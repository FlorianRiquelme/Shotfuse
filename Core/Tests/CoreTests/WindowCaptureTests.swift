import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import Core

// Tests for hq-dvr / P5.2: window + fullscreen capture.
//
// The filter-construction logic is factored into pure functions
// (`makeWindowCapturePlans`, `makeFullscreenCapturePlans`) that the tests
// exercise directly — real SCK calls require TCC and cannot run in CI.
// This mirrors the pattern established by `ScreenCaptureKitTests.swift`.

// MARK: - Fixtures

private struct FakeDisplay: DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let frame: CGRect
}

private struct FakeApp: RunningApplicationSnapshot {
    let bundleIdentifier: String
    let processID: pid_t
}

private struct FakeWindow: WindowSnapshot {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleIdentifier: String?
}

private struct FakeWindowContent: WindowShareableContentSnapshot {
    let displays: [any DisplaySnapshot]
    let applications: [any RunningApplicationSnapshot]
    let windows: [any WindowSnapshot]
}

private struct FakeWindowContentProvider: ShareableContentProviding {
    let content: FakeWindowContent
    func current() async throws -> any ShareableContentSnapshot { content }
}

private struct ThrowingContentProvider: ShareableContentProviding {
    let error: Error
    func current() async throws -> any ShareableContentSnapshot { throw error }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _urls
    }
    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        _urls.append(url)
    }
}

private struct UnreachableWindowCapturer: WindowScreenshotCapturing {
    func captureWindowImage(
        content: any WindowShareableContentSnapshot,
        filterPlan: WindowCaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        Issue.record("Window screenshot backend must not be called in this test")
        throw ScreenCaptureError.captureFailed("unreachable")
    }
}

private struct UnreachableFullscreenCapturer: FullscreenScreenshotCapturing {
    func captureFullscreenImage(
        content: any ShareableContentSnapshot,
        filterPlan: FullscreenCaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        Issue.record("Fullscreen screenshot backend must not be called in this test")
        throw ScreenCaptureError.captureFailed("unreachable")
    }
}

// Canonical fixture: two displays, one Shotfuse instance, a handful of other
// apps, and a target window belonging to a non-Shotfuse app.
private let fixtureDisplayID: CGDirectDisplayID = 42
private let fixtureSecondDisplayID: CGDirectDisplayID = 43
private let fixtureTargetWindowID: CGWindowID = 9001
private let fixtureTargetPID: pid_t = 555
private let fixtureShotfusePID: pid_t = 200

