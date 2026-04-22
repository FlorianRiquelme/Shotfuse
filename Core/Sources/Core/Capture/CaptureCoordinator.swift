import AppKit
import CoreGraphics
import Foundation
import os

// SPEC §5 I1 (CaptureEngine owns state), §5 I2 (AppKit only), §5 I3
// (master.* never modified post-write), §5 I5 (Shotfuse excluded from
// SCContentFilter), §5 I9 (LibraryIndex is load-bearing), §5 I12 (atomic
// writes), §13.3 (SENSITIVE_BUNDLES gate), §13.4 (SCA fire-and-forget),
// §17.2 (path redaction in logs).
//
// CaptureCoordinator is a single-writer actor that composes the end-to-end
// capture loop wired in W1: region/window/fullscreen → finalize → index →
// SCA enrichment. Every collaborator is injected via a Sendable protocol
// so unit tests can stub the capture pipeline end-to-end without real
// TCC/SCK access. The canonical `CaptureEngine` state machine remains the
// source of truth — this actor calls into it rather than bypassing.

// MARK: - Stubbable collaborator protocols

/// Presents the region-selection overlay and awaits the user's gesture.
/// Returns `nil` on cancel (Esc) or throws on programmer error (e.g. no
/// displays available). Implementations are Sendable; they MAY hop to the
/// main actor internally.
public protocol RegionSelecting: Sendable {
    func select() async throws -> RegionSelection?
}

/// Runs the actual SCK capture for a region/window/fullscreen request.
/// Production wires `ScreenCapturer`; tests swap a stub that returns a
/// canned `CapturedFrame`.
public protocol ScreenCapturing: Sendable {
    func captureRegion(selection: RegionSelection) async throws -> CapturedFrame
    func captureWindow(pid: pid_t, windowID: CGWindowID, includeChildren: Bool) async throws -> CapturedFrame
    func captureFullscreen(displayID: CGDirectDisplayID) async throws -> CapturedFrame
}

/// Writes a finalized `.shot/` package atomically. Production wires
/// `CaptureFinalization.finalize` + `ShotPackageWriter`; tests swap a stub
/// that records the call without touching the filesystem (or, in
/// integration tests, writes into a temp directory).
public protocol Finalizing: Sendable {
    /// Finalizes the package and returns the OCR text produced on
    /// `frame.image`. Empty string means "OCR ran but found nothing".
    /// Callers forward this into `LibraryIndex.captures_fts.ocr_text` so
    /// the search overlay (SPEC §5 I7) can hit OCR tokens immediately.
    func finalize(
        frame: CapturedFrame,
        context: CaptureFinalization.Context,
        to finalURL: URL,
        now: Date
    ) throws -> String
}

/// Inserts rows into `LibraryIndex`. Production wraps the live actor;
/// tests supply a recorder.
public protocol LibraryIndexing: Sendable {
    func insert(_ record: LibraryRecord) async throws
    func delete(id: String) async throws
}

// MARK: - Errors

public enum CaptureCoordinatorError: Error, Sendable {
    /// The user dismissed the region-selection overlay with Esc.
    case cancelled
}

// MARK: - Delegate hook

/// Emits lifecycle events for the capture loop. Used by the App shell to
/// trigger the Limbo HUD or surface fatal errors in the menubar badge.
public protocol CaptureCoordinatorDelegate: AnyObject, Sendable {
    func captureDidFinish(url: URL) async
    func captureDidFail(error: Error) async
}

// MARK: - Production adapters

/// Real `RegionSelecting` that presents a fresh `RegionSelectionOverlay`
/// on the main actor for each call. Stateless — safe to store on any
/// actor.
public struct MainActorRegionSelector: RegionSelecting {
    public init() {}

    public func select() async throws -> RegionSelection? {
        try await Self.presentOverlay()
    }

    @MainActor
    private static func presentOverlay() async throws -> RegionSelection? {
        try await RegionSelectionOverlay().present()
    }
}

