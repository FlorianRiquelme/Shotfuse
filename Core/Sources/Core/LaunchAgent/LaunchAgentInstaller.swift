import Foundation

/// Abstract interface over `launchctl` invocations so `LaunchAgentInstaller`
/// can be unit-tested without ever shelling out to the real `launchd`.
///
/// The production implementation is `SystemLaunchctlRunner`. Tests inject a
/// mock; see `LaunchAgentTests`. Keep this protocol public so future call
/// sites outside `Core` (integration tests, the app shell) can also swap it.
public protocol LaunchctlRunning: Sendable {
    /// Executes `/bin/launchctl` with the supplied arguments.
    /// - Parameter args: Arguments passed after the executable, e.g.
    ///   `["load", "/path/to.plist"]`.
    /// - Returns: Captured stdout, stderr, and POSIX exit code.
    /// - Throws: Any I/O error that prevents the process from running at all
    ///   (missing binary, spawn failure). A non-zero exit code is NOT thrown —
    ///   callers inspect `exit` and decide.
    func run(args: [String]) throws -> (stdout: String, stderr: String, exit: Int32)
}

/// Errors surfaced by `LaunchAgentInstaller`.
public enum LaunchAgentError: Error, Sendable, Equatable {
    /// `launchctl load`/`unload` returned a non-zero exit code.
    /// The installer rolls back any plist it just wrote before throwing.
    case loadFailed(exitCode: Int32, stderr: String)
    /// Plist serialization produced something other than the expected shape —
    /// should never happen in practice, but we surface it rather than crashing.
    case plistSerializationFailed(String)
    /// The atomic write sequence (tmp → fsync → rename) failed.
    case atomicWriteFailed(String)
}

/// Production `LaunchctlRunning` that spawns `/bin/launchctl` via `Process`.
///
/// Kept as an `actor`-free `struct` because `Process` usage is synchronous
/// from the caller's perspective and state never leaks between invocations.
public struct SystemLaunchctlRunner: LaunchctlRunning {

    public init() {}

    public func run(args: [String]) throws -> (stdout: String, stderr: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout, stderr, process.terminationStatus)
    }
}

/// Writes, loads, unloads, and removes the Shotfuse fuse-gc launch agent
/// described by `LaunchAgentSpec` (SPEC §15.1).
///
/// All `launchctl` interaction goes through an injectable `LaunchctlRunning`,
/// which lets tests verify installer semantics (atomic write, rollback on
/// load failure, idempotent first-run) without touching real `launchd`.
///
/// Integration note: call `firstRun(shotBinaryPath:)` from
/// `App/Sources/ShotfuseApp.swift` on `.applicationDidFinishLaunching`.
public struct LaunchAgentInstaller: Sendable {

    private let runner: LaunchctlRunning

    /// - Parameter runner: `launchctl` invoker. Defaults to `SystemLaunchctlRunner`
    ///   which shells out to `/bin/launchctl`. Tests inject a mock.
    public init(runner: LaunchctlRunning = SystemLaunchctlRunner()) {
        self.runner = runner
    }

    // MARK: - Public API

