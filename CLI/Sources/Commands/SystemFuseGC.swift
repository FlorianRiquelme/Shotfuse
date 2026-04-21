import Core
import Foundation

/// `shot system fuse-gc [--dry-run]` — SPEC §16 / §15.1.
///
/// This is the command the launch agent invokes hourly. Contract:
/// - Default: invoke `FusePolicy.collect`; print a single-line summary;
///   exit 0 even when `errors > 0` so the agent doesn't keep re-running
///   the same failure.
/// - `--dry-run`: enumerate without removing anything. Echoes each
///   candidate path on stdout, then a summary.
///
/// The `$SHOTFUSE_LIBRARY_ROOT` override routes both paths to a test
/// fixture without touching `~/.shotfuse/library`.
enum SystemFuseGC {

    static func run(args: [String]) -> Int32 {
        var dryRun = false
        for arg in args {
            switch arg {
            case "--dry-run": dryRun = true
            default:
                FileHandle.standardError.write(Data("shot system fuse-gc: unknown argument '\(arg)'\n".utf8))
                return 64
            }
        }

        let libraryRoot = CLIPaths.libraryRoot()
        let fm = FileManager.default
        if !fm.fileExists(atPath: libraryRoot.path) {
            // Parity with the pre-P6.1 wiring (hq-jlu): a missing library
            // is not an error — the launch agent fires before first capture.
            print("0 deleted, 0 pinned, 0 tmp, 0 errors (library not present)")
            return 0
        }

        if dryRun {
            return runDryRun(libraryRoot: libraryRoot)
        }

        let policy = FusePolicy()
        do {
            let result = try policy.collect(libraryRoot: libraryRoot)
            for (url, err) in result.errors {
                FileHandle.standardError.write(
                    Data("shot system fuse-gc: error on \(url.path): \(err)\n".utf8)
                )
            }
            print("\(result.deleted.count) deleted, \(result.skippedPinned.count) pinned, \(result.skippedTmp.count) tmp, \(result.errors.count) errors")
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("shot system fuse-gc: failed to enumerate \(libraryRoot.path): \(error)\n".utf8)
            )
            return 74 // EX_IOERR
        }
    }

    /// Replica of the non-destructive enumeration from the pre-P6.1
    /// wiring — preserved as a compat surface for operators who script
    /// against `--dry-run`. A future refactor can push this into
    /// `FusePolicy` once we're confident the shape is stable.
    private static func runDryRun(libraryRoot: URL) -> Int32 {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: libraryRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            FileHandle.standardError.write(
                Data("shot system fuse-gc: failed to enumerate \(libraryRoot.path): \(error)\n".utf8)
            )
            return 74
        }

        var wouldDelete: [URL] = []
        var pinned = 0
        var tmp = 0
        var errors = 0
        let now = Date()

        for url in children {
            if ShotPackageWriter.isTemporaryPackage(url) {
                tmp += 1
                continue
            }
            guard url.pathExtension == "shot" else { continue }

            let manifestURL = url.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                errors += 1
                continue
            }
            let isPinned = (obj["pinned"] as? Bool) ?? false
            if isPinned { pinned += 1; continue }

            guard let expiresString = obj["expires_at"] as? String,
                  let expiresAt = (try? Date(expiresString, strategy: .iso8601)) else {
                errors += 1
                continue
            }
            if expiresAt <= now {
                wouldDelete.append(url)
            }
        }

        for url in wouldDelete {
            print(url.path)
        }
        print("[dry-run] would delete \(wouldDelete.count); \(pinned) pinned, \(tmp) tmp, \(errors) errors")
        return 0
    }
}
