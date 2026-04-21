import Foundation
import Testing

@Suite("WorkspaceShapeTests")
struct WorkspaceShapeTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // repo root

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Workspace references App, CLI, and Core")
    func workspaceReferencesAllThreeTargets() throws {
        let ws = try Self.read("Shotfuse.xcworkspace/contents.xcworkspacedata")
        #expect(ws.contains("App/App.xcodeproj"))
        #expect(ws.contains("CLI/CLI.xcodeproj"))
        #expect(ws.contains("group:Core"))
    }

    @Test("App depends on Core and not on CLI")
    func appLinksCoreOnly() throws {
        let yaml = try Self.read("App/project.yml")
        #expect(yaml.contains("path: ../Core"), "App must reference Core as a local package")
        #expect(yaml.contains("package: Core"), "App must declare Core as a dependency")
        #expect(!yaml.contains("../CLI"), "App must not reference CLI directory")
        #expect(!yaml.contains("target: CLI"), "App must not depend on CLI target")
        #expect(!yaml.contains("target: shot"), "App must not depend on shot binary target")
    }

    @Test("CLI depends on Core and not on App")
    func cliLinksCoreOnly() throws {
        let yaml = try Self.read("CLI/project.yml")
        #expect(yaml.contains("path: ../Core"), "CLI must reference Core as a local package")
        #expect(yaml.contains("package: Core"), "CLI must declare Core as a dependency")
        #expect(!yaml.contains("../App"), "CLI must not reference App directory")
        #expect(!yaml.contains("target: App"), "CLI must not depend on App target")
    }

    @Test("Core SwiftPM package has no App or CLI references")
    func coreIsIndependent() throws {
        let manifest = try Self.read("Core/Package.swift")
        #expect(!manifest.contains("../App"), "Core must not depend on App")
        #expect(!manifest.contains("../CLI"), "Core must not depend on CLI")
    }

    @Test("App Info.plist sets LSUIElement = true (menubar-only, no Dock icon)")
    func appIsMenubarOnly() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("App/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(plist)
        #expect(dict["LSUIElement"] as? Bool == true, "App must be menubar-only (§15.2)")
    }

    @Test("App Info.plist has Screen Recording + Accessibility TCC usage strings (§8)")
    func appHasTccUsageStrings() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("App/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(plist)
        let screen = dict["NSScreenCaptureUsageDescription"] as? String ?? ""
        let ax = dict["NSAccessibilityUsageDescription"] as? String ?? ""
        #expect(!screen.isEmpty, "Missing NSScreenCaptureUsageDescription (§8 Screen Recording gate)")
        #expect(!ax.isEmpty, "Missing NSAccessibilityUsageDescription (§8 Accessibility gate)")
    }

    @Test("App bundle identifier is dev.friquelme.shotfuse (§1)")
    func appBundleId() throws {
        let yaml = try Self.read("App/project.yml")
        #expect(yaml.contains("dev.friquelme.shotfuse"), "App must use bundle ID dev.friquelme.shotfuse (§1)")
    }

    @Test("CLI binary is named 'shot' (§1 CLI binary)")
    func cliBinaryName() throws {
        let yaml = try Self.read("CLI/project.yml")
        #expect(yaml.contains("PRODUCT_NAME: shot") || yaml.contains("name: shot"),
                "CLI target must produce a 'shot' binary (§1)")
    }
}
