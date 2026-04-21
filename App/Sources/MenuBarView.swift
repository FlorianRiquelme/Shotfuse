import AppKit
import Core
import SwiftUI

/// SwiftUI body for the `MenuBarExtra` scene. Only the menubar content
/// is SwiftUI — per SPEC §5 I2, overlays and capture surfaces stay in
/// AppKit (RegionSelectionOverlay, LimboHUDController, SearchOverlayController).
struct MenuBarView: View {
    let appDelegate: AppDelegate

    var body: some View {
        Button("Capture region  ⇧⌘4") {
            Task { [appDelegate] in
                guard let coordinator = appDelegate.coordinator else { return }
                _ = try? await coordinator.captureRegion()
            }
        }
        Button("Capture fullscreen  ⇧⌘3") {
            Task { [appDelegate] in
                guard let coordinator = appDelegate.coordinator else { return }
                _ = try? await coordinator.captureFullscreen(display: CGMainDisplayID())
            }
        }
        Button("Capture witness  ⇧⌘W") {
            Task { [appDelegate] in
                guard let coordinator = appDelegate.coordinator else { return }
                _ = try? await coordinator.captureWitness()
            }
        }
        Divider()
        Button("Search…  ⇧⌘G") {
            appDelegate.searchController?.activate()
        }
        Divider()
        Text("Shotfuse \(Core.version)")
            .font(.caption)
        if !appDelegate.failedHotkeyIDs.isEmpty {
            Text("⚠︎ Some hotkeys failed to register")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Divider()
        Button("Quit Shotfuse") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
