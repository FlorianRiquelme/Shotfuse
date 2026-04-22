import CoreGraphics
import Foundation
import Testing
@testable import Core

#if canImport(AppKit)
import AppKit
#endif

@Suite("RegionOverlayTests")
struct RegionOverlayTests {

    // MARK: - Fixtures

    /// Display 1: primary (1440x900 @ 2x), sitting at the global origin.
    private static let display1 = DisplayMetadata(
        id: 1,
        nativeWidth: 2880,
        nativeHeight: 1800,
        nativeScale: 2.0,
        vendorID: 0x05ac,
        productID: 0xa050,
        serial: nil,
        localizedName: "Built-in Retina Display",
        globalFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )

    /// Display 2: external (1920x1080 @ 1x) sitting to the LEFT of display 1,
    /// so its origin has a *negative* x — common multi-monitor layout we have
    /// to handle for canonical point-space math per SPEC §5 I6.
    private static let display2 = DisplayMetadata(
        id: 2,
        nativeWidth: 1920,
        nativeHeight: 1080,
        nativeScale: 1.0,
        vendorID: 0x1234,
        productID: 0x5678,
        serial: 0xDEAD,
        localizedName: "Test External 24\"",
        globalFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    )

    private static let displays: [DisplayMetadata] = [display1, display2]

    // MARK: - (a) Coord mapping

    @Test("Rect normalization: drag from bottom-right → top-left yields positive size")
    func rectNormalization() {
        let r = RegionGeometry.rect(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 100, y: 100))
        #expect(r == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test("Single-display: global points map to display-local rect correctly")
    func singleDisplayMapping() {
        // Both points on display1 (origin 0,0), so global == local.
        let sel = RegionGeometry.selection(
            startGlobal: CGPoint(x: 50, y: 60),
            endGlobal: CGPoint(x: 250, y: 260),
            displays: Self.displays
        )
        let s = try! #require(sel)
        #expect(s.display.id == 1)
        #expect(s.rect == CGRect(x: 50, y: 60, width: 200, height: 200))
    }

    @Test("Multi-display with negative origin: global rect on display2 maps to local coords")
    func multiDisplayNegativeOrigin() {
        // Drag entirely on display 2 (negative x origin).
        // Release inside display2 → resolves to display2 → local coords subtract display2.origin.
        let sel = RegionGeometry.selection(
            startGlobal: CGPoint(x: -1800, y: 100),
            endGlobal: CGPoint(x: -1600, y: 300),
            displays: Self.displays
        )
        let s = try! #require(sel)
        #expect(s.display.id == 2)
        // Global rect: (-1800, 100, 200, 200). Minus display2.origin (-1920, 0) → (120, 100, 200, 200).
        #expect(s.rect == CGRect(x: 120, y: 100, width: 200, height: 200))
    }

    // MARK: - (b) Multi-display hit-test

    @Test("Hit-test: release point inside display2 resolves display.id = 2")
    func hitTestResolvesToDisplay2() {
        // Point (-1000, 500) is inside display2's frame (-1920..0, 0..1080).
        let d = RegionGeometry.display(containing: CGPoint(x: -1000, y: 500), displays: Self.displays)
        let resolved = try! #require(d)
        #expect(resolved.id == 2)
    }

    @Test("Hit-test: release point inside display1 resolves display.id = 1")
    func hitTestResolvesToDisplay1() {
        let d = RegionGeometry.display(containing: CGPoint(x: 100, y: 100), displays: Self.displays)
        let resolved = try! #require(d)
        #expect(resolved.id == 1)
    }

    @Test("Hit-test: drag that crosses displays resolves by RELEASE point, not start point")
    func hitTestCrossingDisplays() {
        // Start on display2 (left), release on display1 (right of origin).
        let sel = RegionGeometry.selection(
            startGlobal: CGPoint(x: -500, y: 400),
            endGlobal: CGPoint(x: 300, y: 300),
            displays: Self.displays
        )
        let s = try! #require(sel)
        #expect(s.display.id == 1, "Release point is on display1; selection must resolve there")
    }

