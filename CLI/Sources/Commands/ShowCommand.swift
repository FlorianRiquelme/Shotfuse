import Core
import Foundation

/// `shot show <id>` — SPEC §16.
///
/// Prints the manifest as pretty-printed JSON, the absolute master path,
/// and the OCR text (if any). We deliberately do NOT re-serialize the
/// manifest via a `Codable` round-trip: that would drop fields we don't
/// know about and would silently diverge from what's on disk.
enum ShowCommand {

    static func run(args: [String]) -> Int32 {
        guard let id = args.first, !id.hasPrefix("--") else {
            FileHandle.standardError.write(Data("shot show: requires an <id> argument\n".utf8))
            return 64
        }
        if args.count > 1 {
            FileHandle.standardError.write(Data("shot show: unexpected extra arguments\n".utf8))
            return 64
        }

        let libraryRoot = CLIPaths.libraryRoot()
        let reader = CaptureLibraryReader()
        let match: CaptureSummary?
        do {
            match = try reader.findByID(id, libraryRoot: libraryRoot)
        } catch {
            FileHandle.standardError.write(Data("shot show: \(error)\n".utf8))
            return 1
        }
        guard let match else {
            FileHandle.standardError.write(Data("shot show: no capture with id '\(id)'\n".utf8))
            return 1
        }

        // 1. Manifest JSON, re-pretty-printed from on-disk bytes.
        do {
            let raw = try Data(contentsOf: match.manifestPath)
            let obj = try JSONSerialization.jsonObject(with: raw)
            let pretty = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            )
            if let s = String(data: pretty, encoding: .utf8) {
                print(s)
            }
        } catch {
            FileHandle.standardError.write(Data("shot show: manifest unreadable: \(error)\n".utf8))
            return 1
        }

        // 2. Master path on its own line — scripting-friendly.
        print("master: \(match.masterPath.path)")

        // 3. OCR text, if any. Prefixed so mixed-output parsers can split.
        let ocrText = OCRReader.readText(for: match.packageURL)
        if !ocrText.isEmpty {
            print("ocr_text:")
            print(ocrText)
        } else {
            print("ocr_text: <none>")
        }

        return 0
    }
}
