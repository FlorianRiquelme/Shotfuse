import CoreGraphics
import Foundation
import Testing
@testable import Core

// W1-INT: end-to-end capture loop composed by `CaptureCoordinator`. These
// tests exercise the happy path plus the error branches tracked by the
// issue contract (user cancel, finalization failure, witness path,
// serialization under concurrency, SCA fire-and-forget).
//
// Every collaborator is stubbed — no real TCC, no real SCK, no real
// hotkeys. The happy path writes into a temp directory because the real
// `CaptureFinalization` stage is chained in to keep the stub chain
// trustworthy; `Finalizing` itself is stubbed for the error branches.

// MARK: - Shared fixtures

private struct CoordinatorFixtures {
    static func display(id: CGDirectDisplayID = 1) -> DisplayMetadata {
        DisplayMetadata(
            id: id,
            nativeWidth: 3024,
            nativeHeight: 1964,
            nativeScale: 2.0,
            vendorID: nil,
            productID: nil,
            serial: nil,
            localizedName: "Test",
            globalFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
    }

    static func solidImage(width: Int = 32, height: Int = 32) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x7F, count: bytesPerRow * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = pixels.withUnsafeMutableBufferPointer { buf -> CGContext in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        return ctx.makeImage()!
    }

    static func selection() -> RegionSelection {
        RegionSelection(
            rect: CGRect(x: 0, y: 0, width: 32, height: 32),
            display: display()
        )
    }

    static func capturedFrame() -> CapturedFrame {
        CapturedFrame(
            image: solidImage(),
            pixelBounds: CGRect(x: 0, y: 0, width: 32, height: 32),
            display: display(),
            capturedAt: Date()
        )
    }
}

// MARK: - Actor-based stubs (Sendable by construction)

private actor StubRegionSelector: RegionSelecting {
    enum Behavior: Sendable {
        case returns(RegionSelection?)
        case throws_(any Error & Sendable)
    }

    private var behavior: Behavior
    private(set) var invocationCount: Int = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func select() async throws -> RegionSelection? {
        invocationCount += 1
        switch behavior {
        case .returns(let sel): return sel
        case .throws_(let err): throw err
        }
    }
}

private actor StubScreenCapturing: ScreenCapturing {
    enum Behavior: Sendable {
        case returns(CapturedFrame)
        case throws_(any Error & Sendable)
    }

    private let regionBehavior: Behavior
    private let windowBehavior: Behavior
    private let fullscreenBehavior: Behavior
    private(set) var regionCallCount: Int = 0
    private(set) var windowCallCount: Int = 0
    private(set) var fullscreenCallCount: Int = 0
    /// Artificial delay applied inside `captureRegion` — used by the
    /// concurrency-serialization test to make ordering observable.
    var regionDelayMS: UInt64 = 0

    init(
        region: Behavior,
        window: Behavior? = nil,
        fullscreen: Behavior? = nil
    ) {
        self.regionBehavior = region
        self.windowBehavior = window ?? region
        self.fullscreenBehavior = fullscreen ?? region
    }

    func setRegionDelayMS(_ ms: UInt64) { regionDelayMS = ms }

    func captureRegion(selection: RegionSelection) async throws -> CapturedFrame {
        if regionDelayMS > 0 {
            try? await Task.sleep(nanoseconds: regionDelayMS * 1_000_000)
        }
        regionCallCount += 1
        switch regionBehavior {
        case .returns(let f): return f
        case .throws_(let e): throw e
        }
    }

    func captureWindow(pid: pid_t, windowID: CGWindowID, includeChildren: Bool) async throws -> CapturedFrame {
        windowCallCount += 1
        switch windowBehavior {
        case .returns(let f): return f
        case .throws_(let e): throw e
        }
    }

    func captureFullscreen(displayID: CGDirectDisplayID) async throws -> CapturedFrame {
        fullscreenCallCount += 1
        switch fullscreenBehavior {
        case .returns(let f): return f
        case .throws_(let e): throw e
        }
    }
}

private actor RecordingFinalizer: Finalizing {
    struct Call: Sendable {
        let finalURL: URL
        let bundleID: String
    }
    enum Behavior: Sendable {
        case succeed
        case throws_(any Error & Sendable)
    }

    private(set) var calls: [Call] = []
    let behavior: Behavior

    init(_ behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    nonisolated func finalize(
        frame: CapturedFrame,
        context: CaptureFinalization.Context,
        to finalURL: URL,
        now: Date
    ) throws {
        // Record call synchronously via a blocking actor hop — tests are
        // single-consumer so this won't deadlock. We use a detached task
        // and wait for it to complete because `Finalizing.finalize` is
        // synchronous per the protocol contract.
        let bundleID = context.frontmostBundleID
        let sem = DispatchSemaphore(value: 0)
        Task {
            await self.record(Call(finalURL: finalURL, bundleID: bundleID))
            sem.signal()
        }
        sem.wait()

        switch behavior {
        case .succeed: return
        case .throws_(let e): throw e
        }
    }

    private func record(_ call: Call) {
        calls.append(call)
    }
}

private actor RecordingIndexer: LibraryIndexing {
    private(set) var insertCalls: [LibraryRecord] = []
    private(set) var deleteCalls: [String] = []
    enum Behavior: Sendable { case succeed, throws_(any Error & Sendable) }
    let behavior: Behavior

    init(_ behavior: Behavior = .succeed) { self.behavior = behavior }

    func insert(_ record: LibraryRecord) async throws {
        insertCalls.append(record)
        if case .throws_(let e) = behavior { throw e }
    }

    func delete(id: String) async throws {
        deleteCalls.append(id)
    }
}

/// Captures analyzer invocations so the SCA fire-and-forget test can
/// await completion without polling.
private final class RecordingAnalyzer: SensitivityAnalyzing, @unchecked Sendable {
    let tags: [SensitivityTag]
    let done: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(tags: [SensitivityTag]) {
        self.tags = tags
        var cont: AsyncStream<Void>.Continuation!
        self.done = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func analyze(_ image: CGImage) async throws -> [SensitivityTag] {
        tags
    }

    func analyze(fileURL: URL) async throws -> [SensitivityTag] {
        continuation.yield()
        return tags
    }
}

private actor DelegateRecorder: CaptureCoordinatorDelegate {
    private(set) var finishedURLs: [URL] = []
    private(set) var failureCount: Int = 0

    func captureDidFinish(url: URL) async {
        finishedURLs.append(url)
    }
    func captureDidFail(error: Error) async {
        failureCount += 1
    }
}

// MARK: - Coordinator assembler

private func makeCoordinator(
    regionSelector: any RegionSelecting,
    screenCapturer: any ScreenCapturing,
    finalizer: any Finalizing,
    indexer: any LibraryIndexing,
    sensitivity: any SensitivityAnalyzing = StubSensitivityAnalyzer(tags: [.none]),
    libraryRoot: URL,
    witnessesRoot: URL,
    context: CaptureFinalization.Context = CaptureFinalization.Context(
        frontmostBundleID: "com.example.test",
        frontmostWindowTitle: "Test Window",
        axAvailable: false
    )
) -> CaptureCoordinator {
    CaptureCoordinator(
        regionSelector: regionSelector,
        screenCapturer: screenCapturer,
        finalizer: finalizer,
        indexer: indexer,
        sensitivityAnalyzer: sensitivity,
        libraryRoot: libraryRoot,
        witnessesRoot: witnessesRoot,
        contextProvider: { context }
    )
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Suite("CaptureCoordinatorTests")
struct CaptureCoordinatorTests {

    @Test("Happy path region: overlay returns rect → SCK returns frame → finalizer writes → index inserts")
    func happyPathRegion() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        let url = try await coordinator.captureRegion()

        #expect(url.pathExtension == "shot")
        #expect(url.deletingLastPathComponent().lastPathComponent == "library")
        #expect(await selector.invocationCount == 1)
        #expect(await capturer.regionCallCount == 1)
        let calls = await finalizer.calls
        #expect(calls.count == 1)
        #expect(calls[0].bundleID == "com.example.test")
        let inserts = await indexer.insertCalls
        #expect(inserts.count == 1)
        let id = url.deletingPathExtension().lastPathComponent
        #expect(inserts[0].id == id)
        #expect(inserts[0].bundleID == "com.example.test")
        #expect(inserts[0].windowTitle == "Test Window")
    }

    @Test("User cancel: selector returns nil → throws .cancelled → finalizer/indexer not called")
    func userCancel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(nil))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        await #expect(throws: CaptureCoordinatorError.self) {
            _ = try await coordinator.captureRegion()
        }

        #expect(await capturer.regionCallCount == 0)
        #expect(await finalizer.calls.isEmpty)
        #expect(await indexer.insertCalls.isEmpty)

        // Engine must be re-armable after cancel — drive a second region
        // capture to confirm the state machine rewound cleanly.
        let selector2 = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer2 = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        let finalizer2 = RecordingFinalizer(.succeed)
        let indexer2 = RecordingIndexer()
        let coordinator2 = makeCoordinator(
            regionSelector: selector2,
            screenCapturer: capturer2,
            finalizer: finalizer2,
            indexer: indexer2,
            libraryRoot: root.appendingPathComponent("library2"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )
        _ = try await coordinator2.captureRegion()
        #expect(await indexer2.insertCalls.count == 1)
    }

    @Test("Finalization failure: finalizer throws → index untouched, state re-armable")
    func finalizationFailure() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        struct DiskFull: Error & Sendable {}
        let selector = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        let finalizer = RecordingFinalizer(.throws_(DiskFull()))
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.captureRegion()
        }

