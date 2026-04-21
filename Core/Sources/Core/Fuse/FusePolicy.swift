import Foundation

/// Aggregate result of a single `FusePolicy.collect` run.
///
/// - `deleted`: URLs of `.shot/` packages that were unpinned, past their
///   `expires_at`, and successfully removed from disk.
/// - `skippedPinned`: URLs of `.shot/` packages whose manifest reported
///   `pinned == true`. Pinned packages are never deleted, even if expired.
/// - `skippedTmp`: URLs of `.shot.tmp/` staging directories encountered
///   during enumeration. They are always skipped — touching them would
///   violate SPEC §5 I12 (atomic package writes).
/// - `errors`: URLs paired with the error that prevented classification
///   or deletion (e.g. malformed manifest, missing manifest, I/O error).
///   An erroring package is NEVER deleted.
public struct FuseGCResult: Sendable {
    public var deleted: [URL]
    public var skippedPinned: [URL]
    public var skippedTmp: [URL]
    public var errors: [(URL, Error)]

    public init(
        deleted: [URL] = [],
        skippedPinned: [URL] = [],
        skippedTmp: [URL] = [],
        errors: [(URL, Error)] = []
    ) {
        self.deleted = deleted
        self.skippedPinned = skippedPinned
        self.skippedTmp = skippedTmp
        self.errors = errors
    }
}

/// Errors surfaced by `FusePolicy` through `FuseGCResult.errors`.
public enum FusePolicyError: Error, Sendable {
    /// The package's `manifest.json` was missing.
    case manifestMissing
    /// The package's `manifest.json` could not be decoded as JSON, or lacked
    /// required fields (`expires_at`, `pinned`).
    case manifestMalformed(String)
    /// An underlying I/O error occurred while reading the manifest or
    /// removing the package directory.
    case io(String)
}

/// Sweeps a library root, deleting unpinned `.shot/` packages whose fuse
/// has burned out (`manifest.expires_at` ≤ `now`).
///
/// Contract (SPEC §4 Fuse vocabulary, §15.1 fuse cleanup launch agent,
/// §5 I12 atomic writes):
/// - NEVER deletes pinned packages (`manifest.pinned == true`), regardless
///   of `expires_at`.
/// - NEVER touches `.shot.tmp/` staging directories — they are tracked in
///   `skippedTmp` so the caller can surface them if desired.
/// - Malformed or unreadable manifests are recorded in `errors` and the
///   package is left on disk (fail-safe: we would rather leak a bad
///   package than delete one we cannot verify).
/// - Schema-tolerant: unknown manifest fields (e.g. `sensitivity`,
///   `context`, `display`) are ignored; only `expires_at` and `pinned`
///   are consulted.
public struct FusePolicy: Sendable {

    public init() {}

    /// Enumerates `libraryRoot`, classifies each child, and deletes
    /// expired, unpinned packages.
    ///
    /// - Parameters:
    ///   - libraryRoot: Directory to sweep. Typically `~/.shotfuse/library/`,
    ///     but callers (tests, CLI with `$SHOTFUSE_LIBRARY_ROOT`) may pass
    ///     any directory.
    ///   - now: Reference instant for comparing against `expires_at`.
    ///     Defaults to `Date.now`. Injected for deterministic tests.
    /// - Returns: A `FuseGCResult` summarizing the sweep.
    /// - Throws: Only if `libraryRoot` itself cannot be enumerated. Errors
    ///   on individual packages are captured in the result, not thrown.
    public func collect(libraryRoot: URL, now: Date = .now) throws -> FuseGCResult {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var result = FuseGCResult()

        for url in children {
            // `.shot.tmp/` staging dirs: never touch (SPEC §5 I12).
            if ShotPackageWriter.isTemporaryPackage(url) {
                result.skippedTmp.append(url)
                continue
            }

            // Only `.shot/` packages are managed by the fuse; ignore
            // everything else (stray files, unrelated subdirs).
            guard url.pathExtension == "shot" else {
                continue
            }

            switch classify(packageURL: url, now: now) {
            case .expiredUnpinned:
                do {
                    try fm.removeItem(at: url)
                    result.deleted.append(url)
                } catch {
                    result.errors.append((url, FusePolicyError.io(error.localizedDescription)))
                }
            case .pinned:
                result.skippedPinned.append(url)
            case .notYetExpired:
                // Unpinned but still within fuse window: leave it alone.
                // We do not need a separate bucket for this in v0.1.
                continue
            case .error(let err):
                result.errors.append((url, err))
            }
        }

        return result
    }