private func makeFixtureContent() -> FakeWindowContent {
    FakeWindowContent(
        displays: [
            FakeDisplay(
                displayID: fixtureDisplayID,
                width: 2880,
                height: 1800,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            FakeDisplay(
                displayID: fixtureSecondDisplayID,
                width: 1920,
                height: 1080,
                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            )
        ],
        applications: [
            FakeApp(bundleIdentifier: "com.apple.finder", processID: 100),
            FakeApp(bundleIdentifier: ShotfuseBundle.identifier, processID: fixtureShotfusePID),
            FakeApp(bundleIdentifier: "com.apple.dt.Xcode", processID: 300),
            FakeApp(bundleIdentifier: "com.example.target", processID: fixtureTargetPID)
        ],
        windows: [
            FakeWindow(
                windowID: fixtureTargetWindowID,
                ownerPID: fixtureTargetPID,
                ownerBundleIdentifier: "com.example.target"
            ),
            FakeWindow(
                windowID: 9002,
                ownerPID: fixtureShotfusePID,
                ownerBundleIdentifier: ShotfuseBundle.identifier
            )
        ]
    )
}

// MARK: - Suite

@Suite("WindowCaptureTests")
struct WindowCaptureTests {

    // (1) Window filter plan: includeChildWindows is TRUE (SPEC §14).

    @Test("window filter plan sets includeChildWindows = true")
    func windowFilterIncludesChildren() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (filterPlan, _) = try await capturer.planWindow(
            pid: fixtureTargetPID,
            windowID: fixtureTargetWindowID,
            includeChildren: true
        )
        #expect(filterPlan.includeChildWindows == true)
        #expect(filterPlan.windowID == fixtureTargetWindowID)
        #expect(filterPlan.ownerPID == fixtureTargetPID)
    }

    @Test("window filter plan excludes Shotfuse's own bundle (SPEC §5 I5)")
    func windowFilterExcludesShotfuse() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (filterPlan, _) = try await capturer.planWindow(
            pid: fixtureTargetPID,
            windowID: fixtureTargetWindowID,
            includeChildren: true
        )
        #expect(filterPlan.excludedApplicationBundleIDs == [ShotfuseBundle.identifier])
        #expect(filterPlan.excludedApplicationPIDs == [fixtureShotfusePID])
    }

    @Test("window config has showsCursor = false and capturesAudio = false")
    func windowConfigInvariants() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (_, configPlan) = try await capturer.planWindow(
            pid: fixtureTargetPID,
            windowID: fixtureTargetWindowID,
            includeChildren: true
        )
        #expect(configPlan.showsCursor == false)
        #expect(configPlan.capturesAudio == false)
    }

    @Test("captureWindow refuses to capture Shotfuse's own window")
    func windowCaptureRefusesSelfCapture() async {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        // Shotfuse's own window (9002 / fixtureShotfusePID) — plan builder
        // must reject before any capture happens.
        await #expect(throws: ScreenCaptureError.self) {
            _ = try await capturer.planWindow(
                pid: fixtureShotfusePID,
                windowID: 9002,
                includeChildren: true
            )
        }
    }

    @Test("captureWindow throws when the window is not in the snapshot")
    func windowCaptureMissingWindow() async {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.self) {
            _ = try await capturer.planWindow(
                pid: fixtureTargetPID,
                windowID: 99999,
                includeChildren: true
            )
        }
    }

    // (2) Fullscreen filter plan: exact display + self-exclusion.

    @Test("fullscreen filter plan targets exactly the requested display")
    func fullscreenFilterDisplayID() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (filterPlan, _) = try await capturer.planFullscreen(display: fixtureSecondDisplayID)
        #expect(filterPlan.displayID == fixtureSecondDisplayID)
    }

    @Test("fullscreen filter plan excludes Shotfuse's bundle windows (SPEC §5 I5)")
    func fullscreenFilterExcludesShotfuse() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (filterPlan, _) = try await capturer.planFullscreen(display: fixtureDisplayID)
        #expect(filterPlan.excludedApplicationBundleIDs == [ShotfuseBundle.identifier])
        #expect(filterPlan.excludedApplicationPIDs == [fixtureShotfusePID])
    }

    @Test("fullscreen config has showsCursor = false and capturesAudio = false")
    func fullscreenConfigInvariants() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (_, configPlan) = try await capturer.planFullscreen(display: fixtureDisplayID)
        #expect(configPlan.showsCursor == false)
        #expect(configPlan.capturesAudio == false)
    }

    @Test("fullscreen plan size matches the target display (not another display)")
    func fullscreenSizeIsSingleDisplay() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        let (_, primaryConfig) = try await capturer.planFullscreen(display: fixtureDisplayID)
        let (_, secondaryConfig) = try await capturer.planFullscreen(display: fixtureSecondDisplayID)
        #expect(primaryConfig.width == 2880)
        #expect(primaryConfig.height == 1800)
        #expect(secondaryConfig.width == 1920)
        #expect(secondaryConfig.height == 1080)
        // Guard: secondary display pixels must not match primary — this
        // is the test contract "must NOT capture other displays".
        #expect(primaryConfig != secondaryConfig)
    }

    @Test("fullscreen throws .displayNotFound when display id is absent")
    func fullscreenDisplayNotFound() async {
        let capturer = ScreenCapturer(
            contentProvider: FakeWindowContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.displayNotFound) {
            _ = try await capturer.planFullscreen(display: 99999)
        }
    }

    // (3) Preflight timeout + permission-denied deep-link for BOTH variants.

    @Test("captureWindow on permission-denied deep-links Settings")
    func windowPreflightDenyDeepLinks() async {
        let recorder = URLRecorder()
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: PermissionDeniedSignal()),
            deepLinkOpener: { url in recorder.record(url) },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureWindow(
                pid: fixtureTargetPID,
                windowID: fixtureTargetWindowID,
                includeChildren: true
            )
        }
        #expect(recorder.urls.first == screenRecordingSettingsURL)
    }

    @Test("captureFullscreen on permission-denied deep-links Settings")
    func fullscreenPreflightDenyDeepLinks() async {
        let recorder = URLRecorder()
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: PermissionDeniedSignal()),
            deepLinkOpener: { url in recorder.record(url) },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureFullscreen(display: fixtureDisplayID)
        }
        #expect(recorder.urls.first == screenRecordingSettingsURL)
    }

    @Test("captureWindow on TCC error normalizes to .permissionDenied")
    func windowPreflightTCCError() async {
        let recorder = URLRecorder()
        let tcc = NSError(domain: "com.apple.TCC.error", code: -1)
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: tcc),
            deepLinkOpener: { url in recorder.record(url) },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureWindow(
                pid: fixtureTargetPID,
                windowID: fixtureTargetWindowID,
                includeChildren: true
            )
        }
        #expect(recorder.urls.count == 1)
    }

    @Test("captureFullscreen on TCC error normalizes to .permissionDenied")
    func fullscreenPreflightTCCError() async {
        let recorder = URLRecorder()
        let tcc = NSError(domain: "com.apple.TCC.error", code: -1)
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: tcc),
            deepLinkOpener: { url in recorder.record(url) },
            windowScreenshot: UnreachableWindowCapturer(),
            fullscreenScreenshot: UnreachableFullscreenCapturer()
        )
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureFullscreen(display: fixtureDisplayID)
        }
        #expect(recorder.urls.count == 1)
    }
}
