import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Typed errors

/// Errors surfaced by `ScreenCapturer` during preflight and capture.
public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// TCC denied Screen Recording. Deep-linked to Settings as a side effect.
    case permissionDenied
    /// `SCShareableContent.current` did not resolve within the 1s preflight
    /// budget (SPEC §5 I8). Deep-linked to Settings as a side effect.
    case preflightTimeout
    /// The display referenced by the `RegionSelection` is not present in the
    /// resolved shareable content.
    case displayNotFound
    /// Underlying SCK failure surfaced with a readable description. Not
    /// `Equatable` in the structural sense — compared by associated value.
    case captureFailed(String)
}

// MARK: - Bundle-exclusion constant

/// Shotfuse's own bundle identifier (SPEC §5 I5). Public so that the test
/// suite and upstream callers can assert against the same canonical value.
public enum ShotfuseBundle {
    public static let identifier = "dev.friquelme.shotfuse"
}

// MARK: - Deep-link

/// Deep-link to System Settings → Privacy & Security → Screen Recording.
/// Kept as a constant so tests can assert on the exact URL.
public let screenRecordingSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
)!

// MARK: - Introspectable builder types
//
// `SCContentFilter` and `SCStreamConfiguration` expose init-only state and
// no public accessors for their inputs. To satisfy the test contract
// ("(b) filter exclusion introspectable", "(c) showsCursor == false"),
// `ScreenCapturer` first produces these plain-data plans, then hands them
// to a small builder that realizes them into the real SCK objects. Tests
// operate on the plans; production additionally instantiates the SCK
// objects from them.

/// Plain-data description of the `SCContentFilter` the capturer will build.
/// Holds only the data needed to make Invariant 5 (self-exclusion)
/// introspectable for tests.
public struct CaptureFilterPlan: Sendable, Equatable {
    /// The display the filter will target.
    public let displayID: CGDirectDisplayID
    /// Bundle IDs of applications whose windows will be excluded from the
    /// capture. Always contains `ShotfuseBundle.identifier` when Shotfuse
    /// apps appear in the shareable-content snapshot.
    public let excludedApplicationBundleIDs: [String]
    /// Process IDs of the excluded applications; mirrors
    /// `excludedApplicationBundleIDs` 1:1 and disambiguates multiple
    /// Shotfuse instances during development.
    public let excludedApplicationPIDs: [pid_t]

    public init(
        displayID: CGDirectDisplayID,
        excludedApplicationBundleIDs: [String],
        excludedApplicationPIDs: [pid_t]
    ) {
        self.displayID = displayID
        self.excludedApplicationBundleIDs = excludedApplicationBundleIDs
        self.excludedApplicationPIDs = excludedApplicationPIDs
    }
}

/// Plain-data description of the `SCStreamConfiguration` the capturer will
/// build. Carries the image-mode invariants (I10 no cursor, I11 no audio)
/// in a form tests can directly assert against.
public struct CaptureConfigurationPlan: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let sourceRect: CGRect
    public let showsCursor: Bool
    public let capturesAudio: Bool

    public init(
        width: Int,
        height: Int,
        sourceRect: CGRect,
        showsCursor: Bool,
        capturesAudio: Bool
    ) {
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
        self.showsCursor = showsCursor
        self.capturesAudio = capturesAudio
    }
}

// MARK: - Abstracted shareable-content snapshots

/// Minimal shape of `SCRunningApplication` that the capturer needs. Kept as
/// a protocol so tests can supply fixtures without constructing real
/// `SCRunningApplication` instances (whose `init` is `NS_UNAVAILABLE`).
public protocol RunningApplicationSnapshot: Sendable {
    var bundleIdentifier: String { get }
    var processID: pid_t { get }
}

/// Minimal shape of `SCDisplay`. Same reasoning as above.
public protocol DisplaySnapshot: Sendable {
    var displayID: CGDirectDisplayID { get }
    var width: Int { get }
    var height: Int { get }
    var frame: CGRect { get }
}

