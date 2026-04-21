import Foundation

/// Produces a `.tar.gz` archive of the Shotfuse library directory,
/// deliberately EXCLUDING `telemetry.jsonl` (SPEC §13.5 privacy).
///
/// Implemented by shelling out to `/usr/bin/tar` — macOS's system tar is
/// BSD tar, which supports `--exclude`. Using the system binary keeps us
/// out of the archiving business and guarantees correct permission /
/// symlink handling.
public enum LibraryExporter {

    public enum ExportError: Error, Sendable, CustomStringConvertible {
        case sourceMissing(URL)
        case tarFailed(exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .sourceMissing(let url):
                return "source directory does not exist: \(url.path)"
            case .tarFailed(let code, let stderr):
                return "tar exited with code \(code): \(stderr)"
            }
        }
    }

    /// Tars `sourceDir` (typically `~/.shotfuse/`) to `outputTarball` with
    /// gzip compression. `telemetry.jsonl` files are excluded at every
    /// nesting level.
    ///
    /// - Parameters:
    ///   - sourceDir: Directory to archive. Must exist.
    ///   - outputTarball: Destination `.tar.gz` path. Overwritten if present.
    public static func export(sourceDir: URL, outputTarball: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDir.path) else {
            throw ExportError.sourceMissing(sourceDir)
        }

        // Ensure the output's parent directory exists; tar will create the
        // archive itself.
        let parent = outputTarball.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // We invoke tar as:
        //   tar --exclude='telemetry.jsonl' -czf <out> -C <source-parent> <source-basename>
        // The `-C` + basename form keeps the archive's top-level entry as
        // the source directory's name (e.g. `.shotfuse/...`) rather than
        // an absolute path; this makes the tarball portable.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--exclude=telemetry.jsonl",
            "-czf",
            outputTarball.path,
            "-C",
            sourceDir.deletingLastPathComponent().path,
            sourceDir.lastPathComponent
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Discard stdout — tar with `-c` is silent on success unless `-v`.
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "<non-utf8 stderr>"
            throw ExportError.tarFailed(exitCode: process.terminationStatus, stderr: msg)
        }
    }
}
