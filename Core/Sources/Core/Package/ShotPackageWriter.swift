import Foundation
import Darwin

/// Errors thrown by `ShotPackageWriter`.
public enum ShotPackageWriterError: Error {
    /// The supplied `finalURL` did not end in the `.shot` extension.
    case invalidFinalURL
    /// Either the final `.shot/` package or the staging `.shot.tmp/` directory already exists.
    case destinationExists
    /// Low-level I/O failure bubbled up from the filesystem layer.
    case ioFailure(String)
}

/// Atomically writes a `.shot` package directory.
///
/// Contract (SPEC §5):
/// - I3: `master.*` is written exactly once; callers must not mutate an existing package.
/// - I4: Packages are directories ending in `.shot/`, never flat archives.
/// - I12: Writes are atomic — consumers only ever observe a fully-populated `.shot/`
///        directory, never a half-written one. We stage into `.shot.tmp/`, fsync the
///        manifest and the staging directory, then `rename(2)` into place.
public struct ShotPackageWriter {

    /// Extension used for the staging directory that holds an in-flight package write.
    /// Scanners and readers MUST ignore any directory with this extension.
    public static let temporaryExtension = "shot.tmp"

    /// Returns `true` iff `url` looks like an in-flight package staging directory
    /// (i.e. its path ends in `.shot.tmp`). Used by `PackageScanner` to filter.
    public static func isTemporaryPackage(_ url: URL) -> Bool {
        // `pathExtension` on URL returns the substring after the final '.', so
        // for `foo.shot.tmp` it returns `tmp`. We compare against the full suffix
        // via the trailing path component to catch the whole `shot.tmp` token.
        let name = url.lastPathComponent
        return name.hasSuffix(".\(Self.temporaryExtension)")
    }

    /// Test hook: flipped to `true` immediately after the manifest has been
    /// fsync'd to disk and before `rename(2)` is issued. Used by tests to pin
    /// the fsync-before-rename ordering; never read in production.
    internal var didFsyncManifest: Bool = false

    public init() {}

    /// Writes a `.shot` package atomically.
    ///
    /// - Parameters:
    ///   - finalURL: Destination URL. MUST have `.shot` path extension
    ///     (e.g. `.../2026-04-21T12-34-56.shot`).
    ///   - manifest: Serialized `manifest.json` bytes. Written last inside the
    ///     staging dir and fsync'd before rename to guarantee durability of the
    ///     canonical file.
    ///   - files: Map of relative filename → bytes. Typical keys:
    ///     `master.png`, `thumb.jpg`, `ocr.json`, `context.json`.
    ///
    /// - Throws: `ShotPackageWriterError.invalidFinalURL` if `finalURL` lacks
    ///   the `.shot` extension, `.destinationExists` if either the final or
    ///   staging path already exists, or `.ioFailure` for lower-level errors.
    public mutating func write(
        to finalURL: URL,
        manifest: Data,
        files: [String: Data]
    ) throws {
        guard finalURL.pathExtension == "shot" else {
            throw ShotPackageWriterError.invalidFinalURL
        }

        // Derive `<name>.shot.tmp` from `<name>.shot`.
        let tempURL = finalURL.deletingPathExtension()
            .appendingPathExtension(Self.temporaryExtension)

        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) || fm.fileExists(atPath: tempURL.path) {
            throw ShotPackageWriterError.destinationExists
        }

        // 1. Create the staging directory.
        do {
            try fm.createDirectory(at: tempURL, withIntermediateDirectories: false)
        } catch {
            throw ShotPackageWriterError.ioFailure("create staging dir: \(error.localizedDescription)")
        }

        // 2. Write payload files first — manifest goes last so that its
        //    presence signals a complete package to readers that might peek
        //    into a (not-yet-renamed) staging directory.
        for (name, data) in files {
            let fileURL = tempURL.appendingPathComponent(name)
            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                throw ShotPackageWriterError.ioFailure("write \(name): \(error.localizedDescription)")
            }
        }

        // 3. Write manifest.json.
        let manifestURL = tempURL.appendingPathComponent("manifest.json")
        do {
            try manifest.write(to: manifestURL, options: [.atomic])
        } catch {
            throw ShotPackageWriterError.ioFailure("write manifest: \(error.localizedDescription)")
        }

        // 4. fsync the manifest file — this is the durability point for the
        //    canonical metadata file. Readers that only see `<name>.shot/`
        //    post-rename are guaranteed the manifest bytes are on stable storage.
        try Self.fsync(path: manifestURL.path)
        didFsyncManifest = true

        // 5. fsync the staging directory's own inode so directory-level
        //    metadata (the entries we just wrote) is durable before we rename.
        try Self.fsync(path: tempURL.path)

        // 6. Rename staging → final. `FileManager.moveItem` maps to rename(2)
        //    on APFS/HFS+, which is atomic for directory-to-directory renames
        //    on the same volume (the only case we support here).
        do {
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            throw ShotPackageWriterError.ioFailure("rename: \(error.localizedDescription)")
        }
    }

    /// Opens `path`, fsyncs, closes. Works for both regular files and
    /// directories (fsync on a directory fd flushes the directory's metadata).
    private static func fsync(path: String) throws {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else {
            throw ShotPackageWriterError.ioFailure("open for fsync failed: \(path) errno=\(errno)")
        }
        defer { _ = Darwin.close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw ShotPackageWriterError.ioFailure("fsync failed: \(path) errno=\(errno)")
        }
    }
}
