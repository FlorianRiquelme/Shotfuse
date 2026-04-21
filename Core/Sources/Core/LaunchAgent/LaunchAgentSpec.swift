import Foundation

/// Static description of the Shotfuse fuse-gc launch agent per SPEC §15.1.
///
/// This type is pure data — no side effects, no I/O. The installer
/// (`LaunchAgentInstaller`) is responsible for writing/loading the plist.
///
/// Contract (SPEC §15.1):
/// - Identifier: `dev.friquelme.shotfuse.fuse`
/// - Plist path: `~/Library/LaunchAgents/dev.friquelme.shotfuse.fuse.plist`
/// - StartInterval: `3600` (hourly)
/// - ProgramArguments: `[<shot-binary-path>, system, fuse-gc]`
/// - RunAtLoad: `true`
public enum LaunchAgentSpec {

    /// Reverse-DNS identifier for the launch agent. Matches the `Label`
    /// key in the plist and is also used to name the plist file itself.
    public static let identifier: String = "dev.friquelme.shotfuse.fuse"

    /// Canonical on-disk location for the launch-agent plist under a user's
    /// home directory: `<home>/Library/LaunchAgents/<identifier>.plist`.
    ///
    /// - Parameter home: User home directory. Injectable so tests can point
    ///   at a temporary sandbox without touching the real `~/Library`.
    /// - Returns: Absolute URL to the plist file (which may or may not exist).
    public static func plistPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(identifier).plist", isDirectory: false)
    }

    /// The exact dictionary that SPEC §15.1 mandates be serialized into the
    /// launch-agent plist. Callers pass the absolute path to the `shot`
    /// binary that `launchd` should run every hour.
    ///
    /// Keys (verbatim, no additions):
    /// - `Label` — `LaunchAgentSpec.identifier`
    /// - `ProgramArguments` — `[<shot-binary-path>, "system", "fuse-gc"]`
    /// - `StartInterval` — `3600` (hourly, per spec)
    /// - `RunAtLoad` — `true`
    ///
    /// The return type is `[String: Any]` because `PropertyListSerialization`
    /// accepts an untyped dictionary and handles stable key ordering
    /// internally for the `xml1` format we target.
    public static func expectedPlist(shotBinaryPath: String) -> [String: Any] {
        [
            "Label": identifier,
            "ProgramArguments": [shotBinaryPath, "system", "fuse-gc"],
            "StartInterval": 3600,
            "RunAtLoad": true,
        ]
    }
}