    // MARK: - Classification

    private enum Classification {
        case expiredUnpinned
        case pinned
        case notYetExpired
        case error(FusePolicyError)
    }

    private func classify(packageURL: URL, now: Date) -> Classification {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            return .error(.manifestMissing)
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            return .error(.io(error.localizedDescription))
        }

        let parsed: ManifestFields
        do {
            parsed = try Self.parseManifest(data)
        } catch let err as FusePolicyError {
            return .error(err)
        } catch {
            return .error(.manifestMalformed(error.localizedDescription))
        }

        if parsed.pinned {
            return .pinned
        }

        if parsed.expiresAt <= now {
            return .expiredUnpinned
        }

        return .notYetExpired
    }

    // MARK: - Manifest parsing

    /// Fields extracted from `manifest.json`. Schema-tolerant: we only
    /// look at `expires_at` and `pinned`; all other fields (including
    /// `sensitivity`, `context`, `display`, ...) are intentionally ignored.
    private struct ManifestFields {
        let expiresAt: Date
        let pinned: Bool
    }

    /// Parses only the two fields the fuse policy depends on. Uses
    /// untyped `JSONSerialization` (rather than a `Decodable` wrapper)
    /// specifically so that adding new manifest fields in future spec
    /// versions does not require edits here.
    private static func parseManifest(_ data: Data) throws -> ManifestFields {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FusePolicyError.manifestMalformed("not valid JSON: \(error.localizedDescription)")
        }
        guard let dict = any as? [String: Any] else {
            throw FusePolicyError.manifestMalformed("top-level must be an object")
        }

        guard let expiresRaw = dict["expires_at"] else {
            throw FusePolicyError.manifestMalformed("missing expires_at")
        }
        // The spec allows `expires_at` to be null for pinned packages
        // (§6.1: "null ⇔ pinned"). In that case a non-null `pinned: true`
        // is mandatory; treat the null case as "far future" so the `pinned`
        // check wins regardless of order.
        let expiresAt: Date
        if expiresRaw is NSNull {
            expiresAt = .distantFuture
        } else if let expiresString = expiresRaw as? String {
            guard let parsed = parseISO8601(expiresString) else {
                throw FusePolicyError.manifestMalformed("expires_at not ISO8601: \(expiresString)")
            }
            expiresAt = parsed
        } else {
            throw FusePolicyError.manifestMalformed("expires_at must be string or null")
        }

        guard let pinned = dict["pinned"] as? Bool else {
            throw FusePolicyError.manifestMalformed("missing or non-bool pinned")
        }

        return ManifestFields(expiresAt: expiresAt, pinned: pinned)
    }

    /// ISO8601 parser tolerant to both the fractional-seconds form
    /// (e.g. `2026-04-21T10:43:12.123Z`) and the base form
    /// (e.g. `2026-04-21T10:43:12Z`). Sendable-safe via the modern
    /// `Date.ISO8601FormatStyle` API.
    private static func parseISO8601(_ s: String) -> Date? {
        // Try the default (RFC3339-ish, Z-terminated, seconds precision).
        if let d = try? Date(s, strategy: .iso8601) {
            return d
        }
        // Try with fractional seconds.
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFractional.parse(s) {
            return d
        }
        return nil
    }
}
