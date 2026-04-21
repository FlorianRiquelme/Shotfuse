import Core
import Foundation

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data("shot \(Core.version) — usage: shot <last|list|show|system ...>\n".utf8))
    exit(64) // EX_USAGE
}

// Command surface is wired in P6.1 (see session-plan.md §P6.1 / beads hq-c0l).
// P0.1 ships only the binary scaffolding; dispatch is intentionally a stub.
let command = argv[1]
FileHandle.standardError.write(Data("shot: command '\(command)' not implemented yet (P0.1 scaffolding)\n".utf8))
exit(69) // EX_UNAVAILABLE
