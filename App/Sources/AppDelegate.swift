import AppKit
import ApplicationServices
import Core
import Foundation
import os

// W1-INT App shell. Owns the live `CaptureCoordinator`, the Carbon
// hotkey registry, the search overlay, and the Limbo HUD. Launches the
// launch agent on first run (§15.1) and keeps the menubar presence alive.
//
// Nothing here bypasses the Core protocols — the real collaborators
// (`MainActorRegionSelector`, `RealScreenCapturing`, `RealFinalizing`,
// `RealLibraryIndexing`) are all Sendable wrappers over the matching Core
// types, which is what the Core unit tests stub.

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Public state

    /// Surfaced to `ShotfuseApp` via @NSApplicationDelegateAdaptor. The
    /// menubar view reads these to render live counters + action buttons.
    public private(set) var coordinator: CaptureCoordinator!
    public private(set) var searchController: SearchOverlayController!
    public private(set) var libraryIndex: LibraryIndex!

    /// Ids of hotkeys that failed to register. Drives the warning badge
    /// on the menubar icon (§17.3).
    public private(set) var failedHotkeyIDs: [UInt32] = []

    // MARK: - Dependencies

    private let hotkeyRegistry: CarbonHotkeyRegistry
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "app")
    private var limbo: LimboHUDController?
    private let delegateRelay: DelegateRelay

    // MARK: - Init

    public override init() {
        self.hotkeyRegistry = CarbonHotkeyRegistry()
        self.delegateRelay = DelegateRelay()
        super.init()
    }

    // MARK: - Application lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let shotfuseRoot = CLIPaths.rootDirectory()
        let libraryRoot = CLIPaths.libraryRoot()
        let indexDB = CLIPaths.indexDatabaseURL()

        do {
            try FileManager.default.createDirectory(
                at: libraryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            log.error("could not create library root: \(String(describing: error), privacy: .public)")
        }

        let index: LibraryIndex
        do {
            index = try LibraryIndex(databaseURL: indexDB)
        } catch {
            log.fault("library index open failed: \(String(describing: error), privacy: .public)")
            // Fatal for this prototype — without an index, the capture
            // loop's Invariant 9 is unmet. Surface a modal and bail.
            NSApp.terminate(nil)
            return
        }
        self.libraryIndex = index

        // SearchOverlayController owns its own Cmd+Shift+G registration.
        let search = SearchOverlayController(index: index)
        self.searchController = search
        search.activate()
        if search.lastHotkeyError != nil {
            failedHotkeyIDs.append(HotkeyBindings.searchHotkeyID)
        }

        // Build the live coordinator.
        let coordinator = CaptureCoordinator(
            regionSelector: MainActorRegionSelector(),
            screenCapturer: RealScreenCapturing(),
            finalizer: RealFinalizing(),
            indexer: RealLibraryIndexing(index: index),
            sensitivityAnalyzer: StubSensitivityAnalyzer(tags: [.none]),
            libraryRoot: libraryRoot,
            contextProvider: { [weak self] in
                await MainActor.run {
                    self?.makeCaptureContext() ?? CaptureFinalization.Context(
                        frontmostBundleID: "",
                        axAvailable: false
                    )
                }
            }
        )
        self.coordinator = coordinator

        // Wire delegate so the HUD + menubar badge see capture events.
        delegateRelay.owner = self
        Task { [coordinator, delegateRelay] in
            await coordinator.setDelegate(delegateRelay)
        }

        // Register the three remaining hotkeys; search already took id 1
        // (via SearchOverlayController). HotkeyBindings.all excludes it.
        failedHotkeyIDs.append(contentsOf: registerAll(
            bindings: HotkeyBindings.all,
            registry: hotkeyRegistry,
            handler: { [weak self] id in
                self?.handleHotkey(id: id)
            }
        ))

        // First-run launch-agent install (§15.1). Silently skip if the
        // shot binary path can't be resolved — user can symlink later.
        if let shotPath = resolveShotBinaryPath() {
            do {
                _ = try LaunchAgentInstaller().firstRun(shotBinaryPath: shotPath)
            } catch {
                log.error("launch agent install failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            log.info("shot binary not found; launch agent skipped")
        }

        log.info("shotfuse launched root=\(shotfuseRoot.path, privacy: .public) library=\(libraryRoot.path, privacy: .public)")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotkeyRegistry.close()
        searchController?.deactivate()
        if let index = libraryIndex {
            Task { await index.close() }
        }
    }

    // MARK: - Hotkey dispatch

    private func handleHotkey(id: UInt32) {
        switch id {
        case HotkeyBindings.regionHotkeyID:
            Task { [coordinator, weak self] in
                do {
                    let url = try await coordinator!.captureRegion()
                    await self?.showLimbo(url: url)
                } catch {
                    self?.log.error("region capture failed: \(String(describing: error), privacy: .public)")
                }
            }
        case HotkeyBindings.fullscreenHotkeyID:
            Task { [coordinator, weak self] in
                do {
                    let url = try await coordinator!.captureFullscreen(display: CGMainDisplayID())
                    await self?.showLimbo(url: url)
                } catch {
                    self?.log.error("fullscreen capture failed: \(String(describing: error), privacy: .public)")
                }
            }
        case HotkeyBindings.witnessHotkeyID:
            Task { [coordinator, weak self] in
                do {
                    _ = try await coordinator!.captureWitness()
                } catch {
                    self?.log.error("witness capture failed: \(String(describing: error), privacy: .public)")
                }
            }
        default:
            log.error("unknown hotkey id: \(id, privacy: .public)")
        }
    }

    // MARK: - Limbo HUD

    fileprivate func showLimbo(url: URL) async {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let thumbnailURL = url.appendingPathComponent("thumb.jpg")
        let masterURL = url.appendingPathComponent("master.png")

        var bundleID: String?
        var windowTitle: String?
        var sensitivity: [String] = ["none"]
        if let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let front = json["frontmost"] as? [String: Any] {
                bundleID = front["bundle_id"] as? String
                windowTitle = front["window_title"] as? String
            }
            if let sens = json["sensitivity"] as? [String], !sens.isEmpty {
                sensitivity = sens
            }
        }

        let id = url.deletingPathExtension().lastPathComponent
        let context = LimboContext(
            id: id,
            thumbnailURL: thumbnailURL,
            masterURL: masterURL,
            bundleID: bundleID,
            windowTitle: windowTitle,
            sensitivity: sensitivity,
            durationSeconds: 2.0
        )

        let controller = LimboHUDController(context: context) { [weak self] action in
            self?.handleLimbo(action: action, url: url, id: id)
        }
        limbo = controller
        controller.show()

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        controller.hide()
    }

    private func handleLimbo(action: LimboAction, url: URL, id: String) {
        switch action {
        case .edit:
            NSWorkspace.shared.open(url.appendingPathComponent("master.png"))
        case .pin:
            // v0.1: pin UI wiring deferred — LibraryIndex does not yet
            // expose a pin mutator. Log so we know it was pressed.
            log.info("limbo pin requested for id=\(id, privacy: .public)")
        case .tag:
            break  // v0.1: tag UX deferred to W2
        case .deleteEsc:
            Task { [weak self] in
                guard let self, let index = self.libraryIndex else { return }
                try? await index.delete(id: id)
                try? FileManager.default.removeItem(at: url)
            }
        case .redirect:
            break  // Router is W2
        }
    }

    // MARK: - Capture context

    /// Gathers the runtime context (frontmost app, AX availability, etc.)
    /// for `CaptureFinalization`. In v0.1 the App shell is the only owner
    /// of `NSWorkspace` — Core is UI-free.
    private func makeCaptureContext() -> CaptureFinalization.Context {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier ?? ""
        let axAvailable = AXIsProcessTrusted()
        return CaptureFinalization.Context(
            frontmostBundleID: bundleID,
            frontmostWindowTitle: nil,
            frontmostFileURL: nil,
            frontmostGitRoot: nil,
            frontmostBrowserURL: nil,
            clipboard: nil,
            clipboardLastModifiedAt: .distantPast,
            clipboardLastModifierBundleID: nil,
            axAvailable: axAvailable
        )
    }

    /// Resolves the absolute path to the `shot` CLI. Looks adjacent to the
    /// App bundle and then along `PATH` via `/usr/bin/which`. Returns nil
    /// if nothing resolvable is found — LaunchAgent install is skipped.
    private func resolveShotBinaryPath() -> String? {
        let bundleAdjacent = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/shot")
        if FileManager.default.isExecutableFile(atPath: bundleAdjacent.path) {
            return bundleAdjacent.path
        }
        // Fall back to `which shot` — acceptable for a dev prototype.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["shot"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Delegate relay

/// Small adapter so `AppDelegate` (a main-actor class) can act as the
/// coordinator's delegate without exposing its whole surface. The relay
/// is `Sendable` and forwards calls to the App shell on the main actor.
private final class DelegateRelay: CaptureCoordinatorDelegate, @unchecked Sendable {
    weak var owner: AppDelegate?

    func captureDidFinish(url: URL) async {
        // AppDelegate.handleHotkey already invokes showLimbo directly
        // after each capture. This hook is reserved for future telemetry.
    }

    func captureDidFail(error: Error) async {
        // AppDelegate logs failures directly from each hotkey handler;
        // this hook is reserved for future menubar badge wiring.
    }
}
