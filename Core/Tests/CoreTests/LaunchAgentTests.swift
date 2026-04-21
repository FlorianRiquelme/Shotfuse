import Foundation
import Testing
@testable import Core

@Suite("LaunchAgentTests")
struct LaunchAgentTests {

    // MARK: - Test fixtures

    /// Creates a throwaway directory that will serve as a fake `$HOME` for
    /// a single test. Tests call `Self.cleanup(home)` in their `defer` block.
    private static func makeFakeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Convenience: a `shot` binary path that at least looks plausible.
    private static let fakeShotPath = "/Applications/Shotfuse.app/Contents/MacOS/shot"

    // MARK: - Mock launchctl

    /// Thread-safe mock runner. Records every invocation; answers with a
    /// programmable result so tests can exercise success, non-zero exit,
    /// and spawn failure.
    final class MockLaunchctl: LaunchctlRunning, @unchecked Sendable {
        struct Invocation: Equatable {
            let args: [String]
        }

        enum Response {
            case ok(stdout: String, stderr: String)
            case nonZero(exit: Int32, stderr: String)
            case spawnFailure(Error)
        }

        private let lock = NSLock()
        private var _invocations: [Invocation] = []
        private var _response: Response

        init(response: Response = .ok(stdout: "", stderr: "")) {
            self._response = response
        }

        var invocations: [Invocation] {
            lock.lock(); defer { lock.unlock() }
            return _invocations
        }

        func setResponse(_ r: Response) {
            lock.lock(); defer { lock.unlock() }
            self._response = r
        }

        func run(args: [String]) throws -> (stdout: String, stderr: String, exit: Int32) {
            lock.lock()
            _invocations.append(Invocation(args: args))
            let resp = _response
            lock.unlock()

            switch resp {
            case let .ok(stdout, stderr):
                return (stdout, stderr, 0)
            case let .nonZero(exit, stderr):
                return ("", stderr, exit)
            case let .spawnFailure(err):
                throw err
            }
        }
    }

    private struct SpawnError: Error, Equatable {
        let message: String
    }

    // MARK: - 1. expectedPlist shape

    @Test("expectedPlist has exactly the SPEC §15.1 keys and values")
    func expectedPlistMatchesSpec() throws {
        let dict = LaunchAgentSpec.expectedPlist(shotBinaryPath: Self.fakeShotPath)

        // Keys: exactly these four, no more no less.
        #expect(Set(dict.keys) == Set(["Label", "ProgramArguments", "StartInterval", "RunAtLoad"]))

        // Values.
        #expect(dict["Label"] as? String == "dev.friquelme.shotfuse.fuse")
        #expect(LaunchAgentSpec.identifier == "dev.friquelme.shotfuse.fuse")

        let args = dict["ProgramArguments"] as? [String]
        #expect(args == [Self.fakeShotPath, "system", "fuse-gc"])

        // StartInterval is an Int per spec (hourly).
        // PropertyListSerialization round-trips ints; we stored a plain Int literal.
        if let asInt = dict["StartInterval"] as? Int {
            #expect(asInt == 3600)
        } else {
            Issue.record("StartInterval must be Int, got \(type(of: dict["StartInterval"] ?? "nil"))")
        }

        #expect(dict["RunAtLoad"] as? Bool == true)
    }

