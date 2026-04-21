import Core
import Foundation

/// `shot system export <out.tar.gz>` — SPEC §16.
///
/// Archives the resolved Shotfuse root (typically `~/.shotfuse/`),
/// excluding `telemetry.jsonl` per SPEC §13.5 (telemetry is local-only
/// and must never leave the device).
enum SystemExport {

    static func run(args: [String]) -> Int32 {
        guard args.count == 1, !args[0].hasPrefix("--") else {
            FileHandle.standardError.write(Data("shot system export: requires a single <out.tar.gz> argument\n".utf8))
            return 64
        }
        let outputPath = args[0]
        let outputURL = URL(fileURLWithPath: outputPath)
        let rootURL = CLIPaths.rootDirectory()

        do {
            try LibraryExporter.export(sourceDir: rootURL, outputTarball: outputURL)
            print("exported \(rootURL.path) → \(outputURL.path) (telemetry.jsonl excluded)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("shot system export: \(error)\n".utf8))
            return 1
        }
    }
}
