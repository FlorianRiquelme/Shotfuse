import Foundation
import Testing
@testable import Core

// MARK: - Test Doubles

/// Mock `ObsidianOpener` for Router tests.
actor MockObsidianOpener: ObsidianOpener {
    var shouldSucceed: Bool
    var openedURLs: [URL] = []
    var errorToThrow: Error?

    init(shouldSucceed: Bool = true, errorToThrow: Error? = nil) {
        self.shouldSucceed = shouldSucceed
        self.errorToThrow = errorToThrow
    }

    func open(_ url: URL) async throws {
        if let error = errorToThrow {
            throw error
        }
        if !shouldSucceed {
            struct MockError: Error, LocalizedError {
                var errorDescription: String? { "MockObsidianOpener failed to open URL." }
            }
            throw MockError()
        }
        openedURLs.append(url)
    }
}

/// A thin file-system probe that operates against a real on-disk temp
/// directory. It is `Sendable` (via internal locking) and supports an
/// optional writability override so tests can simulate EACCES without
/// actually `chmod`-ing on the host filesystem.
final class DiskBackedFileSystemProbe: FileSystemProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var writabilityOverride: [String: Bool] = [:]

    private static func canonicalize(_ path: String) -> String {
        // Strip trailing slash so `.../screenshots` and `.../screenshots/` collapse.
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    func setWritable(_ url: URL, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        writabilityOverride[Self.canonicalize(url.path)] = value
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    func isWritableFile(atPath path: String) -> Bool {
        lock.lock()
        if let override = writabilityOverride[Self.canonicalize(path)] {
            lock.unlock()
            return override
        }
        lock.unlock()
        return FileManager.default.isWritableFile(atPath: path)
    }

    func isWritableDirectory(atPath path: String) -> Bool {
        lock.lock()
        if let override = writabilityOverride[Self.canonicalize(path)] {
            lock.unlock()
            return override
        }
        lock.unlock()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return FileManager.default.isWritableFile(atPath: path)
        }
        return false
    }

    func currentDirectoryURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func homeDirectoryForCurrentUser() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.moveItem(at: srcURL, to: dstURL)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.copyItem(at: srcURL, to: dstURL)
    }

    func fileSize(at url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return attrs[.size] as? UInt64 ?? 0
    }

    func fileHandle(forWritingTo url: URL) throws -> FileHandle {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        } else {
            // Truncate
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        return try FileHandle(forWritingTo: url)
    }

    func fileHandle(forUpdating url: URL) throws -> FileHandle {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        return try FileHandle(forUpdating: url)
    }
}

// MARK: - Helpers

private func makeTempDirectory() -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RouterTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
}

private func makeShotPackage(in root: URL, id: String = UUID().uuidString, masterData: Data = Data("png-bytes".utf8)) throws -> URL {
    let packageURL = root.appendingPathComponent(id).appendingPathExtension("shot")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try masterData.write(to: packageURL.appendingPathComponent("master.png"))
    return packageURL
}

private func readLastTelemetry(telemetryURL: URL) throws -> [String: Any]? {
    let data = try Data(contentsOf: telemetryURL)
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline)
    guard let last = lines.last, let lineData = last.data(using: .utf8) else { return nil }
    return try JSONSerialization.jsonObject(with: lineData) as? [String: Any]
}

// MARK: - RouterTests

@Suite("Router Tests")
struct RouterTests {

    @Test("Xcode + gitRoot -> projectScreenshots auto-delivery")
    func testXcodeGitRootAutoDeliver() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        let gitRoot = tempTestDirectory.appendingPathComponent("test-repo")
        try probe.createDirectory(at: gitRoot, withIntermediateDirectories: true, attributes: nil)
        let captureID = UUID().uuidString
        let packageURL = try makeShotPackage(in: tempTestDirectory, id: captureID, masterData: Data("project-png".utf8))

        let context = RouterContext(
            id: captureID,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "MyProject - ViewController.swift",
            gitRoot: gitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)

