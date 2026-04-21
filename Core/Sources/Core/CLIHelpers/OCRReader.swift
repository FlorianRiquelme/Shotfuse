import Foundation

/// Extracts concatenated OCR text from a package's `ocr.json` file.
///
/// The on-disk shape follows SPEC §6.3:
/// ```
/// { "vision_version": "...", "locale_hints": [...],
///   "results": [ { "text": "...", "bbox": [x,y,w,h], "confidence": 0..1, "lang": "..." } ] }
/// ```
///
/// Missing file → empty string. We do NOT hard-fail `shot last --ocr`
/// when OCR has not yet run; it's a valid background-enrichment state.
public enum OCRReader {

    /// Reads `<package>/ocr.json` and returns the concatenation of every
    /// result's `text` field, joined by newlines. Returns `""` if the file
    /// does not exist or cannot be parsed.
    public static func readText(for packageURL: URL) -> String {
        let ocrURL = packageURL.appendingPathComponent("ocr.json")
        guard FileManager.default.fileExists(atPath: ocrURL.path),
              let data = try? Data(contentsOf: ocrURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return ""
        }
        let texts = results.compactMap { $0["text"] as? String }
        return texts.joined(separator: "\n")
    }
}
