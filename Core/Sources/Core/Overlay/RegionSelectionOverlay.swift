#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

// AppKit-only per SPEC §5 I2 (SwiftUI never owns capture surfaces). Per-display
// borderless `NSWindow`s overlay the active display set; drag returns a
// `RegionSelection` via async API. The windows are all created by this process
// and therefore belong to `dev.friquelme.shotfuse`, which is what P1.2's bundle-
// level `SCContentFilter` exclusion (§5 I5) keys off.

/// Errors surfaced by `RegionSelectionOverlay`.
public enum RegionSelectionError: Error, Sendable {
    /// No active `NSScreen` available at presentation time.
    case noDisplaysAvailable
}

/// Minimum drag extent (in points, both axes) required to commit a selection.
/// A click-without-drag or a sub-threshold nudge is treated as an Esc cancel so
/// the capture pipeline never receives a degenerate 1x1 region (hq-6f9).
let minSelectionSize: CGFloat = 8

/// Returns true when the span between two drag points is large enough (on both
/// axes) to qualify as an intentional selection. Sub-threshold drags are
/// rejected and routed through the cancel path. Pure function so it can be
/// unit-tested without AppKit / real mouse events.
func isSelectionAboveMinimum(from a: CGPoint, to b: CGPoint) -> Bool {
    abs(a.x - b.x) >= minSelectionSize && abs(a.y - b.y) >= minSelectionSize
}

/// Borderless, transparent, per-display overlay window. Captures drag events
/// and forwards them to the backing view. One instance per screen.
@MainActor
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// Backing view that draws the dim scrim + the live selection rectangle
/// and forwards mouse events to a delegate. Coordinates are window-local
/// (bottom-left origin = display bottom-left since the window fills the screen).
@MainActor
final class OverlayView: NSView {
    /// Called with (startWindowLocal, currentWindowLocal) on each drag step.
    var onDrag: ((CGPoint, CGPoint) -> Void)?
    /// Called with the final (startWindowLocal, endWindowLocal) on mouse-up.
    var onRelease: ((CGPoint, CGPoint) -> Void)?
    /// Called when the user hits Esc.
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var isFlipped: Bool { false } // bottom-left coord system (matches NSScreen)

