import AppKit
import Core
import Foundation
import os

// SPEC §5 I7: Cmd+Shift+G search overlay. AppKit borderless floating panel
// (`.nonactivatingPanel`, `.hudWindow`) that live-queries `LibraryIndex` as the
// user types. Arrow keys move selection; Enter closes the overlay and logs the
// selected id (sheet presentation is deferred — P2.2 scope is overlay +
// selection).
//
// Hotkey registration goes through `HotkeyRegistry` (Carbon). Global event
// taps are explicitly forbidden (§5 I7 / §8 Input Monitoring). If registration
// fails, `lastHotkeyError` is populated for the eventual menubar-badge
// surfacing in the App shell.

@MainActor
public final class SearchOverlayController: NSObject, NSWindowDelegate {

    // MARK: - Public configuration

    /// App-assigned hotkey id for the search overlay. The registry uses this
    /// to route Carbon events back to the owning controller.
    /// Must match `HotkeyBindings.searchHotkeyID` so region capture (id 1)
    /// and search (id 3) don't clobber each other's Carbon registration.
    public static let hotkeyID: UInt32 = HotkeyBindings.searchHotkeyID

    // MARK: - Public state

    /// Populated when `RegisterEventHotKey` fails at activation time. The
    /// menubar shell reads this to surface a conflict badge per §17.3.
    public var lastHotkeyError: Error?

    // MARK: - Dependencies

