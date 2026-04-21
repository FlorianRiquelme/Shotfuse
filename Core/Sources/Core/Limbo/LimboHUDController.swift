import AppKit
import Foundation
import os

// SPEC §4 (Limbo) + §5 Invariant 2 (AppKit, not SwiftUI) + Invariant 5
// (self-exclusion from SCContentFilter) + §13.4 (SCA surfacing, never
// auto-modify master).
//
// LimboHUDController is a floating, non-activating `NSPanel` shown
// bottom-right of the active screen for 2–8s after a capture (the
// timeline is owned by `LimboTimeline`; this controller renders the
// current frame but does not drive the clock). The panel consumes the
// SPEC §4 keymap (e/p/t/esc/cmd+z) and forwards each match as a
// `LimboAction`, plus a conditional "Redact and re-save" button when
// the SCA result on the `LimboContext` is non-`none`.
//
// Capture self-exclusion (Invariant 5) is the CAPTURE side's
// responsibility: the controller publishes its windows via
// `excludedWindows` so `CaptureEngine` can hand them to
// `SCContentFilter(...excludingWindows:)`. The HUD itself does not
// attempt to enforce exclusion — that would put policy in two places.

/// AppKit controller owning the Limbo HUD panel.
@MainActor
public final class LimboHUDController: NSObject {

    /// Signature of the callback fired when the user activates an action
    /// (keyboard or button). Must be `@MainActor` — AppKit interactions
    /// happen on the main thread.
    public typealias ActionHandler = @MainActor @Sendable (LimboAction) -> Void

    // MARK: - Public state

    /// The finalized-capture snapshot currently rendered. Set once at
    /// init; rebind a new context by constructing a new controller.
    public let context: LimboContext

    /// `true` iff the HUD is rendering the "Redact and re-save" button.
    /// Mirrors `LimboContext.hasSensitiveContent` and is exposed for
    /// tests and for the eventual capture-engine wiring.
    public var showsRedactButton: Bool { context.hasSensitiveContent }

    /// Windows owned by the HUD that CaptureEngine must exclude from
    /// `SCContentFilter` (SPEC §5 Invariant 5). Always contains exactly
    /// the single Limbo panel while the controller is alive.
    public var excludedWindows: [NSWindow] { [panel] }

    // MARK: - Dependencies

