import AppKit
import Core
import Foundation
import os

// SPEC §7 / §7.1: when Router's decision rule says NOT to auto-deliver,
// or when the user presses Cmd+Z on a RouterToast, we surface a
// 3-option chooser listing every candidate destination (see
// `RouterPrediction.all`). Destinations are numbered 1/2/3; the user can
// either click, type the matching digit, navigate with arrow keys +
// Enter, or press Esc to fall back to Clipboard.

/// AppKit controller for the post-capture destination chooser.
@MainActor
public final class RouterChooserController: NSObject {

    public typealias ChoiceHandler = @MainActor @Sendable (RouterDestination) -> Void

    private let panel: NSPanel
    private let prediction: RouterPrediction
    private let onChoose: ChoiceHandler
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "router.chooser")

    /// Ordered `NSButton`s matching `prediction.all` so digit keys /
    /// arrow-key navigation can map back to a `RouterDestination`.
    private var buttons: [NSButton] = []
    private var highlightedIndex: Int = 0

    /// Creates a chooser bound to a prediction. The controller calls
    /// `onChoose` exactly once (clipboard on Esc, or the selected
    /// destination on click/digit/Enter).
    public init(prediction: RouterPrediction, onChoose: @escaping ChoiceHandler) {
        self.panel = Self.buildPanel()
        self.prediction = prediction
        self.onChoose = onChoose
        super.init()
        configurePanel()
    }

    deinit {
        MainActor.assumeIsolated {
            panel.orderOut(nil)
        }
    }

    /// Positions the chooser bottom-right of the active screen and
    /// orders it front. The content view becomes first responder so
    /// digit / arrow / Esc keys route here without app activation.
    public func show() {
        positionBottomRight()
        panel.orderFrontRegardless()
        panel.makeFirstResponder(panel.contentView)
        highlight(index: 0)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Keyboard dispatch

    /// Routes a `keyDown` event received by the content view into a
    /// destination selection or no-op. Exposed internally so the content
    /// view can forward without cracking the enum open itself.
    fileprivate func handle(event: NSEvent) {
        // Esc (keyCode 53) → clipboard fallback.
        if event.keyCode == 53 {
            hide()
            onChoose(.clipboard)
            return
        }
        // Return / Enter → confirm highlighted row.
        if event.keyCode == 36 || event.keyCode == 76 {
            selectHighlighted()
            return
        }
        // Up arrow (126) / Down arrow (125).
        if event.keyCode == 126 {
            highlight(index: (highlightedIndex - 1 + prediction.all.count) % prediction.all.count)
            return
        }
        if event.keyCode == 125 {
            highlight(index: (highlightedIndex + 1) % prediction.all.count)
            return
        }
        // Digit keys 1/2/3 (charactersIgnoringModifiers).
        if let ch = event.charactersIgnoringModifiers,
           let digit = Int(ch),
           digit >= 1, digit <= prediction.all.count {
            pick(index: digit - 1)
            return
        }
    }

    private func highlight(index: Int) {
        guard buttons.indices.contains(index) else { return }
        highlightedIndex = index
        for (i, btn) in buttons.enumerated() {
            btn.state = (i == index) ? .on : .off
        }
    }

    private func selectHighlighted() {
        pick(index: highlightedIndex)
    }

    private func pick(index: Int) {
        guard prediction.all.indices.contains(index) else { return }
        let dest = prediction.all[index].dest
        log.debug("router chooser picked index=\(index) dest=\(dest.logDescription, privacy: .public)")
        hide()
        onChoose(dest)
    }

    // MARK: - Button actions

    @objc private func buttonPressed(_ sender: NSButton) {
        pick(index: sender.tag)
    }

    // MARK: - Panel construction

    private static func buildPanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 180)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.hudWindow, .nonactivatingPanel, .utilityWindow, .titled],
            backing: .buffered,
            defer: false
        )
        p.title = "Send capture to…"
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
        let container = RouterChooserContentView(frame: NSRect(origin: .zero, size: contentSize))
        container.controller = self

        var y: CGFloat = contentSize.height - 40
        for (i, entry) in prediction.all.enumerated() {
            let title = "\(i + 1). \(entry.dest.humanName)"
            let btn = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
            btn.bezelStyle = .rounded
            btn.setButtonType(.pushOnPushOff)
            btn.tag = i
            btn.frame = NSRect(x: 16, y: y, width: contentSize.width - 32, height: 28)
            container.addSubview(btn)
            buttons.append(btn)
            y -= 34
        }

        let hint = NSTextField(labelWithString: "1/2/3 · ↑↓+↩ · Esc → Clipboard")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 16, y: 8, width: contentSize.width - 32, height: 16)
        container.addSubview(hint)

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

/// Content view that captures `keyDown` so digit/arrow/Esc keys don't
/// bubble up to the system or activate the app.
@MainActor
private final class RouterChooserContentView: NSView {
    weak var controller: RouterChooserController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let controller else {
            super.keyDown(with: event)
            return
        }
        controller.handle(event: event)
    }
}
