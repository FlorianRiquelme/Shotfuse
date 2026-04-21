import Core
import Foundation

/// `shot system status` — SPEC §16 / §17.3.
///
/// This command is intentionally side-effect free: it never prompts for
/// TCC, never mutates state. Real TCC queries are left as `"unknown"`
/// until the App target wires them in — the CLI can't open the AppKit
/// panels that would fire the prompts.
enum SystemStatus {

    static func run(args: [String]) -> Int32 {
        if !args.isEmpty {
            FileHandle.standardError.write(Data("shot system status: takes no arguments\n".utf8))
            return 64
        }

        let libraryRoot = CLIPaths.libraryRoot()
        let plistURL = CLIPaths.launchAgentPlistURL()

        let report = SystemStatusReporter.gather(
            libraryRoot: libraryRoot,
            launchAgentPlist: plistURL
        )
        print(report.render())
        return 0
    }
}