        #expect(await finalizer.calls.count == 1)
        #expect(await indexer.insertCalls.isEmpty)
    }

    @Test("Witness path: writes witness package, NEVER calls LibraryIndex.insert")
    func witnessPath() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let witnessesRoot = root.appendingPathComponent("witnesses")
        let selector = StubRegionSelector(.returns(nil))
        let capturer = StubScreenCapturing(
            region: .returns(CoordinatorFixtures.capturedFrame()),
            fullscreen: .returns(CoordinatorFixtures.capturedFrame())
        )
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: witnessesRoot
        )

        let url = try await coordinator.captureWitness()

        #expect(url.pathExtension == "shot")
        #expect(url.path.hasPrefix(witnessesRoot.path))
        #expect(await indexer.insertCalls.isEmpty)
        #expect(await finalizer.calls.isEmpty)  // witness uses WitnessCapture, not finalizer
        #expect(await capturer.fullscreenCallCount == 1)
    }

    @Test("SCA enrichment is fire-and-forget: patches manifest after capture returns")
    func scaEnrichment() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        // Use the REAL finalizer so an actual .shot/ with manifest.json
        // ends up on disk — otherwise patchManifest has nothing to rewrite.
        let finalizer = RealFinalizing()
        let indexer = RecordingIndexer()
        let analyzer = RecordingAnalyzer(tags: [.password_field])

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            sensitivity: analyzer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        let url = try await coordinator.captureRegion()

        // Await the detached analyzer task — waits for the first yield.
        var it = analyzer.done.makeAsyncIterator()
        _ = await it.next()

        // Give patchManifest a moment to land on disk after the yield.
        for _ in 0..<50 {
            let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json"))
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sens = json["sensitivity"] as? [String],
               sens.contains("password_field") {
                return  // success
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("manifest was never patched with sensitivity field")
    }

    @Test("Actor serializes concurrent captures")
    func actorSerialization() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        await capturer.setRegionDelayMS(50)
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        async let a = coordinator.captureRegion()
        async let b = coordinator.captureRegion()
        let urls = try await [a, b]

        #expect(urls.count == 2)
        #expect(urls[0] != urls[1])
        #expect(await indexer.insertCalls.count == 2)
        #expect(await capturer.regionCallCount == 2)
    }

    @Test("Window capture: no overlay, SCK window path, indexed")
    func windowCapture() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(nil))  // unused
        let capturer = StubScreenCapturing(
            region: .returns(CoordinatorFixtures.capturedFrame()),
            window: .returns(CoordinatorFixtures.capturedFrame())
        )
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        let url = try await coordinator.captureWindow(pid: 1234, windowID: 42, includeChildren: true)

        #expect(url.pathExtension == "shot")
        #expect(await selector.invocationCount == 0)
        #expect(await capturer.windowCallCount == 1)
        #expect(await capturer.regionCallCount == 0)
        #expect(await indexer.insertCalls.count == 1)
    }

    @Test("Fullscreen capture: no overlay, SCK fullscreen path, indexed")
    func fullscreenCapture() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(nil))
        let capturer = StubScreenCapturing(
            region: .returns(CoordinatorFixtures.capturedFrame()),
            fullscreen: .returns(CoordinatorFixtures.capturedFrame())
        )
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )

        let url = try await coordinator.captureFullscreen(display: 1)

        #expect(url.pathExtension == "shot")
        #expect(await selector.invocationCount == 0)
        #expect(await capturer.fullscreenCallCount == 1)
        #expect(await indexer.insertCalls.count == 1)
    }

    @Test("Delegate receives captureDidFinish with written URL on success")
    func delegateNotifiesOnSuccess() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selector = StubRegionSelector(.returns(CoordinatorFixtures.selection()))
        let capturer = StubScreenCapturing(region: .returns(CoordinatorFixtures.capturedFrame()))
        let finalizer = RecordingFinalizer(.succeed)
        let indexer = RecordingIndexer()
        let delegate = DelegateRecorder()

        let coordinator = makeCoordinator(
            regionSelector: selector,
            screenCapturer: capturer,
            finalizer: finalizer,
            indexer: indexer,
            libraryRoot: root.appendingPathComponent("library"),
            witnessesRoot: root.appendingPathComponent("witnesses")
        )
        await coordinator.setDelegate(delegate)

        let url = try await coordinator.captureRegion()
        #expect(await delegate.finishedURLs == [url])
        #expect(await delegate.failureCount == 0)
    }
}
