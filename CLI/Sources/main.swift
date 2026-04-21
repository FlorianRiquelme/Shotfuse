import Core
import Foundation

/// Top-level dispatcher for the `shot` binary.
///
/// SPEC §16 pins the v0.1 command set exactly:
/// ```
/// shot last [--ocr] [--path] [--copy]
/// shot list [--limit N] [--pinned] [--since ISO8601]
/// shot show <id>
/// shot system status
/// shot system fuse-gc [--dry-run]
/// shot system export <out.tar.gz>
/// shot system uninstall
/// ```
///
/// Exit-code contract:
/// - `0` — success.
/// - `1` — recoverable error (missing id, unreadable file, etc.).
/// - `64` (EX_USAGE) — unknown command / malformed arguments.
/// - `74` (EX_IOERR) — I/O enumeration failure in fuse-gc.

let usage = """
shot \(Core.version) — usage:
  shot last [--ocr] [--path] [--copy]
  shot list [--limit N] [--pinned] [--since ISO8601]
  shot show <id>
  shot system status
  shot system fuse-gc [--dry-run]
  shot system export <out.tar.gz>
  shot system uninstall

"""

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64) // EX_USAGE
}

let command = argv[1]
let rest = Array(argv.dropFirst(2))

switch command {
case "last":
    exit(LastCommand.run(args: rest))

case "list":
    exit(ListCommand.run(args: rest))

case "show":
    exit(ShowCommand.run(args: rest))

case "system":
    guard let sub = rest.first else {
        FileHandle.standardError.write(Data("shot: system requires a subcommand\n".utf8))
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    let subArgs = Array(rest.dropFirst())
    switch sub {
    case "status":    exit(SystemStatus.run(args: subArgs))
    case "fuse-gc":   exit(SystemFuseGC.run(args: subArgs))
    case "export":    exit(SystemExport.run(args: subArgs))
    case "uninstall": exit(SystemUninstall.run(args: subArgs))
    default:
        FileHandle.standardError.write(Data("shot: unknown subcommand 'system \(sub)'\n".utf8))
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }

case "-h", "--help", "help":
    FileHandle.standardOutput.write(Data(usage.utf8))
    exit(0)

default:
    FileHandle.standardError.write(Data("shot: unknown command '\(command)'\n".utf8))
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}