        #expect(prediction.top.dest == .projectScreenshots(gitRootName: "test-repo"))
        #expect(prediction.top.score == 0.95)
        #expect(prediction.shouldAutoDeliver == true)
        #expect(prediction.all.count == 3)

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto, packageURL: packageURL)
        #expect(outcome.chosen == .projectScreenshots(gitRootName: "test-repo"))
        #expect(outcome.sideEffectResult == .handled(.projectScreenshots(gitRootName: "test-repo")))

        let expectedProjectScreenshotsDir = gitRoot.appendingPathComponent("screenshots")
        let expectedProjectScreenshot = expectedProjectScreenshotsDir.appendingPathComponent("\(captureID).png")
        #expect(probe.fileExists(atPath: expectedProjectScreenshotsDir.path))
        #expect(probe.fileExists(atPath: expectedProjectScreenshot.path))
        #expect(try Data(contentsOf: expectedProjectScreenshot) == Data("project-png".utf8))

        let telemetryURL = tempTestDirectory.appendingPathComponent(".shotfuse").appendingPathComponent("telemetry.jsonl")
        let json = try readLastTelemetry(telemetryURL: telemetryURL)
        #expect(json?["predicted"] as? String == "project_screenshots")
        #expect(json?["chosen"] as? String == "project_screenshots")
        #expect(json?["top_score"] as? Double == 0.95)
    }

    @Test("Obsidian -> obsidianDaily auto-delivery")
    func testObsidianAutoDeliver() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        let captureID = UUID().uuidString
        let packageURL = try makeShotPackage(in: tempTestDirectory, id: captureID)
        let masterURL = packageURL.appendingPathComponent("master.png")

        let context = RouterContext(
            id: captureID,
            bundleID: "md.obsidian",
            windowTitle: "Daily Note",
            gitRoot: nil,
            frontmostHasObsidianURL: true,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)

        #expect(prediction.top.dest == .obsidianDaily)
        #expect(prediction.top.score == 0.90)
        #expect(prediction.shouldAutoDeliver == true)

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto, packageURL: packageURL)
        #expect(outcome.chosen == .obsidianDaily)
        #expect(outcome.sideEffectResult == .handled(.obsidianDaily))

        let openedURLs = await mockOpener.openedURLs
        #expect(openedURLs.count == 1)
        let opened = try #require(openedURLs.first)
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "obsidian")
        #expect(components.host == "daily")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(items["append"] == "true")
        #expect(items["content"]?.contains(masterURL.absoluteString) == true)

        let telemetryURL = tempTestDirectory.appendingPathComponent(".shotfuse").appendingPathComponent("telemetry.jsonl")
        let json = try readLastTelemetry(telemetryURL: telemetryURL)
        #expect(json?["predicted"] as? String == "obsidian_daily")
        #expect(json?["chosen"] as? String == "obsidian_daily")
        #expect(json?["top_score"] as? Double == 0.9)
    }

    @Test("Unwritable target -> fallback to clipboard")
    func testUnwritableTargetFallback() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()

        let projectsDir = tempTestDirectory.appendingPathComponent("Projects")
        let targetGitRoot = projectsDir.appendingPathComponent("unwritable-repo")
        let targetScreenshotsDir = targetGitRoot.appendingPathComponent("screenshots")

        try probe.createDirectory(at: targetScreenshotsDir, withIntermediateDirectories: true, attributes: nil)
        probe.setWritable(targetScreenshotsDir, false)

        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )
        let packageURL = try makeShotPackage(in: tempTestDirectory)

        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "Forbidden Project",
            gitRoot: targetGitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory,
            projectsDirectory: projectsDir
        )

        let prediction = await router.predict(context)
        #expect(prediction.top.dest == .projectScreenshots(gitRootName: "unwritable-repo"))

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto, packageURL: packageURL)

        #expect(outcome.chosen == .projectScreenshots(gitRootName: "unwritable-repo"))
        #expect(outcome.sideEffectResult == .fellBackToClipboard(reason: .notWritable))
    }

    @Test("Telemetry line audit: exactly 6 keys, correct shape")
    func testTelemetryLineAudit() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "My Project",
            gitRoot: tempTestDirectory.appendingPathComponent("my-repo"),
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)
        _ = try await router.decide(context: context, prediction: prediction, hostDecision: .auto)

        let telemetryURL = tempTestDirectory.appendingPathComponent(".shotfuse").appendingPathComponent("telemetry.jsonl")
        let json = try readLastTelemetry(telemetryURL: telemetryURL)
        #expect(json != nil)

        guard let json else {
            Issue.record("Failed to parse telemetry JSON")
            return
        }

        #expect(json.count == 6)

        let expectedKeys: Set<String> = ["id", "ts", "predicted", "chosen", "top_score", "second_score"]
        #expect(Set(json.keys) == expectedKeys)

        let forbiddenKeys: Set<String> = ["ocr", "text", "clipboard", "bundle_id", "path", "git_root", "window_title"]
        let actualKeys = Set(json.keys)
        #expect(actualKeys.intersection(forbiddenKeys).isEmpty)

        let validSlugs: Set<String> = ["clipboard", "project_screenshots", "obsidian_daily"]
        #expect(validSlugs.contains(json["predicted"] as? String ?? ""))
        #expect(validSlugs.contains(json["chosen"] as? String ?? ""))

        #expect(json["id"] is String)
        #expect(json["ts"] is String)
        #expect(json["top_score"] is Double)
        #expect(json["second_score"] is Double)
    }

    @Test("Telemetry file rotation at 10 MB, keep 2")
    func testTelemetryRotation() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        let telemetryDir = tempTestDirectory.appendingPathComponent(".shotfuse")
        try probe.createDirectory(at: telemetryDir, withIntermediateDirectories: true, attributes: nil)
        let telemetryFileURL = telemetryDir.appendingPathComponent("telemetry.jsonl")
        let telemetry1FileURL = telemetryDir.appendingPathComponent("telemetry.1.jsonl")
        let telemetry2FileURL = telemetryDir.appendingPathComponent("telemetry.2.jsonl")

        let threshold: UInt64 = 10 * 1024 * 1024

        /// Writes a zero-padded file so the telemetry rotation check sees a
        /// file >= 10 MB and triggers rotation on the next `appendTelemetry`.
        /// Much faster than spamming tens of thousands of real log lines.
        func preloadTelemetryAboveThreshold() throws {
            let blob = Data(count: Int(threshold) + 1024)
            try blob.write(to: telemetryFileURL)
        }

        // --- First rotation ---
        try preloadTelemetryAboveThreshold()
        #expect(try probe.fileSize(at: telemetryFileURL) >= threshold)

        await router.appendTelemetry(line: RouterTelemetryLine(
            id: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            predicted: "clipboard", chosen: "clipboard", top_score: 0.1, second_score: 0.0
        ))

        #expect(probe.fileExists(atPath: telemetryFileURL.path))
        #expect(probe.fileExists(atPath: telemetry1FileURL.path))
        #expect(try probe.fileSize(at: telemetryFileURL) < threshold)
        #expect(try probe.fileSize(at: telemetry1FileURL) >= threshold)

        // --- Second rotation: preload again so .2 gets the ".1" of before. ---
        try preloadTelemetryAboveThreshold()
        #expect(try probe.fileSize(at: telemetryFileURL) >= threshold)

        await router.appendTelemetry(line: RouterTelemetryLine(
            id: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            predicted: "clipboard", chosen: "clipboard", top_score: 0.1, second_score: 0.0
        ))

        #expect(try probe.fileSize(at: telemetryFileURL) < threshold)
        #expect(try probe.fileSize(at: telemetry1FileURL) >= threshold)
        #expect(probe.fileExists(atPath: telemetry2FileURL.path))
        #expect(try probe.fileSize(at: telemetry2FileURL) >= threshold)

        let telemetry3FileURL = telemetryDir.appendingPathComponent("telemetry.3.jsonl")
        #expect(!probe.fileExists(atPath: telemetry3FileURL.path))
    }

    @Test("Router scoring tie-breaking")
    func testScoringTieBreaking() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        // Scenario 1: Only Clipboard is relevant.
        var context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.random.app",
            windowTitle: "Some Window",
            gitRoot: nil,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )
        var prediction = await router.predict(context)
        #expect(prediction.top.dest == .clipboard)
        #expect(prediction.top.score == 0.1)
        #expect(prediction.second.dest == .obsidianDaily)
        #expect(prediction.second.score == 0.0)
        #expect(prediction.shouldAutoDeliver == false)

        // Scenario 2: Project Screenshots wins.
        let gitRoot = tempTestDirectory.appendingPathComponent("another-repo")
        try probe.createDirectory(at: gitRoot, withIntermediateDirectories: true, attributes: nil)
        context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "Xcode Window",
            gitRoot: gitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )
        prediction = await router.predict(context)
        #expect(prediction.top.dest == .projectScreenshots(gitRootName: "another-repo"))
        #expect(prediction.top.score == 0.95)
        // Second is whichever destination has the next highest score — here
        // Clipboard's 0.1 beats Obsidian's 0.0.
        #expect(prediction.second.dest == .clipboard)
        #expect(prediction.second.score == 0.1)
        #expect(prediction.shouldAutoDeliver == true)

        // Scenario 3: Obsidian wins.
        context = RouterContext(
            id: UUID().uuidString,
            bundleID: "md.obsidian",
            windowTitle: "Obsidian Daily",
            gitRoot: nil,
            frontmostHasObsidianURL: true,
            homeDirectory: tempTestDirectory
        )
        prediction = await router.predict(context)
        #expect(prediction.top.dest == .obsidianDaily)
        #expect(prediction.top.score == 0.90)
        // Clipboard(0.1) > Project(0.0) — Clipboard is runner-up.
        #expect(prediction.second.dest == .clipboard)
        #expect(prediction.second.score == 0.1)
        #expect(prediction.shouldAutoDeliver == true)
    }

    @Test("Obsidian opener failure -> fellBackToClipboard(.obsidianOpenFailed)")
    func testObsidianOpenerFallback() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener(shouldSucceed: false, errorToThrow: URLError(.cannotOpenFile))
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )
        let packageURL = try makeShotPackage(in: tempTestDirectory)

        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "md.obsidian",
            windowTitle: "Daily Note",
            gitRoot: nil,
            frontmostHasObsidianURL: true,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)
        #expect(prediction.top.dest == .obsidianDaily)
        #expect(prediction.top.score == 0.90)
        #expect(prediction.shouldAutoDeliver == true)

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto, packageURL: packageURL)
        #expect(outcome.chosen == .obsidianDaily)
        #expect(outcome.sideEffectResult == .fellBackToClipboard(reason: .obsidianOpenFailed))
    }

    @Test("projectScreenshots side-effect with unwritable parent")
    func testProjectScreenshotsUnwritableHomeDir() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()

        let gitRoot = tempTestDirectory.appendingPathComponent("code-repo")
        let screenshotsDir = gitRoot.appendingPathComponent("screenshots")

        try probe.createDirectory(at: screenshotsDir, withIntermediateDirectories: true, attributes: nil)
        probe.setWritable(gitRoot, false)
        probe.setWritable(screenshotsDir, false)

        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )
        let packageURL = try makeShotPackage(in: tempTestDirectory)

        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "My Code",
            gitRoot: gitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory,
            projectsDirectory: tempTestDirectory.appendingPathComponent("Projects")
        )

        let prediction = await router.predict(context)
        #expect(prediction.top.dest == .projectScreenshots(gitRootName: "code-repo"))

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto, packageURL: packageURL)
        #expect(outcome.chosen == .projectScreenshots(gitRootName: "code-repo"))
        if case .fellBackToClipboard = outcome.sideEffectResult {
            // Expected.
        } else {
            Issue.record("Expected fallback to clipboard when parent directory is unwritable.")
        }
    }

    @Test("User-chosen destination from chooser overrides prediction")
    func testUserChoseFromChooser() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let mockOpener = MockObsidianOpener()
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: mockOpener
        )

        let gitRoot = tempTestDirectory.appendingPathComponent("another-repo")
        try probe.createDirectory(at: gitRoot, withIntermediateDirectories: true, attributes: nil)
        let captureID = UUID().uuidString
        let packageURL = try makeShotPackage(in: tempTestDirectory, id: captureID)

        let context = RouterContext(
            id: captureID,
            bundleID: "com.random.app",
            windowTitle: "Generic Window",
            gitRoot: gitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)
        #expect(prediction.shouldAutoDeliver == false)

        let chosenDest: RouterDestination = .projectScreenshots(gitRootName: "another-repo")
        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .userChoseFromChooser(chosenDest), packageURL: packageURL)

        #expect(outcome.chosen == chosenDest)
        #expect(outcome.sideEffectResult == .handled(chosenDest))

        let expectedProjectScreenshotsDir = gitRoot.appendingPathComponent("screenshots")
        let expectedProjectScreenshot = expectedProjectScreenshotsDir.appendingPathComponent("\(captureID).png")
        #expect(probe.fileExists(atPath: expectedProjectScreenshotsDir.path))
        #expect(probe.fileExists(atPath: expectedProjectScreenshot.path))

        let telemetryURL = tempTestDirectory.appendingPathComponent(".shotfuse").appendingPathComponent("telemetry.jsonl")
        let json = try readLastTelemetry(telemetryURL: telemetryURL)
        #expect(json?["predicted"] as? String == "clipboard")
        #expect(json?["chosen"] as? String == "project_screenshots")
    }

    @Test("IDE without gitRoot does not offer invalid project destination")
    func testNoProjectDestinationWhenGitRootMissing() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: DiskBackedFileSystemProbe(),
            obsidianOpener: MockObsidianOpener()
        )

        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "Unsaved.swift",
            gitRoot: nil,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )

        let prediction = await router.predict(context)
        #expect(!prediction.all.contains { entry in
            if case .projectScreenshots = entry.dest { return true }
            return false
        })
        #expect(prediction.top.dest == .clipboard)
        #expect(prediction.all.map(\.dest) == [.clipboard, .obsidianDaily])
    }

    @Test("Fallback outcome has UI-visible clipboard wording")
    func testFallbackOutcomeHumanName() {
        let result = RouterSideEffectResult.fellBackToClipboard(reason: .notWritable)

        #expect(result.deliveredDestination == .clipboard)
        #expect(result.humanName.contains("Clipboard"))
        #expect(result.humanName.contains("destination not writable"))
    }

    @Test("Missing package falls back visibly instead of pretending delivery succeeded")
    func testMissingPackageFallbackOutcome() async throws {
        let tempTestDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempTestDirectory) }
        let probe = DiskBackedFileSystemProbe()
        let router = Router(
            telemetryDirectory: tempTestDirectory.appendingPathComponent(".shotfuse"),
            fileSystem: probe,
            obsidianOpener: MockObsidianOpener()
        )

        let gitRoot = tempTestDirectory.appendingPathComponent("missing-package-repo")
        try probe.createDirectory(at: gitRoot, withIntermediateDirectories: true, attributes: nil)
        let context = RouterContext(
            id: UUID().uuidString,
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "Missing Package",
            gitRoot: gitRoot,
            frontmostHasObsidianURL: false,
            homeDirectory: tempTestDirectory
        )
        let prediction = await router.predict(context)

        let outcome = try await router.decide(context: context, prediction: prediction, hostDecision: .auto)

        #expect(outcome.sideEffectResult == .fellBackToClipboard(reason: .missingCapture))
        #expect(outcome.sideEffectResult.humanName.contains("capture file missing"))
    }
}
