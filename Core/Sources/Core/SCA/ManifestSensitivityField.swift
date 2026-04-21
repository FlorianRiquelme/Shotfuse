import Darwin
import Foundation

// MARK: - Codable helper for the `sensitivity` field

/// Codable projection of the `sensitivity` field added to `manifest.json`
/// post-capture. Serialized as a bare JSON array of strings under the
/// `sensitivity` key — e.g. `{"sensitivity": ["password_field"]}`.
///
/// SPEC §6.1 lists `sensitivity` as optional; present iff analysis ran. This
/// type is only the projection the analyzer produces; merging into the live
/// manifest happens via `patchManifest(url:with:)` below.
public struct ManifestSensitivityField: Codable, Equatable, Sendable {
    public let sensitivity: [SensitivityTag]

    public init(_ tags: [SensitivityTag]) {
        self.sensitivity = tags
    }
}

// MARK: - patchManifest

/// Errors thrown by `patchManifest(url:with:)`.
public enum ManifestPatchError: Error, Sendable, Equatable {
    case manifestMissing
    case invalidJSON(String)
    case ioFailure(String)
    case encodingFailed(String)
}

/// Merges a `sensitivity` field into an existing `.shot/manifest.json`.
///
/// This is the ONLY place in the codebase that mutates an existing `.shot/`
/// package in-place. SPEC §5 Invariant 3 constrains `master.*`, not
/// `manifest.json` — §13.4 explicitly allows writing the sensitivity result
/// back to the manifest after capture.
///
/// Durability: writes the updated JSON to a sibling `.shot/manifest.json.tmp`,
/// fsyncs the new file, then `rename(2)`s it over the live manifest. The
/// rename is atomic on APFS; the fsync guarantees the new bytes are on stable
/// storage before the rename point-of-no-return.
///
/// - Parameters:
///   - url: Either the `.shot/` package URL or the `manifest.json` file URL.
///   - field: The sensitivity projection to merge (replaces any existing
///     `sensitivity` key).
public func patchManifest(
    url: URL,
    with field: ManifestSensitivityField
) throws {
    let manifestURL = resolveManifestURL(url)
    let fm = FileManager.default
    guard fm.fileExists(atPath: manifestURL.path) else {
        throw ManifestPatchError.manifestMissing
    }

    // 1. Read + parse existing manifest as a generic JSON dictionary so we
    //    preserve fields we don't model (forward-compat with spec deltas).
    let existingData: Data
    do {
        existingData = try Data(contentsOf: manifestURL)
    } catch {
        throw ManifestPatchError.ioFailure("read manifest: \(error.localizedDescription)")
    }

    var jsonObject: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: existingData)
                as? [String: Any] else {
            throw ManifestPatchError.invalidJSON("manifest root is not a JSON object")
        }
        jsonObject = parsed
    } catch let err as ManifestPatchError {
        throw err
    } catch {
        throw ManifestPatchError.invalidJSON(error.localizedDescription)
    }

    // 2. Overwrite the `sensitivity` key with the incoming tag list. We
    //    serialize the rawValues ourselves so the JSON shape stays
    //    `["password_field", ...]` regardless of `JSONEncoder` quirks.
    jsonObject["sensitivity"] = field.sensitivity.map { $0.rawValue }

    // 3. Re-serialize. Keep sorted keys + pretty-printing so the file format
    //    matches what `CaptureFinalization` writes initially.
    let patched: Data
    do {
        patched = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
    } catch {
        throw ManifestPatchError.encodingFailed(error.localizedDescription)
    }

    // 4. Write to sibling `.tmp`, fsync, rename atomically.
    let tmpURL = manifestURL.deletingLastPathComponent()
        .appendingPathComponent(manifestURL.lastPathComponent + ".tmp")

    // If a stale tmp exists (e.g. from a crashed previous patch), remove it
    // first so the atomic write below doesn't collide.
    if fm.fileExists(atPath: tmpURL.path) {
        try? fm.removeItem(at: tmpURL)
    }

    do {
        try patched.write(to: tmpURL, options: [.atomic])
    } catch {
        throw ManifestPatchError.ioFailure("write tmp: \(error.localizedDescription)")
    }

    try fsyncFile(atPath: tmpURL.path)

    do {
        // `replaceItemAt` uses `renamex_np` under the hood for atomic replace.
        // On APFS this is a single atomic operation — the live manifest is
        // either the old bytes or the new bytes, never truncated/partial.
        _ = try fm.replaceItemAt(manifestURL, withItemAt: tmpURL)
    } catch {
        throw ManifestPatchError.ioFailure("rename: \(error.localizedDescription)")
    }
}

/// Resolves a user-supplied `url` (either a `.shot/` package or a direct
/// `manifest.json`) to the manifest file path.
private func resolveManifestURL(_ url: URL) -> URL {
    // If `url` already points at a file named `manifest.json` — use it.
    if url.lastPathComponent == "manifest.json" {
        return url
    }
    // Otherwise treat as a package URL.
    return url.appendingPathComponent("manifest.json")
}

/// Opens `path` read-only, fsyncs, closes. Raises on open/fsync failure.
/// Mirrors `ShotPackageWriter.fsync` but kept local so the SCA module has
/// no source dependency on the Package module's internals.
private func fsyncFile(atPath path: String) throws {
    let fd = Darwin.open(path, O_RDONLY)
    guard fd >= 0 else {
        throw ManifestPatchError.ioFailure("open for fsync: errno=\(errno)")
    }
    defer { _ = Darwin.close(fd) }
    if Darwin.fsync(fd) != 0 {
        throw ManifestPatchError.ioFailure("fsync: errno=\(errno)")
    }
}