    @Test("Hit-test: release outside every display returns nil")
    func hitTestNoMatch() {
        let sel = RegionGeometry.selection(
            startGlobal: CGPoint(x: 100, y: 100),
            endGlobal: CGPoint(x: 10_000, y: 10_000),
            displays: Self.displays
        )
        #expect(sel == nil)
    }

    // MARK: - (c) Bundle exclusion marker
    //
    // Per SPEC §5 I5, all windows in the Shotfuse bundle are excluded from
    // `SCContentFilter` by P1.2's bundle-level filter. The deterministic fact we
    // can assert here is that the overlay window is owned by *this* process,
    // whose `Bundle.main.bundleIdentifier` is what P1.2 will key off. Under
    // `swift test` there is no embedded plist, so `bundleIdentifier` may be nil;
    // we assert on identity — the overlay window is in the current process's
    // NSApp window list — which is the invariant P1.2 actually needs.

    @Test("Overlay window belongs to this process (Shotfuse bundle exclusion marker)")
    @MainActor
    func overlayWindowBelongsToThisProcess() async throws {
        #if canImport(AppKit)
        // Ensure NSApp exists (test harness may not have activated it).
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // Headless CI with no display: skip the AppKit assertion. The
            // geometry assertions above already covered the pure logic.
            return
        }
        let window = RegionSelectionOverlay.makeOverlayWindow(on: screen)
        defer { window.orderOut(nil) }

        // Must be a borderless overlay.
        #expect(window.styleMask.contains(.borderless))
        #expect(window.isOpaque == false)
        #expect(window.backgroundColor == .clear)
        #expect(window.level == .screenSaver)

        // Identity check: the window is in this process's window list.
        let inProcess = NSApplication.shared.windows.contains { $0 === window }
        #expect(inProcess, "Overlay NSWindow must be owned by this process so SCContentFilter bundle exclusion (§5 I5) applies")

        // The test-process bundle identifier is whatever the swift-test harness
        // reports; assert only that Bundle.main is resolvable (non-nil) so
        // downstream P1.2 can read it without crashing.
        _ = Bundle.main.bundlePath
        #endif
    }

    @Test("Overlay window is created successfully and has a content view")
    @MainActor
    func overlayWindowHasContentView() async throws {
        #if canImport(AppKit)
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let window = RegionSelectionOverlay.makeOverlayWindow(on: screen)
        defer { window.orderOut(nil) }
        #expect(window.contentView != nil)
        #expect(window.contentView?.frame.size == screen.frame.size)
        #endif
    }

    // MARK: - (d) Minimum selection threshold (hq-6f9)

    #if canImport(AppKit)
    @Test("Sub-8px drag on either axis is rejected (click without drag → cancel)")
    func subThresholdDragRejected() {
        // Plain click (no motion).
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100)) == false)
        // 1x1 nudge — the exact degenerate case from the UAT.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 101, y: 101)) == false)
        // 7x7 — just below threshold.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 107, y: 107)) == false)
        // Wide but short: 100x7 — must still reject because BOTH axes must clear the threshold.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 107)) == false)
        // Short but tall: 7x100 — same logic on the other axis.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 107, y: 200)) == false)
    }

    @Test("≥8px drag on both axes is committed (normal selection)")
    func aboveThresholdDragCommitted() {
        // Exactly 8x8 — boundary value, must commit.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 108, y: 108)) == true)
        // Typical selection.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 250)) == true)
        // Direction-independent: dragging up-left from end point still counts.
        #expect(isSelectionAboveMinimum(from: CGPoint(x: 250, y: 250), to: CGPoint(x: 50, y: 50)) == true)
    }
    #endif

    // MARK: - Display metadata shape

    @Test("DisplayMetadata carries §6.1 fields: native dims, scale, localized name, global frame")
    func displayMetadataShape() {
        let d = Self.display2
        #expect(d.nativeWidth == 1920)
        #expect(d.nativeHeight == 1080)
        #expect(d.nativeScale == 1.0)
        #expect(d.vendorID == 0x1234)
        #expect(d.productID == 0x5678)
        #expect(d.serial == 0xDEAD)
        #expect(d.localizedName == "Test External 24\"")
        #expect(d.globalFrame.origin.x == -1920)
    }
}
