import Core
import Foundation

/// `shot list [--limit N] [--pinned]` — SPEC §16.
///
/// The SPEC shows `[--since <ISO8601>]` too; the session-plan test contract
/// pins `--limit N` and `--pinned` for P6.1. We implement both the P6.1
/// flags and preserve ISO8601 `--since` as a no-op-friendly extension so a
/// future cleanup can remove it without breaking consumers.
enum ListCommand {

    static func run(args: [String]) -> Int32 {
        var limit: Int = 50
        var onlyPinned = false
        var since: Date?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else {
                    FileHandle.standardError.write(Data("shot list: --limit requires a positive integer\n".utf8))
                    return 64
                }
                limit = n
            case "--pinned":
                onlyPinned = true
            case "--since":
                i += 1
                guard i < args.count else {
                    FileHandle.standardError.write(Data("shot list: --since requires an ISO-8601 timestamp\n".utf8))
                    return 64
                }
                if let d = try? Date(args[i], strategy: .iso8601) {
                    since = d
                } else {
                    FileHandle.standardError.write(Data("shot list: could not parse --since '\(args[i])'\n".utf8))
                    return 64
                }
            default:
                FileHandle.standardError.write(Data("shot list: unknown argument '\(arg)'\n".utf8))
                return 64
            }
            i += 1
        }

        let libraryRoot = CLIPaths.libraryRoot()
        let reader = CaptureLibraryReader()
        let all: [CaptureSummary]
        do {
            all = try reader.listAll(libraryRoot: libraryRoot)
        } catch {
            FileHandle.standardError.write(Data("shot list: \(error)\n".utf8))
            return 1
        }

        var filtered = all
        if onlyPinned {
            filtered = filtered.filter { $0.pinned }
        }
        if let since {
            filtered = filtered.filter { $0.createdAtEpoch >= since.timeIntervalSince1970 }
        }
        if filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }

        for summary in filtered {
            print(formatRow(summary))
        }
        return 0
    }

    /// One-line row. Order is: `id  created_at  pinned  bundle  title`.
    /// Fields are tab-separated so `awk`/`cut` consumers have an easy time.
    static func formatRow(_ s: CaptureSummary) -> String {
        let pinned = s.pinned ? "pinned" : "-"
        let bundle = s.bundleID ?? "-"
        let title = s.windowTitle ?? "-"
        return "\(s.id)\t\(s.createdAt)\t\(pinned)\t\(bundle)\t\(title)"
    }
}
