import Foundation

/// Path-resolution helpers for the `shot` CLI.
///
/// Each resolver accepts an explicit precedence:
/// 1. An environment-variable override (documented per-field) — used by
///    tests and by cooperative multi-process setups.
/// 2. The SPEC default under `~/.shotfuse/`.
///
/// These live in `Core/CLIHelpers/` rather than `Core/Library/` because the
/// CLI is the only caller — Library owns `index.db`, not the filesystem
/// layout around it.
public enum CLIPaths {

    /// Shotfuse root: `$SHOTFUSE_ROOT` or `~/.shotfuse/`.
    public static func rootDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SHOTFUSE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".shotfuse", isDirectory: true)
    }

    /// Library directory: `$SHOTFUSE_LIBRARY_ROOT` or `<root>/library/`.
    /// Matches the precedence used by `runFuseGC` in the CLI.
    public static func libraryRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SHOTFUSE_LIBRARY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return rootDirectory(environment: environment)
            .appendingPathComponent("library", isDirectory: true)
    }

    /// Index DB path: `$SHOTFUSE_INDEX_DB` or `<root>/index.db`.
    public static func indexDatabaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SHOTFUSE_INDEX_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return rootDirectory(environment: environment)
            .appendingPathComponent("index.db")
    }

    /// Launch-agent plist path: `$SHOTFUSE_LAUNCH_AGENT_PATH` or
    /// `~/Library/LaunchAgents/dev.friquelme.shotfuse.fuse.plist` per SPEC §15.1.
    public static func launchAgentPlistURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SHOTFUSE_LAUNCH_AGENT_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(LaunchAgentSpec.identifier).plist")
    }

    /// Launch-agent identifier + absolute plist path per SPEC §15.1. Kept
    /// here (not in a LaunchAgent helper module) because hq-lq3 owns that
    /// module in parallel; uninstall needs the constants directly.
    public enum LaunchAgentSpec {
        /// SPEC §15.1 Identifier.
        public static let identifier = "dev.friquelme.shotfuse.fuse"
    }
}
