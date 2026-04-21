import Foundation

/// Removes the fuse-cleanup launch agent per SPEC §15.1.
///
/// NOTE: the *install* path belongs to hq-lq3 (a parallel worker). This
/// uninstaller is intentionally self-contained so we don't share module
/// state with that worktree. Once both land, the install module should
/// expose a matching uninstall entrypoint and this file can be thinned
/// down to a delegating wrapper.
public enum LaunchAgentUninstaller {

    public enum UninstallError: Error, Sendable, CustomStringConvertible {
        case removeFailed(String)

        public var description: String {
            switch self {
            case .removeFailed(let s): return "failed to remove launch agent: \(s)"
            }
        }
    }

    /// Outcome of an uninstall invocation. We surface both the unload
    /// status and the removal status so the CLI can print something
    /// meaningful even when the plist was already missing.
    public struct Result: Sendable, Equatable {
        public let plistExistedBefore: Bool
        public let plistRemoved: Bool
        public let unloadInvoked: Bool
        public let unloadExitCode: Int32?

        public init(
            plistExistedBefore: Bool,
            plistRemoved: Bool,
            unloadInvoked: Bool,
            unloadExitCode: Int32?
        ) {
            self.plistExistedBefore = plistExistedBefore
            self.plistRemoved = plistRemoved
            self.unloadInvoked = unloadInvoked
            self.unloadExitCode = unloadExitCode
        }
    }

    /// Attempts to unload and remove the launch agent plist.
    ///
    /// Behavior:
    /// - If `plistURL` does not exist: returns with `plistExistedBefore=false`,
    ///   `plistRemoved=false` and does not invoke `launchctl`. This is the
    ///   idempotent "already uninstalled" path.
    /// - If it exists: invokes `launchctl unload <plist>` best-effort
    ///   (non-zero exit is captured but not thrown — `launchctl` fails
    ///   when the agent isn't currently loaded, which is fine for our
    ///   purposes). Then removes the file.
    ///
    /// - Parameters:
    ///   - plistURL: Absolute path to the launch-agent plist. In production
    ///     this resolves via `CLIPaths.launchAgentPlistURL`; tests inject
    ///     a temp path.
    ///   - runLaunchctl: When `false`, skips the `launchctl unload` call
    ///     entirely. Tests default to `false` to avoid mutating system
    ///     launchd state; production defaults to `true`.
    public static func uninstall(
        plistURL: URL,
        runLaunchctl: Bool = true
    ) throws -> Result {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: plistURL.path)

        if !existed {
            return Result(
                plistExistedBefore: false,
                plistRemoved: false,
                unloadInvoked: false,
                unloadExitCode: nil
            )
        }

        var unloadInvoked = false
        var unloadExit: Int32?
        if runLaunchctl {
            unloadInvoked = true
            unloadExit = runUnload(plistURL: plistURL)
        }

        do {
            try fm.removeItem(at: plistURL)
        } catch {
            throw UninstallError.removeFailed(error.localizedDescription)
        }

        return Result(
            plistExistedBefore: true,
            plistRemoved: true,
            unloadInvoked: unloadInvoked,
            unloadExitCode: unloadExit
        )
    }

    /// Best-effort `launchctl unload <plist>`. Returns the exit code;
    /// errors launching the tool return `nil`. The return is purely
    /// informational — callers proceed regardless.
    private static func runUnload(plistURL: URL) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }
}
