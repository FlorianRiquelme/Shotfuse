import AppKit
import Core
import SwiftUI

@main
struct ShotfuseApp: App {
    var body: some Scene {
        MenuBarExtra("Shotfuse", systemImage: "scope") {
            Text("Shotfuse \(Core.version)")
                .font(.headline)
            Divider()
            Button("Quit Shotfuse") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
