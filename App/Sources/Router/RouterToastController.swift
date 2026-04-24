import AppKit
import Core
import Foundation
import os

// SPEC §7 / §7.1: after Router auto-delivers to the top-scoring destination
// we surface a 3-second toast "→ <destination>  (⌘Z to change)". Pressing
// Cmd+Z within the toast's lifetime cancels the auto-dismiss and hands
// control to the 3-option chooser (`RouterChooserController`).
//
// Mirrors `LimboHUDController`'s non-activating `NSPanel` shape so both
// surfaces share the same SCContentFilter exclusion story and key-event
// discipline (panels do not steal focus from the frontmost app).

/// AppKit controller for the post-capture "delivered to" toast.
@MainActor
public final class RouterToastController: NSObject {

    public typealias RedirectHandler = @MainActor @Sendable () -> Void

    private let panel: NSPanel
    private let result: RouterSideEffectResult
    private let onRedirect: RedirectHandler
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "router.toast")
    private var autoDismissTask: Task<Void, Never>?

    /// Creates a toast bound to the actual delivery result. The controller owns
    /// its own auto-dismiss timer; press Cmd+Z in its key window to
    /// cancel the timer and invoke `onRedirect`.
    public init(result: RouterSideEffectResult, onRedirect: @escaping RedirectHandler) {
        self.panel = Self.buildPanel()
        self.result = result
        self.onRedirect = onRedirect
        super.init()
        configurePanel()
    }

    deinit {
        autoDismissTask?.cancel()
        MainActor.assumeIsolated {
            panel.orderOut(nil)
        }
    }

    /// Positions the toast bottom-right of the active screen, orders it
    /// front, and kicks off the 3-second auto-dismiss timer.
    public func show() {
        positionBottomRight()
        panel.orderFrontRegardless()
        // Let the content view drive Cmd+Z without yanking focus from the
        // frontmost app.
        panel.makeFirstResponder(panel.contentView)

        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.hide()
            }
        }
    }

    /// Hides the toast and cancels the auto-dismiss task.
    public func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel.orderOut(nil)
    }

    /// Invoked by the content view on Cmd+Z. Cancels the auto-dismiss
    /// timer, hides the toast, and invokes the redirect closure.
    fileprivate func handleRedirect() {
        log.debug("router toast redirect (Cmd+Z)")
        hide()
        onRedirect()
    }

    // MARK: - Panel construction

    private static func buildPanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 60)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.hudWindow, .nonactivatingPanel, .utilityWindow, .titled],
            backing: .buffered,
            defer: false
        )
        p.title = "Shotfuse"
        p.level = .floating
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.worksWhenModal = true
        return p
    }

    private func configurePanel() {
        let contentSize = panel.frame.size
        let container = RouterToastContentView(frame: NSRect(origin: .zero, size: contentSize))
        container.controller = self

        let label = NSTextField(labelWithString: "→ \(result.humanName)  (⌘Z to change)")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: 18, width: contentSize.width - 32, height: 20)
        container.addSubview(label)

        panel.contentView = container
    }

    private func positionBottomRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 24
        let origin = CGPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
        panel.setFrameOrigin(origin)
    }
}

/// Content view that makes itself first responder so the toast can see
/// Cmd+Z without activating the app.
@MainActor
private final class RouterToastContentView: NSView {
    weak var controller: RouterToastController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           (event.charactersIgnoringModifiers ?? "").lowercased() == "z" {
            controller?.handleRedirect()
            return
        }
        super.keyDown(with: event)
    }
}