    // Accept the very first click that activates the overlay window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()
        guard let a = dragStart, let b = dragCurrent else { return }
        let r = RegionGeometry.rect(from: a, to: b)
        // Punch a clear hole over the selection.
        NSColor.clear.setFill()
        r.fill(using: .copy)
        // Outline.
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragCurrent = p
        needsDisplay = true
        NSLog("[shotfuse-overlay] mouseDown at (\(p.x), \(p.y))")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragCurrent = p
        needsDisplay = true
        onDrag?(a, p)
        NSLog("[shotfuse-overlay] mouseDragged to (\(p.x), \(p.y))")
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        // Reject sub-threshold drags (including plain clicks) by routing through
        // the cancel path, same as Esc. Keeps degenerate 1x1 selections out of
        // the capture pipeline (hq-6f9).
        guard isSelectionAboveMinimum(from: a, to: p) else {
            NSLog("[shotfuse-overlay] mouseUp sub-threshold drag (\(abs(p.x - a.x))x\(abs(p.y - a.y)) < \(minSelectionSize)) — cancelling")
            onCancel?()
            return
        }
        onRelease?(a, p)
        NSLog("[shotfuse-overlay] mouseUp at (\(p.x), \(p.y)) — start=(\(a.x),\(a.y))")
    }

    override func keyDown(with event: NSEvent) {
        // Esc = cancel.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Region-selection overlay. Call `present()` to show overlay windows on every
/// active display; returns a `RegionSelection` on release, or `nil` if the user
/// cancels with Esc. Failure to enumerate displays throws
/// `RegionSelectionError.noDisplaysAvailable`.
@MainActor
public final class RegionSelectionOverlay {
    private var windows: [(NSWindow, DisplayMetadata)] = []
    private var continuation: CheckedContinuation<RegionSelection?, Error>?

    public init() {}

    /// Enumerates live displays and wraps their metadata per §6.1.
    static func liveDisplays() -> [DisplayMetadata] {
        NSScreen.screens.compactMap { screen in
            guard let rawID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return metadata(for: CGDirectDisplayID(rawID.uint32Value), screen: screen)
        }
    }

    /// Builds `DisplayMetadata` for the given `CGDirectDisplayID` + `NSScreen`.
    /// Uses `CGDisplayCopyDisplayMode` for native dimensions and
    /// `IODisplayCreateInfoDictionary` for vendor / product / serial (§6.1).
    static func metadata(for displayID: CGDirectDisplayID, screen: NSScreen) -> DisplayMetadata {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nativeWidth = mode.map { Int($0.pixelWidth) } ?? Int(screen.frame.width * screen.backingScaleFactor)
        let nativeHeight = mode.map { Int($0.pixelHeight) } ?? Int(screen.frame.height * screen.backingScaleFactor)

        var vendor: UInt32?
        var product: UInt32?
        var serial: UInt32?
        if let info = ioDisplayInfo(for: displayID) {
            vendor = (info[kDisplayVendorID as String] as? NSNumber)?.uint32Value
            product = (info[kDisplayProductID as String] as? NSNumber)?.uint32Value
            serial = (info[kDisplaySerialNumber as String] as? NSNumber)?.uint32Value
        }

        return DisplayMetadata(
            id: UInt32(displayID),
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            nativeScale: screen.backingScaleFactor,
            vendorID: vendor,
            productID: product,
            serial: serial,
            localizedName: screen.localizedName,
            globalFrame: screen.frame
        )
    }

    private static func ioDisplayInfo(for displayID: CGDirectDisplayID) -> [String: Any]? {
        // `CGDisplayIOServicePort` is deprecated on modern macOS but the modern
        // replacement via `IOServicePortFromCGDisplayID` lives in private headers
        // on some SDKs. We fall through to nil so vendor/product/serial become
        // `Optional.none` — allowed by §6.1 (the fields are `?`).
        return nil
    }

    /// Presents the overlay across all active displays and suspends until the
    /// user releases the drag (returns a `RegionSelection`), presses Esc
    /// (returns `nil`), or an error occurs.
    public func present() async throws -> RegionSelection? {
        let displays = Self.liveDisplays()
        guard !displays.isEmpty else {
            throw RegionSelectionError.noDisplaysAvailable
        }

        // Build one overlay window per screen. Tag each with the matching
        // `DisplayMetadata` so we can resolve the release display on mouseUp.
        for screen in NSScreen.screens {
            guard let rawID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(rawID.uint32Value)
            guard let meta = displays.first(where: { $0.id == UInt32(displayID) }) else { continue }

            let w = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false

            let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v

            v.onRelease = { [weak self] startLocal, endLocal in
                guard let self else { return }
                // Convert window-local → global canonical point space by adding
                // the window (screen) origin.
                let origin = screen.frame.origin
                let startGlobal = CGPoint(x: startLocal.x + origin.x, y: startLocal.y + origin.y)
                let endGlobal = CGPoint(x: endLocal.x + origin.x, y: endLocal.y + origin.y)
                let sel = RegionGeometry.selection(startGlobal: startGlobal, endGlobal: endGlobal, displays: displays)
                self.finish(with: sel)
            }
            v.onCancel = { [weak self] in
                self?.finish(with: nil)
            }

            windows.append((w, meta))
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            NSApplication.shared.activate(ignoringOtherApps: true)
            for (w, _) in windows {
                w.orderFrontRegardless()
            }
            windows.first?.0.makeKey()
            NSLog("[shotfuse-overlay] presented \(windows.count) overlay window(s)")
        }
    }

    private func finish(with selection: RegionSelection?) {
        guard let cont = continuation else { return }
        continuation = nil
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        cont.resume(returning: selection)
    }

    // MARK: - Test hooks

    /// Spawns a single overlay window on the provided screen without starting a
    /// modal wait — used by tests to verify bundle ownership and window
    /// properties without driving real mouse events. Caller is responsible for
    /// closing the returned window.
    static func makeOverlayWindow(on screen: NSScreen) -> NSWindow {
        let w = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        return w
    }
}

#endif