/// Minimal shape of `SCShareableContent`. The capturer consumes this abstract
/// view so the preflight + filter-construction path is fully testable
/// without real TCC permission or SCK objects.
public protocol ShareableContentSnapshot: Sendable {
    var displays: [any DisplaySnapshot] { get }
    var applications: [any RunningApplicationSnapshot] { get }
}

/// Something that can resolve the current shareable content. The default
/// implementation wraps `SCShareableContent.current`; tests inject a double
/// that either returns a fixture, throws permissionDenied, or hangs to
/// force the 1s preflight timeout.
public protocol ShareableContentProviding: Sendable {
    func current() async throws -> any ShareableContentSnapshot
}

// MARK: - Real provider wrapping SCShareableContent

/// Real `SCRunningApplication` adapter. `@unchecked Sendable` because the
/// SCK type is an immutable-by-observation NSObject that SCK itself hands
/// across actor boundaries.
struct SCRunningApplicationAdapter: RunningApplicationSnapshot, @unchecked Sendable {
    let underlying: SCRunningApplication
    var bundleIdentifier: String { underlying.bundleIdentifier }
    var processID: pid_t { underlying.processID }
}

/// Real `SCDisplay` adapter.
struct SCDisplayAdapter: DisplaySnapshot, @unchecked Sendable {
    let underlying: SCDisplay
    var displayID: CGDirectDisplayID { underlying.displayID }
    var width: Int { underlying.width }
    var height: Int { underlying.height }
    var frame: CGRect { underlying.frame }
}

/// Real `SCShareableContent` adapter. Carries the underlying content so
/// the capturer can reach the genuine `SCDisplay` + `SCRunningApplication`
/// references after introspection.
struct SCShareableContentAdapter: ShareableContentSnapshot, @unchecked Sendable {
    let underlying: SCShareableContent
    var displays: [any DisplaySnapshot] {
        underlying.displays.map { SCDisplayAdapter(underlying: $0) }
    }
    var applications: [any RunningApplicationSnapshot] {
        underlying.applications.map { SCRunningApplicationAdapter(underlying: $0) }
    }
}

/// Production provider: calls `SCShareableContent.current`.
public struct DefaultShareableContentProvider: ShareableContentProviding {
    public init() {}
    public func current() async throws -> any ShareableContentSnapshot {
        let content = try await SCShareableContent.current
        return SCShareableContentAdapter(underlying: content)
    }
}

// MARK: - ScreenCapturer

