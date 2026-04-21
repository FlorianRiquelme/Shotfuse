import Foundation

/// A minimal read-only projection of a `.shot/` package for CLI use.
///
/// Produced by scanning the on-disk library: we do NOT depend on
/// `LibraryIndex` here because (a) the library directory is the source of
/// truth per SPEC §5 I4 and (b) the FTS index is query-oriented, not
/// chronology-oriented.
public struct CaptureSummary: Sendable, Equatable {
    public let id: String
    public let packageURL: URL
    public let createdAt: String        // ISO-8601 string from manifest.json
    public let createdAtEpoch: TimeInterval
    public let pinned: Bool
    public let bundleID: String?
    public let windowTitle: String?

    public init(
        id: String,
        packageURL: URL,
        createdAt: String,
        createdAtEpoch: TimeInterval,
        pinned: Bool,
        bundleID: String?,
        windowTitle: String?
    ) {
        self.id = id
        self.packageURL = packageURL
        self.createdAt = createdAt
        self.createdAtEpoch = createdAtEpoch
        self.pinned = pinned
        self.bundleID = bundleID
        self.windowTitle = windowTitle
    }

    /// The absolute path of `master.png` inside this package.
    public var masterPath: URL {
        packageURL.appendingPathComponent("master.png")
    }

    /// Path to `ocr.json`; may not exist if OCR is not yet complete.
    public var ocrPath: URL {
        packageURL.appendingPathComponent("ocr.json")
    }

    /// Path to `context.json` — read separately by `shot show`.
    public var contextPath: URL {
        packageURL.appendingPathComponent("context.json")
    }

    /// Path to `manifest.json`.
    public var manifestPath: URL {
        packageURL.appendingPathComponent("manifest.json")
    }
}

/// Reads `.shot/` packages directly from disk.
///
/// Implemented on top of `PackageScanner` (`.shot.tmp/` is already filtered)
/// plus a schema-tolerant JSON peek — we need `id`, `created_at`, `pinned`
/// and (optionally) the frontmost bundle + title from `context.json`.
public struct CaptureLibraryReader: Sendable {

    public init() {}

    /// Scans `libraryRoot` and returns all readable package summaries,
    /// newest-first by `created_at`.
    ///
    /// Unreadable or malformed packages are silently skipped — the CLI
    /// would rather show the user the valid rows than abort on one
    /// corrupt manifest.
    public func listAll(libraryRoot: URL) throws -> [CaptureSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryRoot.path) else {
            return []
        }
        let packages = try PackageScanner().scan(libraryRoot)
        var summaries: [CaptureSummary] = []
        summaries.reserveCapacity(packages.count)
        for pkg in packages {
            if let summary = try? readSummary(at: pkg) {
                summaries.append(summary)
            }
        }
        summaries.sort { $0.createdAtEpoch > $1.createdAtEpoch }
        return summaries
    }

    /// Returns the newest summary, or `nil` if the library is empty.
    public func latest(libraryRoot: URL) throws -> CaptureSummary? {
        try listAll(libraryRoot: libraryRoot).first
    }

    /// Fetches a single summary by id. Linear scan — the library is small
    /// for interactive `shot show <id>` use; switch to the FTS index if
    /// this ever appears on a hot path.
    public func findByID(_ id: String, libraryRoot: URL) throws -> CaptureSummary? {
        let all = try listAll(libraryRoot: libraryRoot)
        return all.first { $0.id == id }
    }

    // MARK: - Private

    /// Parses the minimum required fields from a package's `manifest.json`
    /// and optionally enriches with `frontmost` from `context.json`.
    private func readSummary(at packageURL: URL) throws -> CaptureSummary {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureLibraryReaderError.malformedManifest(packageURL)
        }
        guard let id = obj["id"] as? String,
              let createdAtString = obj["created_at"] as? String else {
            throw CaptureLibraryReaderError.malformedManifest(packageURL)
        }
        let pinned = (obj["pinned"] as? Bool) ?? false
        let epoch = Self.parseISO8601(createdAtString)?.timeIntervalSince1970
            ?? 0

        var bundleID: String?
        var windowTitle: String?
        let ctxURL = packageURL.appendingPathComponent("context.json")
        if FileManager.default.fileExists(atPath: ctxURL.path),
           let ctxData = try? Data(contentsOf: ctxURL),
           let ctxObj = try? JSONSerialization.jsonObject(with: ctxData) as? [String: Any],
           let front = ctxObj["frontmost"] as? [String: Any] {
            bundleID = front["bundle_id"] as? String
            windowTitle = front["window_title"] as? String
        }

        return CaptureSummary(
            id: id,
            packageURL: packageURL,
            createdAt: createdAtString,
            createdAtEpoch: epoch,
            pinned: pinned,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    /// ISO8601 parser matching the production writer's output (see
    /// `FusePolicy.parseISO8601`).
    private static func parseISO8601(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFractional.parse(s) { return d }
        return nil
    }
}

public enum CaptureLibraryReaderError: Error, Sendable, CustomStringConvertible {
    case malformedManifest(URL)

    public var description: String {
        switch self {
        case .malformedManifest(let url):
            return "malformed manifest at \(url.path)"
        }
    }
}
