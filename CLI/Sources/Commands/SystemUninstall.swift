import Core
import Foundation

/// `shot system uninstall` — SPEC §16 / §15.1.
///
/// Removes `~/Library/LaunchAgents/dev.friquelme.shotfuse.fuse.plist`
/// after invoking `launchctl unload`. The library at `~/.shotfuse/` is
/// preserved; users who want to wipe the library should `rm -rf` it
/// themselves (no CLI command ever destroys capture data).
enum SystemUninstall {

    /// `$SHOTFUSE_UNINSTALL_SKIP_LAUNCHCTL=1` disables the `launchctl
    /// unload` invocation. Tests set this to avoid mutating launchd state.
    private static let skipLaunchctlEnv = "SHOTFUSE_UNINSTALL_SKIP_LAUNCHCTL"

    static func run(args: [String]) -> Int32 {
        if !args.isEmpty {
            FileHandle.standardError.write(Data("shot system uninstall: takes no arguments\n".utf8))
            return 64
        }

        let plistURL = CLIPaths.launchAgentPlistURL()
        let skipLaunchctl = (ProcessInfo.processInfo.environment[skipLaunchctlEnv] ?? "") == "1"

        do {
            let result = try LaunchAgentUninstaller.uninstall(
                plistURL: plistURL,
                runLaunchctl: !skipLaunchctl
            )
            if !result.plistExistedBefore {
                print("launch agent not installed (nothing to remove) at \(plistURL.path)")
            } else {
                print("launch agent removed: \(plistURL.path)")
                if let code = result.unloadExitCode {
                    print("launchctl unload exit: \(code)")
                }
            }
            print("library preserved at: \(CLIPaths.rootDirectory().path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("shot system uninstall: \(error)\n".utf8))
            return 1
        }
    }
}