/// Single-frame screen capture via `ScreenCaptureKit` (SPEC §5 I5/I8/I10/I11).
///
/// `ScreenCapturer` is an `actor` so it can own preflight state without
/// cross-thread mutation. It never runs a long-lived SCStream — v0.1 is
/// image-only (I11: no audio during any SCStream session).
public actor ScreenCapturer {

    // MARK: Configuration

    /// Preflight budget from SPEC §5 I8.
    public static let preflightTimeout: Duration = .seconds(1)

    // MARK: Collaborators (all injectable)

    private let contentProvider: any ShareableContentProviding
    private let deepLinkOpener: @Sendable (URL) -> Void
    private let clock: any Clock<Duration>
    private let selfBundleIdentifier: String
    private let screenshot: any ScreenshotCapturing
    private let windowScreenshot: any WindowScreenshotCapturing
    private let fullscreenScreenshot: any FullscreenScreenshotCapturing

    // MARK: Init

    /// Designated initializer; all side-effects injectable.
    ///
    /// - Parameters:
    ///   - contentProvider: shareable-content source. Defaults to
    ///     `DefaultShareableContentProvider` (the real SCK path).
    ///   - deepLinkOpener: invoked with the Settings URL when preflight
    ///     fails. Defaults to `NSWorkspace.shared.open(_:)`. Tests supply a
    ///     capturing closure to assert the deep-link fired.
    ///   - clock: used to enforce the 1s preflight timeout. Production uses
    ///     `ContinuousClock()`; tests can supply a fake clock.
    ///   - selfBundleIdentifier: bundle ID to exclude from the content
    ///     filter. Defaults to `ShotfuseBundle.identifier`.
    ///   - screenshot: the frame-grab backend for region capture.
    ///   - windowScreenshot: the frame-grab backend for window capture
    ///     (SPEC §14; hq-dvr). Defaults to the real SCK path.
    ///   - fullscreenScreenshot: the frame-grab backend for fullscreen
    ///     capture (hq-dvr). Defaults to the real SCK path.
    public init(
        contentProvider: any ShareableContentProviding = DefaultShareableContentProvider(),
        deepLinkOpener: @escaping @Sendable (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        clock: any Clock<Duration> = ContinuousClock(),
        selfBundleIdentifier: String = ShotfuseBundle.identifier,
        screenshot: any ScreenshotCapturing = DefaultScreenshotCapturer(),
        windowScreenshot: any WindowScreenshotCapturing = DefaultWindowScreenshotCapturer(),
        fullscreenScreenshot: any FullscreenScreenshotCapturing = DefaultFullscreenScreenshotCapturer()
    ) {
        self.contentProvider = contentProvider
        self.deepLinkOpener = deepLinkOpener
        self.clock = clock
        self.selfBundleIdentifier = selfBundleIdentifier
        self.screenshot = screenshot
        self.windowScreenshot = windowScreenshot
        self.fullscreenScreenshot = fullscreenScreenshot
    }

    // MARK: - Public API

    /// Capture a single frame of the given region. Runs preflight first
    /// (SPEC §5 I8); on permission-denied or timeout, deep-links to Settings
    /// and throws a typed error.
    public func captureFrame(selection: RegionSelection) async throws -> CapturedFrame {
        let content = try await preflight()
        let (filterPlan, configPlan) = try makePlans(content: content, selection: selection)
        let image = try await screenshot.captureImage(
            content: content,
            filterPlan: filterPlan,
            configurationPlan: configPlan
        )
        let pixelBounds = pixelBounds(for: selection, configPlan: configPlan)
        return CapturedFrame(
            image: image,
            pixelBounds: pixelBounds,
            display: selection.display,
            capturedAt: Date()
        )
    }

    /// Run only the preflight + plan step and return the plans. Used by
    /// tests to assert on filter/config shape without running capture.
    public func plan(for selection: RegionSelection) async throws -> (CaptureFilterPlan, CaptureConfigurationPlan) {
        let content = try await preflight()
        return try makePlans(content: content, selection: selection)
    }

    // MARK: - Window capture (SPEC §14; hq-dvr / P5.2)

    /// Capture a single window by owning PID + `CGWindowID`.
    ///
    /// - Parameters:
    ///   - pid: owning-application PID of the target window.
    ///   - windowID: `CGWindowID` (WindowServer id) of the target window.
    ///   - includeChildren: SPEC §14 — `true` composites sheets/popovers
    ///     into the frame. v0.1 always passes `true` from the hotkey path.
    /// - Throws: `ScreenCaptureError.permissionDenied` /
    ///   `.preflightTimeout` / `.captureFailed`.
    public func captureWindow(
        pid: pid_t,
        windowID: CGWindowID,
        includeChildren: Bool
    ) async throws -> CapturedFrame {
        let content = try await preflight()
        guard let windowContent = content as? any WindowShareableContentSnapshot else {
            throw ScreenCaptureError.captureFailed(
                "Window capture requires a window-aware ShareableContentProviding"
            )
        }
        let (filterPlan, configPlan) = try makeWindowCapturePlans(
            content: windowContent,
            pid: pid,
            windowID: windowID,
            includeChildren: includeChildren,
            selfBundleIdentifier: selfBundleIdentifier
        )
        let image = try await windowScreenshot.captureWindowImage(
            content: windowContent,
            filterPlan: filterPlan,
            configurationPlan: configPlan
        )
        // Window capture has no natural `DisplayMetadata`; callers who need
        // it can hit-test the window's frame themselves. We use a synthetic
        // `DisplayMetadata` with the window's host display at 0 — downstream
        // packaging (CaptureFinalization) only reads pixelBounds/image here.
        let pixelBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        return CapturedFrame(
            image: image,
            pixelBounds: pixelBounds,
            display: DisplayMetadata(
                id: 0,
                nativeWidth: image.width,
                nativeHeight: image.height,
                nativeScale: 1.0,
                vendorID: nil,
                productID: nil,
                serial: nil,
                localizedName: "",
                globalFrame: .zero
            ),
            capturedAt: Date()
        )
    }

    /// Plan-only variant of `captureWindow` for test introspection.
    public func planWindow(
        pid: pid_t,
        windowID: CGWindowID,
        includeChildren: Bool
    ) async throws -> (WindowCaptureFilterPlan, CaptureConfigurationPlan) {
        let content = try await preflight()
        guard let windowContent = content as? any WindowShareableContentSnapshot else {
            throw ScreenCaptureError.captureFailed(
                "Window capture requires a window-aware ShareableContentProviding"
            )
        }
        return try makeWindowCapturePlans(
            content: windowContent,
            pid: pid,
            windowID: windowID,
            includeChildren: includeChildren,
            selfBundleIdentifier: selfBundleIdentifier
        )
    }

    // MARK: - Fullscreen capture (hq-dvr / P5.2)

    /// Capture the full frame of a single `SCDisplay`.
    ///
    /// - Parameter display: `CGDirectDisplayID` of the target display.
    ///   The resulting frame captures ONLY this display; no other display's
    ///   pixels leak into the output.
    public func captureFullscreen(
        display: CGDirectDisplayID
    ) async throws -> CapturedFrame {
        let content = try await preflight()
        let (filterPlan, configPlan, displaySnap) = try makeFullscreenCapturePlans(
            content: content,
            displayID: display,
            selfBundleIdentifier: selfBundleIdentifier
        )
        let image = try await fullscreenScreenshot.captureFullscreenImage(
            content: content,
            filterPlan: filterPlan,
            configurationPlan: configPlan
        )
        let pixelBounds = CGRect(
            x: 0,
            y: 0,
            width: configPlan.width,
            height: configPlan.height
        )
        return CapturedFrame(
            image: image,
            pixelBounds: pixelBounds,
            display: DisplayMetadata(
                id: displaySnap.displayID,
                nativeWidth: displaySnap.width,
                nativeHeight: displaySnap.height,
                nativeScale: 1.0,
                vendorID: nil,
                productID: nil,
                serial: nil,
                localizedName: "",
                globalFrame: displaySnap.frame
            ),
            capturedAt: Date()
        )
    }

    /// Plan-only variant of `captureFullscreen` for test introspection.
    public func planFullscreen(
        display: CGDirectDisplayID
    ) async throws -> (FullscreenCaptureFilterPlan, CaptureConfigurationPlan) {
        let content = try await preflight()
        let (filterPlan, configPlan, _) = try makeFullscreenCapturePlans(
            content: content,
            displayID: display,
            selfBundleIdentifier: selfBundleIdentifier
        )
        return (filterPlan, configPlan)
    }

    // MARK: - Preflight

    private func preflight() async throws -> any ShareableContentSnapshot {
        try await withTimeout(Self.preflightTimeout, clock: clock) {
            try await self.contentProvider.current()
        } onTimeout: {
            self.deepLinkOpener(screenRecordingSettingsURL)
            return ScreenCaptureError.preflightTimeout
        } mapError: { error in
            if Self.isPermissionDenied(error) {
                self.deepLinkOpener(screenRecordingSettingsURL)
                return ScreenCaptureError.permissionDenied
            }
            return nil
        }
    }

    /// `SCStreamErrorUserDeclined` from `<ScreenCaptureKit/SCError.h>`.
    /// Hard-coded because the bridged Swift enum is not exposed here.
    private static let scStreamErrorUserDeclined = -3801

    /// `SCShareableContent.current` throws `TCCError` or `SCStreamError` on
    /// denial. We detect both shapes so tests can fake either.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        // SCK's own user-declined error.
        if ns.domain == SCStreamErrorDomain,
           ns.code == Self.scStreamErrorUserDeclined {
            return true
        }
        // TCC (private) errors that surface from SCShareableContent.current
        // when Screen Recording is disabled use domain "com.apple.TCC" /
        // "TCCErrorDomain" depending on OS version.
        if ns.domain.contains("TCC") { return true }
        // Explicit signal from injected fakes.
        if error is PermissionDeniedSignal { return true }
        return false
    }

    // MARK: - Plan construction

    private func makePlans(
        content: any ShareableContentSnapshot,
        selection: RegionSelection
    ) throws -> (CaptureFilterPlan, CaptureConfigurationPlan) {
        guard let display = content.displays.first(where: {
            $0.displayID == selection.display.id
        }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let excluded = content.applications.filter {
            $0.bundleIdentifier == selfBundleIdentifier
        }

        let filterPlan = CaptureFilterPlan(
            displayID: display.displayID,
            excludedApplicationBundleIDs: excluded.map(\.bundleIdentifier),
            excludedApplicationPIDs: excluded.map(\.processID)
        )

        let scale = selection.display.nativeScale
        let pixelW = Int((selection.rect.width * CGFloat(scale)).rounded())
        let pixelH = Int((selection.rect.height * CGFloat(scale)).rounded())

        let configPlan = CaptureConfigurationPlan(
            width: max(pixelW, 1),
            height: max(pixelH, 1),
            sourceRect: selection.rect,  // SCK sourceRect is in points
            showsCursor: false,           // SPEC §5 I10
            capturesAudio: false          // SPEC §5 I11
        )
        return (filterPlan, configPlan)
    }

    private func pixelBounds(
        for selection: RegionSelection,
        configPlan: CaptureConfigurationPlan
    ) -> CGRect {
        // Origin at zero because the master-pixel space is local to the
        // captured image, not the display. Width/height mirror the config.
        return CGRect(x: 0, y: 0, width: configPlan.width, height: configPlan.height)
    }
}

// MARK: - Screenshot backend

/// Executes the actual frame capture once the capturer has resolved the
/// plans. Split out so tests can substitute a no-op implementation.
public protocol ScreenshotCapturing: Sendable {
    func captureImage(
        content: any ShareableContentSnapshot,
        filterPlan: CaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage
}

/// Real backend: builds `SCContentFilter` + `SCStreamConfiguration` from
/// the plans and hands them to `SCScreenshotManager.captureImage`.
public struct DefaultScreenshotCapturer: ScreenshotCapturing {
    public init() {}

    public func captureImage(
        content: any ShareableContentSnapshot,
        filterPlan: CaptureFilterPlan,
        configurationPlan configPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        // Only the real adapter carries the SCK objects we need to build
        // a live filter. Fakes never reach this code path.
        guard let adapter = content as? SCShareableContentAdapter else {
            throw ScreenCaptureError.captureFailed(
                "DefaultScreenshotCapturer requires real SCShareableContent"
            )
        }
        let real = adapter.underlying

        guard let display = real.displays.first(where: {
            $0.displayID == filterPlan.displayID
        }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let excludedApps = real.applications.filter {
            filterPlan.excludedApplicationBundleIDs.contains($0.bundleIdentifier)
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = configPlan.width
        config.height = configPlan.height
        config.sourceRect = configPlan.sourceRect
        config.showsCursor = configPlan.showsCursor
        config.capturesAudio = configPlan.capturesAudio

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw ScreenCaptureError.captureFailed(String(describing: error))
        }
    }
}

// MARK: - Internal helpers

/// Signal used by test fakes to say "treat me as TCC-denied" without
/// pulling a private error domain into the test bundle.
public struct PermissionDeniedSignal: Error, Sendable {
    public init() {}
}

/// Run `operation` with a timeout. On timeout, `onTimeout` is invoked and
/// its return value is thrown. On error, `mapError` gets a chance to
/// convert the error (e.g., to `.permissionDenied`); returning `nil` means
/// "rethrow the original error".
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    clock: any Clock<Duration>,
    operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () -> Error,
    mapError: @escaping @Sendable (Error) -> Error?
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            do {
                return try await operation()
            } catch {
                if let mapped = mapError(error) { throw mapped }
                throw error
            }
        }
        group.addTask {
            try await clock.sleep(for: duration)
            throw onTimeout()
        }
        defer { group.cancelAll() }
        // First completion wins.
        guard let result = try await group.next() else {
            throw onTimeout()
        }
        return result
    }
}
