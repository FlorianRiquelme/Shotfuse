import AppKit
import Core
import Foundation

/// `shot last [--ocr] [--path] [--copy]` — SPEC §16.
///
/// Flags are mutually cumulative (`--ocr` and `--path` can be combined),
/// but the first matching output wins the process's stdout so scripts can
/// depend on a single-line `--path`. When no flags are passed, we print a
/// short human-readable summary matching the `shot list` single-row shape.
enum LastCommand {

    static func run(args: [String]) -> Int32 {
        var wantOCR = false
        var wantPath = false
        var wantCopy = false

        for arg in args {
            switch arg {
            case "--ocr":  wantOCR = true
            case "--path": wantPath = true
            case "--copy": wantCopy = true
            default:
                FileHandle.standardError.write(Data("shot last: unknown argument '\(arg)'\n".utf8))
                return 64
            }
        }

        let libraryRoot = CLIPaths.libraryRoot()
        let reader = CaptureLibraryReader()
        let latest: CaptureSummary?
        do {
            latest = try reader.latest(libraryRoot: libraryRoot)
        } catch {
            FileHandle.standardError.write(Data("shot last: \(error)\n".utf8))
            return 1
        }
        guard let latest else {
            FileHandle.standardError.write(Data("shot last: library is empty\n".utf8))
            return 1
        }

        // Precedence: --path dominates (it's the scripting-friendly single
        // line). --ocr adds OCR text. --copy writes to the pasteboard.
        if wantPath {
            print(latest.masterPath.path)
        }
        if wantOCR {
            print(OCRReader.readText(for: latest.packageURL))
        }
        if wantCopy {
            if let copyError = copyMasterToPasteboard(latest.masterPath) {
                FileHandle.standardError.write(Data("shot last --copy: \(copyError)\n".utf8))
                return 1
            }
        }

        // No flags → print a compact summary. Matches one-row-shape of
        // `shot list`.
        if !wantPath && !wantOCR && !wantCopy {
            let line = ListCommand.formatRow(latest)
            print(line)
        }
        return 0
    }

    /// Writes the PNG bytes at `masterURL` to `NSPasteboard.general`.
    ///
    /// Returns an error string on failure. In headless CI this may silently
    /// fail because there is no pasteboard server; we tolerate that via the
    /// test's `#if !CI` skip, not here.
    private static func copyMasterToPasteboard(_ masterURL: URL) -> String? {
        guard let data = try? Data(contentsOf: masterURL) else {
            return "could not read \(masterURL.path)"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setData(data, forType: .png)
        return ok ? nil : "NSPasteboard.setData returned false"
    }
}