    private let index: LibraryIndex
    private let registry: HotkeyRegistering
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "search")

    // MARK: - UI state

    private var panel: NSPanel?
    private var textField: NSTextField?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?
    private var results: [LibraryRecord] = []
    /// Debounce token — each keystroke bumps this; only the latest task runs.
    private var debounceToken: UInt64 = 0
    /// Milliseconds to wait before issuing the query. Per the task contract.
    private let debounceMilliseconds: UInt64 = 50

    // MARK: - Init

    /// - Parameters:
    ///   - index: the library index to query.
    ///   - registry: injection seam for tests / production. Defaults to the
    ///     Carbon-backed registry on macOS.
    public init(index: LibraryIndex, registry: HotkeyRegistering) {
        self.index = index
        self.registry = registry
        super.init()
    }

    #if canImport(Carbon)
    public convenience init(index: LibraryIndex) {
        self.init(index: index, registry: CarbonHotkeyRegistry())
    }
    #endif

    // MARK: - Activation

    /// Installs the `Cmd+Shift+G` hotkey. Call once from the App shell after
    /// `NSApp` is up. Registration failure is stored in `lastHotkeyError` and
    /// does not throw — the app should still launch.
    public func activate() {
        #if canImport(Carbon)
        do {
            try registry.register(
                id: Self.hotkeyID,
                keyCode: HotkeyKeyCode.g,
                modifiers: HotkeyModifiers.command | HotkeyModifiers.shift
            ) { [weak self] in
                self?.toggle()
            }
        } catch {
            lastHotkeyError = error
            log.error("hotkey registration failed: \(String(describing: error), privacy: .public)")
        }
        #else
        lastHotkeyError = HotkeyRegistryError.carbonUnavailable
        #endif
    }

    /// Tears down the hotkey. Call from the App shell on shutdown.
    public func deactivate() {
        registry.unregister(id: Self.hotkeyID)
        hide()
    }

    // MARK: - Panel lifecycle

    /// Test hook — instantiates the panel without relying on a hotkey event.
    /// The returned panel is not ordered front; callers take ownership of
    /// lifetime. Useful for smoke tests that only verify NSPanel construction.
    public func makePanelForTesting() -> NSPanel {
        let p = buildPanel()
        return p
    }

    private func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let p = panel ?? buildPanel()
        panel = p
        // Center on the active screen.
        if let screen = NSScreen.main {
            let size = p.frame.size
            let origin = CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2
            )
            p.setFrameOrigin(origin)
        }
        p.orderFrontRegardless()
        p.makeKey()
        textField?.becomeFirstResponder()
        // Fresh activation: clear the prior query + results.
        textField?.stringValue = ""
        results = []
        tableView?.reloadData()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func buildPanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 600, height: 400)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow, .titled],
            backing: .buffered,
            defer: false
        )
        p.title = "Shotfuse Search"
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        let container = NSView(frame: rect)

        // Search field.
        let field = NSTextField(frame: NSRect(x: 12, y: 360, width: 576, height: 28))
        field.placeholderString = "Search captures (OCR, window title, app, path)"
        field.font = NSFont.systemFont(ofSize: 16)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        container.addSubview(field)
        self.textField = field

        // Results table in a scroll view.
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 576, height: 340))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = NSTableView(frame: scroll.bounds)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowSizeStyle = .medium
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableRowClicked)
        table.doubleAction = #selector(tableRowActivated)

        let col = NSTableColumn(identifier: .init("result"))
        col.title = "Result"
        col.width = 560
        table.addTableColumn(col)

        scroll.documentView = table
        container.addSubview(scroll)
        self.scrollView = scroll
        self.tableView = table

        p.contentView = container
        return p
    }

    // MARK: - Keyboard handling

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        // Esc closes.
        if event.keyCode == 53 {
            hide()
            return true
        }
        // Return / Enter fires selection.
        if event.keyCode == 36 || event.keyCode == 76 {
            commitSelection()
            return true
        }
        // Arrow Up / Down move the table selection.
        guard let table = tableView else { return false }
        if event.keyCode == 125 { // down
            let next = min(table.selectedRow + 1, results.count - 1)
            if next >= 0 {
                table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                table.scrollRowToVisible(next)
            }
            return true
        }
        if event.keyCode == 126 { // up
            let prev = max(table.selectedRow - 1, 0)
            if prev < results.count {
                table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                table.scrollRowToVisible(prev)
            }
            return true
        }
        return false
    }

    private func commitSelection() {
        guard let table = tableView, table.selectedRow >= 0,
              table.selectedRow < results.count else {
            hide()
            return
        }
        let picked = results[table.selectedRow]
        log.info("search overlay selected id=\(picked.id, privacy: .public)")
        hide()
    }

    @objc private func tableRowClicked() {
        // Single-click just selects; Enter or double-click commits.
    }

    @objc private func tableRowActivated() {
        commitSelection()
    }

    // MARK: - Query pipeline

    fileprivate func scheduleQuery(_ raw: String) {
        debounceToken &+= 1
        let token = debounceToken
        let sanitized = SearchQuery.sanitize(raw)
        // Empty input: clear immediately, no debounce.
        if sanitized.isEmpty {
            results = []
            tableView?.reloadData()
            return
        }
        Task { [weak self, index, debounceMilliseconds] in
            try? await Task.sleep(for: .milliseconds(Int(debounceMilliseconds)))
            guard let self, await self.isCurrent(token) else { return }
            do {
                let ids = try await index.searchIDs(sanitized, limit: 50)
                var records: [LibraryRecord] = []
                records.reserveCapacity(ids.count)
                for id in ids {
                    if let rec = try await index.fetch(id: id) {
                        records.append(rec)
                    }
                }
                await MainActor.run {
                    guard self.debounceToken == token else { return }
                    self.results = records
                    self.tableView?.reloadData()
                    if !records.isEmpty {
                        self.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            } catch {
                self.log.error("search query failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        debounceToken == token
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Mirror Spotlight behavior — close if focus moves away.
        hide()
    }
}

// MARK: - NSTextFieldDelegate

extension SearchOverlayController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        scheduleQuery(field.stringValue)
    }

    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        // Intercept navigation keys so they drive the table instead of the
        // text field's cursor.
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            if let t = tableView {
                let next = min(t.selectedRow + 1, results.count - 1)
                if next >= 0 {
                    t.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                    t.scrollRowToVisible(next)
                }
                return true
            }
        case #selector(NSResponder.moveUp(_:)):
            if let t = tableView {
                let prev = max(t.selectedRow - 1, 0)
                if prev < results.count {
                    t.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                    t.scrollRowToVisible(prev)
                }
                return true
            }
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            break
        }
        return false
    }
}

// MARK: - NSTableView data source / delegate

extension SearchOverlayController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = identifier
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
                ])
                return c
            }()
        guard row < results.count else { return cell }
        let rec = results[row]
        let title = rec.windowTitle ?? rec.fileURL ?? rec.bundleID ?? rec.id
        cell.textField?.stringValue = title
        return cell
    }
}
