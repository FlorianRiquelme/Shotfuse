import Foundation
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// SPEC §5 Invariant 7: global hotkeys are bound via Carbon's
// `RegisterEventHotKey`. This avoids the Input Monitoring TCC gate that
// `NSEvent.addGlobalMonitorForEvents` would trip. Registration failure is
// surfaced via the throwing API below; upstream (App target) is responsible
// for badging the menubar icon and deep-linking to Settings.
//
// ## Concurrency
//
// The Carbon Event Manager posts hotkey events on the main run loop. We
// marshal the firing into a `@MainActor` callback via `MainActor.assumeIsolated`,
// which keeps the public API Swift-6 concurrency-clean — handlers registered
// from the main actor never need to worry about cross-actor hops.

/// Errors surfaced by `HotkeyRegistry`.
public enum HotkeyRegistryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The OS returned a non-OK status when installing the hotkey.
    case registrationFailed(id: UInt32, status: Int32)
    /// The requested id is already in use by this process.
    case alreadyRegistered(id: UInt32)
    /// Carbon is not available (e.g., tests on a non-macOS host).
    case carbonUnavailable

    public var description: String {
        switch self {
        case .registrationFailed(let id, let s):
            return "HotkeyRegistry.registrationFailed(id=\(id), status=\(s))"
        case .alreadyRegistered(let id):
            return "HotkeyRegistry.alreadyRegistered(id=\(id))"
        case .carbonUnavailable:
            return "HotkeyRegistry.carbonUnavailable"
        }
    }
}

/// Abstraction over "register a global hotkey, invoke a handler when it fires."
/// The concrete Carbon-backed implementation is `CarbonHotkeyRegistry`; tests
/// use a mock that simulates registration failure without touching the OS.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Registers a hotkey. `id` is an app-assigned stable identifier (caller
    /// chooses the numbering scheme; 1 = search overlay is fine for v0.1).
    /// `keyCode` is a Carbon virtual keycode (`kVK_*`); `modifiers` is a Carbon
    /// modifier bitmask (`cmdKey`, `shiftKey`, ...).
    func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws

    /// Unregisters a previously-registered hotkey. No-op if `id` is unknown.
    func unregister(id: UInt32)
}

// MARK: - Carbon-backed implementation

#if canImport(Carbon)

/// Production implementation. Wraps `RegisterEventHotKey`.
///
/// Singleton-like: only one instance per process is meaningful, because Carbon
/// hotkey IDs are process-scoped. Multiple instances would collide on ids.
@MainActor
public final class CarbonHotkeyRegistry: HotkeyRegistering {

    // Track every registration so the event handler can dispatch by hotkey id
    // and so `unregister` can unwind cleanly. Values live inside the class so
    // the Carbon event handler (a C function pointer) can safely capture a
    // heap pointer to `self`.
    private final class Slot {
        let hotkeyRef: EventHotKeyRef
        let handler: @MainActor () -> Void
        init(hotkeyRef: EventHotKeyRef, handler: @escaping @MainActor () -> Void) {
            self.hotkeyRef = hotkeyRef
            self.handler = handler
        }
    }

    private var slots: [UInt32: Slot] = [:]
    private var eventHandlerRef: EventHandlerRef?

    public init() {}

    // No `deinit` — Swift 6's nonisolated deinit can't touch main-actor state
    // safely. Callers should invoke `close()` explicitly before releasing the
    // registry. Carbon tears down its tables at process exit as a safety net.

    /// Explicit teardown. Unregisters every hotkey and removes the Carbon
    /// event handler. Safe to call more than once.
    public func close() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        for (_, slot) in slots {
            UnregisterEventHotKey(slot.hotkeyRef)
        }
        slots.removeAll()
    }

    public func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws {
        if slots[id] != nil {
            throw HotkeyRegistryError.alreadyRegistered(id: id)
        }

        // Install the shared Carbon event handler on first registration.
        if eventHandlerRef == nil {
            try installEventHandler()
        }

        var sig: FourCharCode = 0
        // 'SHOT' in big-endian FourCharCode form. Carbon wants any unique-ish
        // 4CC for the application's hotkey signature; the exact value doesn't
        // matter beyond being stable within the process.
        withUnsafeBytes(of: "SHOT".utf8CString) { raw in
            // utf8CString has a trailing NUL; first 4 bytes carry the chars.
            let a = UInt32(raw[0])
            let b = UInt32(raw[1])
            let c = UInt32(raw[2])
            let d = UInt32(raw[3])
            sig = (a << 24) | (b << 16) | (c << 8) | d
        }

        let hotKeyID = EventHotKeyID(signature: sig, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else {
            throw HotkeyRegistryError.registrationFailed(id: id, status: Int32(status))
        }
        slots[id] = Slot(hotkeyRef: ref, handler: handler)
    }

    public func unregister(id: UInt32) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(slot.hotkeyRef)
    }

    // MARK: - Carbon event plumbing

    private func installEventHandler() throws {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                // Re-enter the main actor. Carbon delivers on the main thread
                // in practice, but the Swift-6 compiler can't prove it, so we
                // use `assumeIsolated`. If Carbon ever changed this we'd crash
                // loudly — preferable to silently wrong-thread behavior.
                guard let event, let userData else { return noErr }
                let registry = Unmanaged<CarbonHotkeyRegistry>
                    .fromOpaque(userData).takeUnretainedValue()

                var id = EventHotKeyID()
                let sz = MemoryLayout<EventHotKeyID>.size
                let rc = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    sz,
                    nil,
                    &id
                )
                if rc != noErr { return rc }

                MainActor.assumeIsolated {
                    registry.slots[id.id]?.handler()
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandlerRef
        )
        if status != noErr {
            throw HotkeyRegistryError.registrationFailed(id: 0, status: Int32(status))
        }
    }
}

// MARK: - Carbon keycode convenience

/// Symbolic names for the Carbon virtual keycodes used in v0.1.
///
/// Carbon's `kVK_*` constants are `Int`. We re-surface them as `UInt32` because
/// that's what `RegisterEventHotKey` takes. This keeps app-side call sites
/// ergonomic (no inline casts).
public enum HotkeyKeyCode {
    public static let g: UInt32 = UInt32(kVK_ANSI_G)
    public static let w: UInt32 = UInt32(kVK_ANSI_W)
}

/// Symbolic names for Carbon modifier masks.
public enum HotkeyModifiers {
    public static let command: UInt32 = UInt32(cmdKey)
    public static let shift: UInt32 = UInt32(shiftKey)
    public static let option: UInt32 = UInt32(optionKey)
    public static let control: UInt32 = UInt32(controlKey)
}

#endif
