import Foundation

/// A snapshot of the subsystems `shot system status` reports on.
///
/// Split out as a pure value so tests can assert the text contents
/// without invoking SCK / TCC — the CLI command layer is responsible
/// for resolving live state and feeding it into `render(...)`.
public struct SystemStatusReport: Sendable, Equatable {
    /// One of `"granted"`, `"denied"`, `"unknown"`.
    public let screenRecording: String
    public let accessibility: String
    /// Number of `.shot/` packages currently in the library.
    public let libraryRowCount: Int
    /// ISO-8601 timestamp of the last fuse-gc run, or `"unknown"`.
    public let fuseGCLastRun: String
    /// `"installed"` / `"missing"`.
    public let launchAgentStatus: String
    /// Resolved library path — shown verbatim so operators can spot a
    /// mis-configured `$SHOTFUSE_LIBRARY_ROOT`.
    public let libraryPath: String
    /// Resolved launch-agent plist path.
    public let launchAgentPath: String

    public init(
        screenRecording: String,
        accessibility: String,
        libraryRowCount: Int,
        fuseGCLastRun: String,
        launchAgentStatus: String,
        libraryPath: String,
        launchAgentPath: String
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.libraryRowCount = libraryRowCount
        self.fuseGCLastRun = fuseGCLastRun
        self.launchAgentStatus = launchAgentStatus
        self.libraryPath = libraryPath
        self.launchAgentPath = launchAgentPath
    }

    /// Fixed-width, greppable rendering. Keep this stable — the spec says
    /// `shot system status` must surface all gates and counts (§17.3) and
    /// downstream tooling is likely to consume the output.
    public func render() -> String {
        """
        Shotfuse status
          screen_recording : \(screenRecording)
          accessibility   : \(accessibility)
          library_rows    : \(libraryRowCount)
          library_path    : \(libraryPath)
          launch_agent    : \(launchAgentStatus)
          launch_agent_path: \(launchAgentPath)
          fuse_gc_last_run: \(fuseGCLastRun)
        """
    }
}

/// Assembles a `SystemStatusReport` from on-disk state only.
///
/// TCC state is left as `"unknown"` here because querying it correctly
/// requires AppKit / CGRequestScreenCaptureAccess which is a platform
/// side-effect we don't want to invoke from the CLI tool. The App target
/// can enrich these fields once it boots.
public enum SystemStatusReporter {

    public static func gather(
        libraryRoot: URL,
        launchAgentPlist: URL,
        screenRecording: String = "unknown",
        accessibility: String = "unknown",
        fuseGCLastRun: String = "unknown"
    ) -> SystemStatusReport {
        let rowCount = countPackages(at: libraryRoot)
        let agentExists = FileManager.default.fileExists(atPath: launchAgentPlist.path)
        return SystemStatusReport(
            screenRecording: screenRecording,
            accessibility: accessibility,
            libraryRowCount: rowCount,
            fuseGCLastRun: fuseGCLastRun,
            launchAgentStatus: agentExists ? "installed" : "missing",
            libraryPath: libraryRoot.path,
            launchAgentPath: launchAgentPlist.path
        )
    }

    /// Counts direct-child `.shot/` packages. Missing directory → 0.
    /// Errors during enumeration → 0 (status never fails the process).
    private static func countPackages(at libraryRoot: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryRoot.path) else { return 0 }
        guard let packages = try? PackageScanner().scan(libraryRoot) else { return 0 }
        return packages.count
    }
}