/// Real `ScreenCapturing` backed by the existing `ScreenCapturer` actor.
public struct RealScreenCapturing: ScreenCapturing {
    private let capturer: ScreenCapturer

    public init(capturer: ScreenCapturer = ScreenCapturer()) {
        self.capturer = capturer
    }

    public func captureRegion(selection: RegionSelection) async throws -> CapturedFrame {
        try await capturer.captureFrame(selection: selection)
    }

    public func captureWindow(pid: pid_t, windowID: CGWindowID, includeChildren: Bool) async throws -> CapturedFrame {
        try await capturer.captureWindow(pid: pid, windowID: windowID, includeChildren: includeChildren)
    }

    public func captureFullscreen(displayID: CGDirectDisplayID) async throws -> CapturedFrame {
        try await capturer.captureFullscreen(display: displayID)
    }
}

/// Real `Finalizing` backed by `CaptureFinalization` + `ShotPackageWriter`.
public struct RealFinalizing: Finalizing {
    public init() {}

    public func finalize(
        frame: CapturedFrame,
        context: CaptureFinalization.Context,
        to finalURL: URL,
        now: Date
    ) throws -> String {
        var writer = ShotPackageWriter()
        let ocr = try CaptureFinalization.finalize(
            frame: frame,
            context: context,
            to: finalURL,
            writer: &writer,
            now: now
        )
        return ocr.concatenatedText
    }
}

/// Real `LibraryIndexing` that forwards to a shared `LibraryIndex` actor.
public struct RealLibraryIndexing: LibraryIndexing {
    private let index: LibraryIndex

    public init(index: LibraryIndex) {
        self.index = index
    }

    public func insert(_ record: LibraryRecord) async throws {
        try await index.insert(record)
    }

    public func delete(id: String) async throws {
        try await index.delete(id: id)
    }
}

// MARK: - CaptureCoordinator

