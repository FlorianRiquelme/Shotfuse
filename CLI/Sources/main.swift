import Core
import Foundation

/// Usage line kept compatible with the P0.1 stub — `shot system ...` is
/// dispatched below without altering the user-visible help text.
let usage = "shot \(Core.version) — usage: shot <last|list|show|system ...>\n"

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64) // EX_USAGE
}

// Dispatch subcommands. Everything not explicitly handled falls through
// to the P0.1 stub (EX_UNAVAILABLE). Real wiring lands in P6.1 / hq-c0l.
let command = argv[1]

switch command {
case "system":
    // `shot system <sub>` handling.
    guard argv.count >= 3 else {
        FileHandle.standardError.write(Data("shot: system requires a subcommand\n".utf8))
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    let sub = argv[2]
    switch sub {
    case "fuse-gc":
        exit(runFuseGC(extraArgs: Array(argv.dropFirst(3))))
    case "status":
        // TODO(hq-lq3, hq-c0l): surface real launch-agent install state
        // and last-run timestamp once the agent plist + state file exist.
        print("fuse-gc: last-run unknown; launch agent: unknown")
        exit(0)
    default:
        FileHandle.standardError.write(Data("shot: command 'system \(sub)' not implemented yet (P0.1 scaffolding)\n".utf8))
        exit(69) // EX_UNAVAILABLE
    }

default:
    FileHandle.standardError.write(Data("shot: command '\(command)' not implemented yet (P0.1 scaffolding)\n".utf8))
    exit(69) // EX_UNAVAILABLE
}

// MARK: - fuse-gc

/// Resolves the library root the fuse sweep should operate on.
///
/// Precedence:
/// 1. `$SHOTFUSE_LIBRARY_ROOT` — test/CI override, documented in the
///    issue brief (hq-jlu).
/// 2. `~/.shotfuse/library/` — the SPEC §6 default for production.
private func resolveLibraryRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["SHOTFUSE_LIBRARY_ROOT"],
       !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".shotfuse/library", isDirectory: true)
}

/// Runs `shot system fuse-gc [--dry-run]`. Returns an exit code.
///
/// Behavior:
/// - `--dry-run`: prints the `.shot/` packages that would be deleted (one
///   path per line), plus a summary; nothing is removed.
/// - Default: invokes `FusePolicy.collect`, prints a one-line summary
///   `N deleted, K pinned, M tmp, E errors`, and returns 0 even when
///   `errors > 0` (the launch agent re-runs hourly; a single malformed
///   package must not wedge the sweep). Individual error lines are
///   written to stderr so operators can see them.
private func runFuseGC(extraArgs: [String]) -> Int32 {
    var dryRun = false
    for arg in extraArgs {
        switch arg {
        case "--dry-run":
            dryRun = true
        default:
            FileHandle.standardError.write(Data("shot system fuse-gc: unknown argument '\(arg)'\n".utf8))
            return 64 // EX_USAGE
        }
    }

    let libraryRoot = resolveLibraryRoot()
    let fm = FileManager.default
    if !fm.fileExists(atPath: libraryRoot.path) {
        // Nothing to sweep — library hasn't been created yet. Exit cleanly
        // so the launch agent doesn't keep firing errors.
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

/// `--dry-run` path: enumerates candidates using the same classification
/// logic as `collect`, but never calls `removeItem`. Implemented by
/// invoking `FusePolicy.collect` against a shadow copy is overkill for
/// v0.1; instead we replicate the minimal enumeration here so the real
/// filesystem is never mutated.
private func runDryRun(libraryRoot: URL) -> Int32 {
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
