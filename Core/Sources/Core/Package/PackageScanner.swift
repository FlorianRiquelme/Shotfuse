import Foundation

/// Enumerates `.shot/` packages in a directory, skipping in-flight `.shot.tmp/` staging dirs.
///
/// Paired with `ShotPackageWriter`: the writer creates `<name>.shot.tmp/`,
/// populates + fsyncs it, then renames to `<name>.shot/`. The scanner must
/// never return a staging directory — that would expose a partially-written
/// package to readers and violate SPEC §5 I12 (atomic writes).
public struct PackageScanner {

    public init() {}

    /// Returns URLs of direct-child `.shot/` packages inside `dir`, ignoring
    /// `.shot.tmp/` staging directories.
    ///
    /// - Parameter dir: Directory to scan (non-recursive).
    /// - Returns: URLs of every direct child whose path extension is exactly `shot`.
    ///   The order matches the filesystem enumeration order and is not sorted.
    public func scan(_ dir: URL) throws -> [URL] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return children.filter { url in
            // `pathExtension` strips the final dot-suffix, so:
            //   foo.shot       -> "shot"     ✓ keep
            //   bar.shot.tmp   -> "tmp"      ✗ drop
            //   baz.png        -> "png"      ✗ drop
            url.pathExtension == "shot" && !ShotPackageWriter.isTemporaryPackage(url)
        }
    }
}
