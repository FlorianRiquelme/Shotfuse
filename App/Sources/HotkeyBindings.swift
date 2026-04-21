import Core
import Foundation

// SPEC §5 I7: all global hotkeys go through `HotkeyRegistry` (Carbon).
// This file names the hotkey ids so AppDelegate, tests, and the menubar
// badge all agree on which slot means what. Key codes are the Carbon
// virtual key codes `kVK_ANSI_*`; we carry them as raw UInt32 to avoid
// leaking the `Carbon` import into the App surface.

/// Deterministic hotkey IDs per the W1-INT contract.
public enum HotkeyBindings {
    public static let regionHotkeyID: UInt32 = 1
    public static let fullscreenHotkeyID: UInt32 = 2
    public static let searchHotkeyID: UInt32 = 3
    public static let witnessHotkeyID: UInt32 = 4

    /// `kVK_ANSI_4` — the "4" key. Cmd+Option+4 for region capture
    /// (Cmd+Shift+4 collides with macOS native + CleanShot).
    public static let keyCode4: UInt32 = 21
    /// `kVK_ANSI_3` — Cmd+Option+3 for fullscreen
    /// (Cmd+Shift+3 collides with macOS native + CleanShot).
    public static let keyCode3: UInt32 = 20
    /// `kVK_ANSI_G` — Cmd+Shift+G for search overlay.
    public static let keyCodeG: UInt32 = 5
    /// `kVK_ANSI_W` — Cmd+Option+W for witness capture
    /// (Cmd+Shift+W closes a window in most apps).
    public static let keyCodeW: UInt32 = 13

    /// Single binding row describing one hotkey we want registered at
    /// launch. The App shell iterates over `all` to register/unregister
    /// and the menubar badge keys off any failure.
    public struct Binding: Sendable {
        public let id: UInt32
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let label: String
    }

    /// Cmd+Shift modifier mask. Kept because `SearchOverlayController` still
    /// uses Cmd+Shift+G (no conflict observed).
    public static let cmdShift: UInt32 = HotkeyModifiers.command | HotkeyModifiers.shift
    /// Cmd+Option modifier mask — capture hotkeys use this to avoid the
    /// Cmd+Shift+[3/4/5] collision with macOS native + CleanShot.
    public static let cmdOption: UInt32 = HotkeyModifiers.command | HotkeyModifiers.option

    /// The four W1 hotkeys in registration order. `searchHotkeyID` is
    /// registered by `SearchOverlayController` itself (see `activate()`);
    /// including it here keeps the diagnostics story honest — the App
    /// knows which ids are in play even if it doesn't own all of them.
    public static let all: [Binding] = [
        Binding(id: regionHotkeyID,     keyCode: keyCode4, modifiers: cmdOption, label: "Capture region"),
        Binding(id: fullscreenHotkeyID, keyCode: keyCode3, modifiers: cmdOption, label: "Capture fullscreen"),
        Binding(id: witnessHotkeyID,    keyCode: keyCodeW, modifiers: cmdOption, label: "Capture witness"),
    ]
}

/// Registers every hotkey in `bindings` against the supplied registry and
/// wires each to its matching handler. Fail-open (SPEC §5 I7 +
/// §17.3): a single registration failure is logged and returned for the
/// menubar badge, but never thrown — the app stays launchable.
///
/// - Returns: Ids that failed to register, in registration order.
@MainActor
public func registerAll(
    bindings: [HotkeyBindings.Binding] = HotkeyBindings.all,
    registry: HotkeyRegistering,
    handler: @escaping @MainActor (UInt32) -> Void
) -> [UInt32] {
    var failed: [UInt32] = []
    for binding in bindings {
        do {
            try registry.register(
                id: binding.id,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers
            ) { handler(binding.id) }
        } catch {
            failed.append(binding.id)
        }
    }
    return failed
}
