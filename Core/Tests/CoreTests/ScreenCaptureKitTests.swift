import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import Core

// MARK: - Test fixtures

/// Plain-data `DisplaySnapshot` for test content.
private struct FakeDisplay: DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let frame: CGRect
}

/// Plain-data `RunningApplicationSnapshot` for test content.
private struct FakeApp: RunningApplicationSnapshot {
    let bundleIdentifier: String
    let processID: pid_t
}

/// Plain-data `ShareableContentSnapshot` for test content.
private struct FakeContent: ShareableContentSnapshot {
    let displays: [any DisplaySnapshot]
    let applications: [any RunningApplicationSnapshot]
}

/// Content provider that always returns the same fixture.
private struct FakeContentProvider: ShareableContentProviding {
    let content: FakeContent
    func current() async throws -> any ShareableContentSnapshot { content }
}

/// Content provider that always throws.
private struct ThrowingContentProvider: ShareableContentProviding {
    let error: Error
    func current() async throws -> any ShareableContentSnapshot { throw error }
}

/// Content provider that never returns, forcing the preflight timeout.
private struct HangingContentProvider: ShareableContentProviding {
    func current() async throws -> any ShareableContentSnapshot {
        // Sleep forever; the 1s timeout should fire first.
        try await Task.sleep(for: .seconds(3600))
        fatalError("unreachable in tests")
    }
}

/// Thread-safe recorder for captured URLs; the deep-link closure writes into
/// it from the capturer's isolation domain.
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

/// Screenshot backend that is never reached in these tests; guards any
/// accidental production code path.
private struct UnreachableScreenshotCapturer: ScreenshotCapturing {
    func captureImage(
        content: any ShareableContentSnapshot,
        filterPlan: CaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        Issue.record("Screenshot backend must not be called in this test")
        throw ScreenCaptureError.captureFailed("unreachable")
    }
}

// MARK: - Shared fixture helpers

private let fixtureDisplayID: CGDirectDisplayID = 42
private let fixtureDisplayMeta = DisplayMetadata(
    id: fixtureDisplayID,
    nativeWidth: 2880,
    nativeHeight: 1800,
    nativeScale: 2.0,
    localizedName: "Fixture Display"
)
private let fixtureSelection = RegionSelection(
    rect: CGRect(x: 100, y: 200, width: 300, height: 400),
    display: fixtureDisplayMeta
)

/// Baseline shareable-content snapshot containing one display and one
/// Shotfuse-bundled app alongside a couple of unrelated apps.
private func makeFixtureContent() -> FakeContent {
    FakeContent(
        displays: [
            FakeDisplay(
                displayID: fixtureDisplayID,
                width: 1440,
                height: 900,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            )
        ],
        applications: [
            FakeApp(bundleIdentifier: "com.apple.finder", processID: 100),
            FakeApp(bundleIdentifier: ShotfuseBundle.identifier, processID: 200),
            FakeApp(bundleIdentifier: "com.apple.dt.Xcode", processID: 300)
        ]
    )
}

// MARK: - Suite

@Suite("ScreenCaptureKitTests")
struct ScreenCaptureKitTests {

    // (a) Preflight-deny deep-links.