    private let panel: NSPanel
    private let onAction: ActionHandler
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "limbo")

    // MARK: - UI refs (for test access + teardown)

    private weak var thumbnailView: NSImageView?
    private weak var titleLabel: NSTextField?
    private weak var subtitleLabel: NSTextField?
    private weak var redactButton: NSButton?

    // MARK: - Init / teardown

    /// Builds the panel from `context` and wires the action callback.
    /// - Parameters:
    ///   - context: Snapshot of the capture to surface.
    ///   - onAction: `@MainActor @Sendable` callback invoked on each
    ///     dispatched `LimboAction`. The controller itself does NOT
    ///     perform the action — it purely emits events.
    public init(
        context: LimboContext,
        onAction: @escaping ActionHandler
    ) {
        self.context = context
        self.onAction = onAction
        self.panel = Self.buildPanel()
        super.init()
        configurePanel()
    }

    /// Convenience init for smoke tests that only need a default no-op
    /// handler.
    public convenience init(context: LimboContext) {
        self.init(context: context, onAction: { _ in })
    }

    deinit {
        // Panel holds no strong back-reference to `self`, but we want to
        // make sure it's off-screen if a live controller is dropped.
        MainActor.assumeIsolated {
            panel.orderOut(nil)
        }
    }

    // MARK: - Activation

    /// Positions the panel bottom-right of the active screen and orders
    /// it front. Callers own the visibility timeline — pair this with a
    /// `LimboTimeline` poll that calls `hide()` when remaining ≤ 0.
    public func show() {
        positionBottomRight()
        panel.orderFrontRegardless()
    }

    /// Hides the panel without destroying it.
    public func hide() {
        panel.orderOut(nil)
    }

    /// Synthesizes an action dispatch as if the user had pressed the
    /// matching key. Exposed for tests and for the capture-engine
    /// wiring; production buttons call this too.
    public func dispatch(_ action: LimboAction) {
        log.debug("limbo action \(action.rawValue, privacy: .public)")
        onAction(action)
    }

    // MARK: - Panel construction

    private static func buildPanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 120)
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
        let container = LimboContentView(frame: NSRect(origin: .zero, size: contentSize))
        container.controller = self

        // Thumbnail.
        let thumb = NSImageView(frame: NSRect(x: 12, y: 12, width: 96, height: 96))
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        if let img = NSImage(contentsOf: context.thumbnailURL) {
            thumb.image = img
        }
        container.addSubview(thumb)
        self.thumbnailView = thumb

        // Title (bundle id).
        let title = NSTextField(labelWithString: context.bundleID ?? "Unknown app")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 120, y: 84, width: 228, height: 20)
        container.addSubview(title)
        self.titleLabel = title

        // Subtitle (window title).
        let subtitle = NSTextField(labelWithString: context.windowTitle ?? "")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 120, y: 64, width: 228, height: 18)
        container.addSubview(subtitle)
        self.subtitleLabel = subtitle

        // Action row.
        let actions: [(LimboAction, String)] = [
            (.edit, "Edit"),
            (.pin, "Pin"),
            (.tag, "Tag"),
            (.deleteEsc, "Delete"),
        ]
        var x: CGFloat = 120
        for (action, label) in actions {
            let btn = NSButton(title: label, target: self, action: #selector(actionButtonPressed(_:)))
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            btn.sizeToFit()
            var f = btn.frame
            f.origin.x = x
            f.origin.y = 16
            f.size.height = 22
            btn.frame = f
            container.addSubview(btn)
            x += f.size.width + 6
        }

        // Redact-and-re-save button — surfaced only when SCA flagged
        // non-`none` content (SPEC §13.4).
        if context.hasSensitiveContent {
            let btn = NSButton(
                title: "Redact and re-save",
                target: self,
                action: #selector(redactButtonPressed(_:))
            )
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.identifier = NSUserInterfaceItemIdentifier("redact")
            btn.sizeToFit()
            var f = btn.frame
            f.origin.x = 120
            f.origin.y = 40
            f.size.height = 22
            btn.frame = f
            container.addSubview(btn)
            self.redactButton = btn
        }

        panel.contentView = container
    }

    // MARK: - Positioning

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

    // MARK: - Button actions

    @objc private func actionButtonPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = LimboAction(rawValue: raw) else { return }
        dispatch(action)
    }

    @objc private func redactButtonPressed(_ sender: NSButton) {
        // "Redact and re-save" re-enters the edit flow with the blur
        // tool preselected (SPEC §6.4). The controller itself does not
        // do the redaction — it only signals intent, and the host
        // (capture pipeline) owns the "new .shot" write (SPEC §5 I3).
        dispatch(.edit)
    }

    // MARK: - Keyboard handling

    /// Translates a `NSEvent.keyDown` event into an optional
    /// `LimboAction`. Exposed `internal` so the content view can reach
    /// it; tests import `Core` via the App target bundle only — this
    /// method is incidentally covered by the dispatch-round-trip test.
    func action(for event: NSEvent) -> LimboAction? {
        // Escape (keyCode 53).
        if event.keyCode == 53 {
            return .deleteEsc
        }
        // Cmd+Z.
        if event.modifierFlags.contains(.command),
           (event.charactersIgnoringModifiers ?? "").lowercased() == "z" {
            return .redirect
        }
        // Plain printable keys (e/p/t).
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if chars.count == 1, let action = LimboAction(rawValue: chars) {
            return action
        }
        return nil
    }
}

// MARK: - Content view with keyDown dispatch

/// Custom `NSView` subclass so the panel's content view can become
/// first responder and route keyDown events through the controller.
@MainActor
private final class LimboContentView: NSView {
    weak var controller: LimboHUDController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let controller,
              let action = controller.action(for: event) else {
            super.keyDown(with: event)
            return
        }
        controller.dispatch(action)
    }
}