/// Orchestrates the W1 capture loop as a single actor. Callers drive the
/// four top-level entry points; the actor serializes them internally.
public actor CaptureCoordinator {

    // MARK: Collaborators

    private let engine: CaptureEngine
    private let regionSelector: any RegionSelecting
    private let screenCapturer: any ScreenCapturing
    private let finalizer: any Finalizing
    private let indexer: any LibraryIndexing
    private let sensitivityAnalyzer: any SensitivityAnalyzing

    // MARK: Configuration

    private let libraryRoot: URL
    private let witnessesRoot: URL
    private let contextProvider: @Sendable () async -> CaptureFinalization.Context
    private let clock: @Sendable () -> Date
    private let log = Logger(subsystem: "dev.friquelme.shotfuse", category: "coordinator")

    /// Weak-ref delegate surface so the App shell can get capture-done
    /// callbacks without a retain cycle.
    private weak var delegate: (any CaptureCoordinatorDelegate)?

    /// Tail of the serialization task chain. Each new capture awaits the
    /// previous one so concurrent invocations execute strictly in the
    /// order the public entry points were called. The actor alone does
    /// not provide this guarantee because it releases its mailbox lock
    /// across `await`, letting a second task interleave into `runIndexedPipeline`.
    private var pendingTail: Task<Void, Never>?

    // MARK: Init

    public init(
        engine: CaptureEngine = CaptureEngine(),
        regionSelector: any RegionSelecting,
        screenCapturer: any ScreenCapturing,
        finalizer: any Finalizing,
        indexer: any LibraryIndexing,
        sensitivityAnalyzer: any SensitivityAnalyzing = StubSensitivityAnalyzer(tags: [.none]),
        libraryRoot: URL,
        witnessesRoot: URL = WitnessCapture.defaultWitnessesRoot(),
        contextProvider: @escaping @Sendable () async -> CaptureFinalization.Context = {
            CaptureFinalization.Context(frontmostBundleID: "", axAvailable: false)
        },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.regionSelector = regionSelector
        self.screenCapturer = screenCapturer
        self.finalizer = finalizer
        self.indexer = indexer
        self.sensitivityAnalyzer = sensitivityAnalyzer
        self.libraryRoot = libraryRoot
        self.witnessesRoot = witnessesRoot
        self.contextProvider = contextProvider
        self.clock = clock
    }

    public func setDelegate(_ delegate: (any CaptureCoordinatorDelegate)?) {
        self.delegate = delegate
    }

    // MARK: - Public entry points

    /// Region capture: overlay → SCK → finalize → index → SCA enrichment.
    /// Returns the URL of the newly-written `.shot/` package.
    public func captureRegion() async throws -> URL {
        try await serialized {
            try await self.runIndexedPipeline {
                guard let selection = try await self.regionSelector.select() else {
                    throw CaptureCoordinatorError.cancelled
                }
                return try await self.screenCapturer.captureRegion(selection: selection)
            }
        }
    }

    /// Window capture for a known `(pid, windowID)` pair. v0.1 passes
    /// `includeChildren: true` to composite sheets/popovers.
    public func captureWindow(
        pid: pid_t,
        windowID: CGWindowID,
        includeChildren: Bool = true
    ) async throws -> URL {
        try await serialized {
            try await self.runIndexedPipeline {
                try await self.screenCapturer.captureWindow(
                    pid: pid,
                    windowID: windowID,
                    includeChildren: includeChildren
                )
            }
        }
    }

    /// Fullscreen capture of a single display.
    public func captureFullscreen(display: CGDirectDisplayID) async throws -> URL {
        try await serialized {
            try await self.runIndexedPipeline {
                try await self.screenCapturer.captureFullscreen(displayID: display)
            }
        }
    }

    /// Witness capture: bypasses Limbo and the library index (§13).
    /// Returns the URL of the witness `.shot/` package.
    public func captureWitness() async throws -> URL {
        try await serialized {
            try await self.runWitnessCapture()
        }
    }

    private func runWitnessCapture() async throws -> URL {
        try await engine.arm()
        try await engine.beginSelection()
        try await engine.beginCapture()
        do {
            let displayID = CGMainDisplayID()
            let frame = try await screenCapturer.captureFullscreen(displayID: displayID)
            try await engine.finalize()
            let input = WitnessCapture.Input(
                frame: frame,
                witnessesRoot: witnessesRoot,
                now: clock()
            )
            let url = try await WitnessCapture.captureWitness(input)
            try await engine.reset()
            await delegate?.captureDidFinish(url: url)
            return url
        } catch {
            try? await engine.fail(error)
            try? await engine.reset()
            await delegate?.captureDidFail(error: error)
            throw error
        }
    }

    // MARK: - Serialization

    /// Chains `work` behind any in-flight capture so concurrent public
    /// entry points execute in strict arrival order. The second caller
    /// observes the first's completion before its own pipeline touches
    /// the `CaptureEngine` state machine — preserving Invariant I1 even
    /// when callers fire captures from multiple tasks.
    private func serialized(
        _ work: @Sendable @escaping () async throws -> URL
    ) async throws -> URL {
        let previous = pendingTail
        let task = Task<URL, Error> {
            _ = await previous?.value
            return try await work()
        }
        pendingTail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Shared pipeline

    /// Runs the capture stage (frame producer) and then drives the
    /// shared finalize → index → SCA enrichment tail.
    ///
    /// The frame producer is passed as a closure so each entry point can
    /// choose its own overlay/SCK path without duplicating the downstream.
    private func runIndexedPipeline(
        frameProducer: () async throws -> CapturedFrame
    ) async throws -> URL {
        try await engine.arm()
        try await engine.beginSelection()

        let frame: CapturedFrame
        do {
            frame = try await frameProducer()
        } catch let error as CaptureCoordinatorError {
            // User cancelled — wind the state machine back to idle cleanly.
            try? await engine.fail(error)
            try? await engine.reset()
            throw error
        } catch {
            try? await engine.fail(error)
            try? await engine.reset()
            await delegate?.captureDidFail(error: error)
            throw error
        }

        try await engine.beginCapture()
        try await engine.finalize()

        let now = clock()
        let finalURL = libraryRoot.appendingPathComponent(
            "\(UUIDv7.generate(now: now)).shot",
            isDirectory: true
        )

        // Ensure the library root exists — CaptureFinalization expects the
        // parent directory to be present.
        do {
            try FileManager.default.createDirectory(
                at: libraryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            try? await engine.fail(error)
            try? await engine.reset()
            await delegate?.captureDidFail(error: error)
            throw error
        }

        let finalizationContext = await contextProvider()
        let ocrText: String
        do {
            ocrText = try finalizer.finalize(
                frame: frame,
                context: finalizationContext,
                to: finalURL,
                now: now
            )
        } catch {
            try? await engine.fail(error)
            try? await engine.reset()
            await delegate?.captureDidFail(error: error)
            throw error
        }

        // SPEC §2 Weekend 1 DoD: the PNG of the capture MUST be on the
        // clipboard by the time `fsync` of the .shot returns. `finalizer.finalize`
        // has already fsynced `master.png`, so writing its bytes to the
        // pasteboard here is the latest-safe moment in the pipeline. Failures
        // are logged and swallowed — we never want a pasteboard hiccup to
        // abort a successful capture that's already on disk.
        ClipboardWriter.copyMaster(at: finalURL)

        let record = buildLibraryRecord(
            finalURL: finalURL,
            now: now,
            context: finalizationContext,
            ocrText: ocrText
        )
        do {
            try await indexer.insert(record)
        } catch {
            // Don't rollback .shot/ — the file remains on disk and can be
            // reconciled later. We still report failure to the delegate so
            // the menubar can badge.
            try? await engine.reset()
            await delegate?.captureDidFail(error: error)
            throw error
        }

        try await engine.reset()

        // SPEC §13.4: SCA enrichment is fire-and-forget post-capture.
        let analyzer = sensitivityAnalyzer
        Task.detached {
            await Self.enrichSensitivity(
                analyzer: analyzer,
                packageURL: finalURL
            )
        }

        await delegate?.captureDidFinish(url: finalURL)
        return finalURL
    }

    /// Projects the finalization context + URL into the LibraryIndex row
    /// shape. Library-row id reuses the UUIDv7 derived from the `.shot/`
    /// filename so `LibraryIndex` and `manifest.json` agree.
    private func buildLibraryRecord(
        finalURL: URL,
        now: Date,
        context: CaptureFinalization.Context,
        ocrText: String
    ) -> LibraryRecord {
        let id = finalURL.deletingPathExtension().lastPathComponent
        let createdAt = Int64(now.timeIntervalSince1970)
        let expiresAt = Int64(now.addingTimeInterval(CaptureFinalization.defaultFuseInterval).timeIntervalSince1970)
        // `resolveClipboard` re-applies the SENSITIVE_BUNDLES gate so the FTS
        // projection never sees a clipboard string that context.json omitted.
        let (gatedClipboard, _) = CaptureFinalization.resolveClipboard(
            context: context,
            now: now
        )
        return LibraryRecord(
            id: id,
            createdAt: createdAt,
            expiresAt: expiresAt,
            pinned: false,
            bundleID: context.frontmostBundleID.isEmpty ? nil : context.frontmostBundleID,
            windowTitle: context.frontmostWindowTitle,
            fileURL: context.frontmostFileURL,
            gitRoot: context.frontmostGitRoot,
            browserURL: context.frontmostBrowserURL,
            clipboard: gatedClipboard,
            ocrText: ocrText.isEmpty ? nil : ocrText
        )
    }

    /// Background enrichment of `manifest.json.sensitivity` (SPEC §13.4).
    /// Static so it can be called from a detached Task without re-entering
    /// the actor.
    static func enrichSensitivity(
        analyzer: any SensitivityAnalyzing,
        packageURL: URL
    ) async {
        let masterURL = packageURL.appendingPathComponent("master.png")
        do {
            let tags = try await analyzer.analyze(fileURL: masterURL)
            try patchManifest(
                url: packageURL,
                with: ManifestSensitivityField(tags)
            )
        } catch {
            // Silent — SCA failures must never crash the capture loop.
        }
    }
}