    @Test("plistPath is <home>/Library/LaunchAgents/dev.friquelme.shotfuse.fuse.plist")
    func plistPathShape() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let url = LaunchAgentSpec.plistPath(home: home)
        #expect(url.lastPathComponent == "dev.friquelme.shotfuse.fuse.plist")
        #expect(url.deletingLastPathComponent().lastPathComponent == "LaunchAgents")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library")
        #expect(url.path.hasPrefix(home.path))
    }

    // MARK: - 2. Bytes on disk match expected serialization

    @Test("install writes plist to the expected path with exact serialized bytes")
    func installWritesExpectedBytes() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let mock = MockLaunchctl()
        let installer = LaunchAgentInstaller(runner: mock)

        try installer.install(shotBinaryPath: Self.fakeShotPath, home: home)

        let plistURL = LaunchAgentSpec.plistPath(home: home)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let actual = try Data(contentsOf: plistURL)
        let expected = try PropertyListSerialization.data(
            fromPropertyList: LaunchAgentSpec.expectedPlist(shotBinaryPath: Self.fakeShotPath),
            format: .xml,
            options: 0
        )
        #expect(actual == expected, "plist bytes on disk differ from PropertyListSerialization output")

        // And launchctl was asked to load exactly this file.
        #expect(mock.invocations == [.init(args: ["load", plistURL.path])])
    }

    @Test("install surfaces serialized bytes that round-trip to the expected dict")
    func installBytesRoundTrip() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let installer = LaunchAgentInstaller(runner: MockLaunchctl())
        try installer.install(shotBinaryPath: Self.fakeShotPath, home: home)

        let plistURL = LaunchAgentSpec.plistPath(home: home)
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any]

        #expect(format == .xml)
        #expect(parsed?["Label"] as? String == "dev.friquelme.shotfuse.fuse")
        #expect(parsed?["StartInterval"] as? Int == 3600)
        #expect(parsed?["RunAtLoad"] as? Bool == true)
        #expect(parsed?["ProgramArguments"] as? [String] == [Self.fakeShotPath, "system", "fuse-gc"])
    }

    // MARK: - 3. isInstalled flips

    @Test("isInstalled flips false→true after install, true→false after uninstall")
    func isInstalledFlips() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let mock = MockLaunchctl()
        let installer = LaunchAgentInstaller(runner: mock)

        #expect(installer.isInstalled(home: home) == false)

        try installer.install(shotBinaryPath: Self.fakeShotPath, home: home)
        #expect(installer.isInstalled(home: home) == true)

        try installer.uninstall(home: home)
        #expect(installer.isInstalled(home: home) == false)

        // uninstall called launchctl unload on the plist we just removed.
        let unloadCalls = mock.invocations.filter { $0.args.first == "unload" }
        #expect(unloadCalls.count == 1)
        #expect(unloadCalls.first?.args == ["unload", LaunchAgentSpec.plistPath(home: home).path])
    }

    // MARK: - 4. firstRun idempotency

    @Test("firstRun installs once, returns true; subsequent call returns false and does not re-install")
    func firstRunIsIdempotent() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let mock = MockLaunchctl()
        let installer = LaunchAgentInstaller(runner: mock)

        let first = try installer.firstRun(shotBinaryPath: Self.fakeShotPath, home: home)
        #expect(first == true)
        #expect(installer.isInstalled(home: home) == true)
        #expect(mock.invocations.count == 1)

        let second = try installer.firstRun(shotBinaryPath: Self.fakeShotPath, home: home)
        #expect(second == false)
        // No additional launchctl call on the no-op path.
        #expect(mock.invocations.count == 1)
    }

    // MARK: - 5. launchctl load failure → badge hook → rollback

    @Test("launchctl non-zero exit throws loadFailed and rolls back the plist")
    func launchctlNonZeroExitRollsBack() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let mock = MockLaunchctl(response: .nonZero(exit: 3, stderr: "Load failed: bad plist"))
        let installer = LaunchAgentInstaller(runner: mock)

        var thrown: LaunchAgentError?
        do {
            try installer.install(shotBinaryPath: Self.fakeShotPath, home: home)
            Issue.record("expected install to throw")
        } catch let e as LaunchAgentError {
            thrown = e
        }

        // Error content matches the runner's stderr and exit code.
        #expect(thrown == .loadFailed(exitCode: 3, stderr: "Load failed: bad plist"))

        // Rollback: plist must NOT exist after a failed load.
        let plistURL = LaunchAgentSpec.plistPath(home: home)
        #expect(FileManager.default.fileExists(atPath: plistURL.path) == false)
        #expect(installer.isInstalled(home: home) == false)
    }

    @Test("launchctl spawn failure throws loadFailed and rolls back the plist")
    func launchctlSpawnFailureRollsBack() throws {
        let home = try Self.makeFakeHome()
        defer { Self.cleanup(home) }

        let mock = MockLaunchctl(response: .spawnFailure(SpawnError(message: "ENOENT")))
        let installer = LaunchAgentInstaller(runner: mock)

        var threw = false
        do {
            try installer.install(shotBinaryPath: Self.fakeShotPath, home: home)
        } catch let e as LaunchAgentError {
            threw = true
            if case .loadFailed(let code, let stderr) = e {
                #expect(code == -1)
                #expect(stderr.contains("ENOENT") || !stderr.isEmpty)
            } else {
                Issue.record("wrong LaunchAgentError case: \(e)")
            }
        }
        #expect(threw)

        // Rollback.
        let plistURL = LaunchAgentSpec.plistPath(home: home)
        #expect(FileManager.default.fileExists(atPath: plistURL.path) == false)
    }
}