    @Test("permission-denied preflight throws .permissionDenied and deep-links Settings")
    func preflightDenyDeepLinks() async {
        let recorder = URLRecorder()
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: PermissionDeniedSignal()),
            deepLinkOpener: { url in recorder.record(url) },
            screenshot: UnreachableScreenshotCapturer()
        )

        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureFrame(selection: fixtureSelection)
        }

        let urls = recorder.urls
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString.contains("Privacy_ScreenCapture") == true)
        #expect(urls.first == screenRecordingSettingsURL)
    }

    @Test("TCC-error preflight also normalizes to .permissionDenied + deep-link")
    func preflightTCCDomainDeepLinks() async {
        let recorder = URLRecorder()
        let tccError = NSError(domain: "com.apple.TCC.error", code: -1, userInfo: nil)
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: tccError),
            deepLinkOpener: { url in recorder.record(url) },
            screenshot: UnreachableScreenshotCapturer()
        )

        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureFrame(selection: fixtureSelection)
        }
        #expect(recorder.urls.first?.absoluteString.contains("Privacy_ScreenCapture") == true)
    }

    @Test("SCStreamErrorUserDeclined (domain=SCStreamErrorDomain, code=-3801) normalizes to .permissionDenied")
    func preflightSCStreamUserDeclined() async {
        let recorder = URLRecorder()
        let scError = NSError(domain: SCStreamErrorDomain, code: -3801, userInfo: nil)
        let capturer = ScreenCapturer(
            contentProvider: ThrowingContentProvider(error: scError),
            deepLinkOpener: { url in recorder.record(url) },
            screenshot: UnreachableScreenshotCapturer()
        )

        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await capturer.captureFrame(selection: fixtureSelection)
        }
        #expect(recorder.urls.count == 1)
    }

    @Test("preflight timeout throws .preflightTimeout and deep-links Settings")
    func preflightTimeoutDeepLinks() async {
        let recorder = URLRecorder()
        let capturer = ScreenCapturer(
            contentProvider: HangingContentProvider(),
            deepLinkOpener: { url in recorder.record(url) },
            // Shrink the timeout from 1s to 50ms for fast tests; the
            // capturer's public preflightTimeout is the real contract,
            // but the timeout mechanism itself is what we are asserting
            // here (and we can't override the constant). To keep this
            // test fast, we rely on the hang + 1s real timeout.
            screenshot: UnreachableScreenshotCapturer()
        )

        await #expect(throws: ScreenCaptureError.preflightTimeout) {
            _ = try await capturer.captureFrame(selection: fixtureSelection)
        }
        let urls = recorder.urls
        #expect(urls.first == screenRecordingSettingsURL)
    }

    // (b) Filter excludes Shotfuse windows.

    @Test("filter plan excludes the Shotfuse bundle from the SCContentFilter")
    func filterExcludesShotfuse() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )

        let (filterPlan, _) = try await capturer.plan(for: fixtureSelection)

        #expect(filterPlan.displayID == fixtureDisplayID)
        #expect(filterPlan.excludedApplicationBundleIDs.contains(ShotfuseBundle.identifier))
        #expect(filterPlan.excludedApplicationBundleIDs.count == 1)
        #expect(filterPlan.excludedApplicationPIDs == [200])
    }

    @Test("filter plan excludes every Shotfuse instance when multiple are running")
    func filterExcludesAllShotfuseInstances() async throws {
        let content = FakeContent(
            displays: [
                FakeDisplay(
                    displayID: fixtureDisplayID,
                    width: 1440,
                    height: 900,
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
                )
            ],
            applications: [
                FakeApp(bundleIdentifier: ShotfuseBundle.identifier, processID: 201),
                FakeApp(bundleIdentifier: ShotfuseBundle.identifier, processID: 202),
                FakeApp(bundleIdentifier: "com.apple.finder", processID: 100)
            ]
        )
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: content),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )

        let (filterPlan, _) = try await capturer.plan(for: fixtureSelection)

        #expect(filterPlan.excludedApplicationBundleIDs == [
            ShotfuseBundle.identifier,
            ShotfuseBundle.identifier
        ])
        #expect(Set(filterPlan.excludedApplicationPIDs) == Set([201, 202]))
    }

    @Test("filter plan excludes nothing when no Shotfuse instance is listed (dev / mis-config guard)")
    func filterExcludesNothingWhenAbsent() async throws {
        let content = FakeContent(
            displays: [
                FakeDisplay(
                    displayID: fixtureDisplayID,
                    width: 1440,
                    height: 900,
                    frame: .zero
                )
            ],
            applications: [
                FakeApp(bundleIdentifier: "com.apple.finder", processID: 100)
            ]
        )
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: content),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )

        let (filterPlan, _) = try await capturer.plan(for: fixtureSelection)
        #expect(filterPlan.excludedApplicationBundleIDs.isEmpty)
        #expect(filterPlan.excludedApplicationPIDs.isEmpty)
    }

    @Test("display not found throws .displayNotFound (not a silent whole-screen capture)")
    func displayNotFoundThrows() async {
        let otherDisplay = FakeContent(
            displays: [
                FakeDisplay(displayID: 999, width: 100, height: 100, frame: .zero)
            ],
            applications: []
        )
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: otherDisplay),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )
        await #expect(throws: ScreenCaptureError.displayNotFound) {
            _ = try await capturer.captureFrame(selection: fixtureSelection)
        }
    }

    // (c) showsCursor = false (SPEC §5 I10) and capturesAudio = false (I11).

    @Test("config plan has showsCursor = false (SPEC §5 I10)")
    func configShowsCursorFalse() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )
        let (_, configPlan) = try await capturer.plan(for: fixtureSelection)
        #expect(configPlan.showsCursor == false)
    }

    @Test("config plan has capturesAudio = false (SPEC §5 I11)")
    func configCapturesAudioFalse() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )
        let (_, configPlan) = try await capturer.plan(for: fixtureSelection)
        #expect(configPlan.capturesAudio == false)
    }

    @Test("config plan width/height are computed in master pixels (point * nativeScale)")
    func configPixelDimensions() async throws {
        let capturer = ScreenCapturer(
            contentProvider: FakeContentProvider(content: makeFixtureContent()),
            deepLinkOpener: { _ in },
            screenshot: UnreachableScreenshotCapturer()
        )
        let (_, configPlan) = try await capturer.plan(for: fixtureSelection)
        #expect(configPlan.width == 600)   // 300 * 2.0
        #expect(configPlan.height == 800)  // 400 * 2.0
        #expect(configPlan.sourceRect == fixtureSelection.rect)
    }

    // Settings URL stability.

    @Test("screenRecordingSettingsURL targets the Screen Recording privacy pane")
    func settingsURLShape() {
        let s = screenRecordingSettingsURL.absoluteString
        #expect(s.hasPrefix("x-apple.systempreferences:"))
        #expect(s.contains("Privacy_ScreenCapture"))
    }
}
