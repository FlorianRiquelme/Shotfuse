import AppKit
import Core
import SwiftUI

// SPEC §5 I2: SwiftUI is confined to the MenuBarExtra scene. The
// `AppDelegate` owns everything else — CaptureCoordinator, hotkey
// registry, search overlay, Limbo HUD, launch-agent install.
//
// Prototype note: the `shot` CLI is not auto-bundled inside the App.
// To enable `shot list` / `shot system status` end-to-end, symlink the
// build output into PATH after `xcodebuild` resolves the CLI binary:
//
//   ln -s "$(xcodebuild -workspace Shotfuse.xcworkspace -scheme CLI \
//           -showBuildSettings | awk '/ TARGET_BUILD_DIR /{print $3}')/shot" \
//         /usr/local/bin/shot
//
// LaunchAgent install silently skips when the shot path can't be
// resolved; run `shot system uninstall` to clean up if needed.

@main
struct ShotfuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Shotfuse", systemImage: "scope") {
            MenuBarView(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)
    }
}