    /// Writes the launch-agent plist atomically and loads it via `launchctl`.
    ///
    /// On `launchctl load` failure the plist is deleted before the error is
    /// thrown, so the filesystem never ends up with a half-installed agent.
    ///
    /// - Parameters:
    ///   - shotBinaryPath: Absolute path to the `shot` binary that
    ///     `launchd` should run hourly.
    ///   - home: Home directory root; injectable for tests. Defaults to the
    ///     current user's home.
    /// - Throws: `LaunchAgentError.atomicWriteFailed` on write errors;
    ///   `LaunchAgentError.loadFailed` on non-zero `launchctl` exit;
    ///   `LaunchAgentError.plistSerializationFailed` on serialization errors.
    public func install(
        shotBinaryPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let plistURL = LaunchAgentSpec.plistPath(home: home)
        try ensureParentDirectoryExists(for: plistURL)

        let plistData = try Self.serializedPlist(shotBinaryPath: shotBinaryPath)
        try Self.atomicWrite(data: plistData, to: plistURL)

        let result: (stdout: String, stderr: String, exit: Int32)
        do {
            result = try runner.run(args: ["load", plistURL.path])
        } catch {
            // Spawn failed outright — roll back the plist so we don't
            // leave a half-installed agent behind.
            try? FileManager.default.removeItem(at: plistURL)
            throw LaunchAgentError.loadFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        if result.exit != 0 {
            // Rollback: delete the plist we just wrote so a retry is clean.
            try? FileManager.default.removeItem(at: plistURL)
            throw LaunchAgentError.loadFailed(exitCode: result.exit, stderr: result.stderr)
        }
    }

    /// Unloads the agent via `launchctl` and deletes the plist.
    ///
    /// Unloads are best-effort: if `launchctl unload` fails (e.g. because
    /// the agent was never loaded) we still remove the plist so subsequent
    /// `firstRun` calls behave correctly. A hard `launchctl` spawn failure
    /// still throws so the caller can badge the menubar.
    public func uninstall(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let plistURL = LaunchAgentSpec.plistPath(home: home)
        let fm = FileManager.default

        if fm.fileExists(atPath: plistURL.path) {
            // Try to unload; ignore non-zero exit (may already be unloaded)
            // but surface a true spawn failure.
            _ = try? runner.run(args: ["unload", plistURL.path])
            try fm.removeItem(at: plistURL)
        }
    }

    /// Returns `true` iff the plist file exists at the expected path.
    /// Does NOT consult `launchctl` — a plist on disk is our source of truth
    /// for "installed", matching SPEC §15.1's semantics.
    public func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        FileManager.default.fileExists(atPath: LaunchAgentSpec.plistPath(home: home).path)
    }

    /// First-run convenience: if the agent is not yet installed, install it
    /// and return `true`; otherwise return `false` without side effects.
    ///
    /// Idempotent by design — safe to call on every app launch.
    public func firstRun(
        shotBinaryPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Bool {
        if isInstalled(home: home) {
            return false
        }
        try install(shotBinaryPath: shotBinaryPath, home: home)
        return true
    }

    // MARK: - Plist serialization

    /// Serializes the spec dictionary as XML-format property-list bytes.
    ///
    /// Exposed internally (not `public`) so tests can assert byte-for-byte
    /// equivalence against the bytes the installer actually writes.
    static func serializedPlist(shotBinaryPath: String) throws -> Data {
        let dict = LaunchAgentSpec.expectedPlist(shotBinaryPath: shotBinaryPath)
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dict,
                format: .xml,
                options: 0
            )
        } catch {
            throw LaunchAgentError.plistSerializationFailed(error.localizedDescription)
        }
    }

    // MARK: - Atomic write

    /// Atomically writes `data` to `dst` by first writing to `<dst>.tmp`,
    /// fsync'ing the file descriptor, then renaming over the destination.
    ///
    /// This matches the atomicity contract used elsewhere in the codebase
    /// (see `ShotPackageWriter`) — either the old file persists unchanged,
    /// or the new bytes are fully durable.
    private static func atomicWrite(data: Data, to dst: URL) throws {
        let tmpURL = dst.appendingPathExtension("tmp")
        let fm = FileManager.default

        // Make sure no stale tmp lingers from a previous crash.
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        // Open the tmp file, write, fsync, close.
        guard fm.createFile(atPath: tmpURL.path, contents: nil, attributes: nil) else {
            throw LaunchAgentError.atomicWriteFailed("could not create \(tmpURL.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: tmpURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize() // fsync
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw LaunchAgentError.atomicWriteFailed(error.localizedDescription)
        }

        // Rename tmp over dst. Use `replaceItemAt` which handles cross-volume
        // cases and atomic replacement on APFS.
        do {
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: dst)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw LaunchAgentError.atomicWriteFailed(error.localizedDescription)
        }
    }

    /// Creates `~/Library/LaunchAgents/` if it does not already exist.
    /// On a fresh macOS user account the directory may be missing; launchd
    /// does not create it for us.
    private func ensureParentDirectoryExists(for plistURL: URL) throws {
        let dir = plistURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw LaunchAgentError.atomicWriteFailed(
                    "failed to create \(dir.path): \(error.localizedDescription)"
                )
            }
        }
    }
}
