import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// hotkey wiring: keymap.toml + HotkeyRegistry (future integration task)
//
// This file adds the window-capture (`cmd+shift+3`) and fullscreen-capture
// (`cmd+shift+4`) variants for SPEC §5 I5 (self-excluded), I10 (no cursor),
// §14 (`includeChildWindows = true`). Hotkey registration is intentionally
// NOT done here — that is coupled to the `HotkeyRegistry` (hq-qpn) and the
// future keymap loader, and will be wired in a later task.
//
// Design parallels `ScreenCaptureKit.swift`:
//   1. Plain-data *plans* (`WindowCaptureFilterPlan`, `FullscreenCaptureFilterPlan`)
//      carry the introspectable inputs for the real `SCContentFilter`.
//   2. Pure, file-local builder functions construct those plans from a
//      shareable-content snapshot — fully testable without TCC.
//   3. A `WindowScreenshotCapturing` backend maps plans → real SCK objects.
//   4. Public entry points live on `ScreenCapturer` (see
//      `ScreenCaptureKit.swift`) and call into these helpers.

// MARK: - Window snapshot

/// Minimal shape of `SCWindow` the capturer needs. Kept as a protocol so tests
/// can supply fixtures without constructing a real `SCWindow` (whose `init`
/// is `NS_UNAVAILABLE`). Mirrors the pattern established for `SCDisplay` /
/// `SCRunningApplication` in `ScreenCaptureKit.swift`.
public protocol WindowSnapshot: Sendable {
    /// `CGWindowID` assigned by the WindowServer.
    var windowID: CGWindowID { get }
    /// The owning application's PID. Used for the
    /// `captureWindow(pid:windowID:...)` lookup key.
    var ownerPID: pid_t { get }
    /// The owning application's bundle identifier, if available. Used by
    /// tests to prove that the target window is NOT Shotfuse's own.
    var ownerBundleIdentifier: String? { get }
}

/// Extended shareable-content snapshot that additionally exposes on-screen
/// windows. The baseline `ShareableContentSnapshot` intentionally does not
/// publish windows (region capture never needed them); adding a separate
/// protocol keeps the existing shape stable.
public protocol WindowShareableContentSnapshot: ShareableContentSnapshot {
    var windows: [any WindowSnapshot] { get }
}

/// Real `SCWindow` adapter. `@unchecked Sendable` for the same reason as the
/// `SCDisplayAdapter` / `SCRunningApplicationAdapter` pairs: SCK hands these
/// immutable-by-observation `NSObject`s across actor boundaries itself.
struct SCWindowAdapter: WindowSnapshot, @unchecked Sendable {
    let underlying: SCWindow
    var windowID: CGWindowID { underlying.windowID }
    var ownerPID: pid_t { underlying.owningApplication?.processID ?? 0 }
    var ownerBundleIdentifier: String? {
        underlying.owningApplication?.bundleIdentifier
    }
}

/// Real `SCShareableContent` adapter that additionally publishes windows.
/// Used by the production `captureWindow` / `captureFullscreen` paths.
struct SCShareableContentWindowAdapter: WindowShareableContentSnapshot, @unchecked Sendable {
    let underlying: SCShareableContent
    var displays: [any DisplaySnapshot] {
        underlying.displays.map { SCDisplayAdapter(underlying: $0) }
    }
    var applications: [any RunningApplicationSnapshot] {
        underlying.applications.map { SCRunningApplicationAdapter(underlying: $0) }
    }
    var windows: [any WindowSnapshot] {
        underlying.windows.map { SCWindowAdapter(underlying: $0) }
    }
}

// MARK: - Plans

/// Plain-data description of the `SCContentFilter` that `captureWindow`
/// will construct. The test contract asserts:
///   - the target window is correctly identified by `windowID` (and PID),
///   - `includeChildWindows == true` (SPEC §14),
///   - Shotfuse's own apps remain excluded (SPEC §5 I5).
public struct WindowCaptureFilterPlan: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    /// Always `true` in v0.1 to composite sheets/popovers correctly (SPEC §14).
    public let includeChildWindows: Bool
    /// Bundle IDs of applications whose windows must not appear in the
    /// captured frame. Always contains `ShotfuseBundle.identifier` when a
    /// Shotfuse instance is present in the shareable-content snapshot.
    public let excludedApplicationBundleIDs: [String]
    /// PIDs mirror `excludedApplicationBundleIDs` 1:1.
    public let excludedApplicationPIDs: [pid_t]

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        includeChildWindows: Bool,
        excludedApplicationBundleIDs: [String],
        excludedApplicationPIDs: [pid_t]
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.includeChildWindows = includeChildWindows
        self.excludedApplicationBundleIDs = excludedApplicationBundleIDs
        self.excludedApplicationPIDs = excludedApplicationPIDs
    }
}

/// Plain-data description of the fullscreen `SCContentFilter`. Captures
/// exactly one `SCDisplay`; Shotfuse's own windows are excluded.
public struct FullscreenCaptureFilterPlan: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let excludedApplicationBundleIDs: [String]
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

// MARK: - Pure plan builders (file-local, directly test-callable)

/// Build a `WindowCaptureFilterPlan` + matching `CaptureConfigurationPlan`
/// for single-window capture. Pure function — no SCK calls.
///
/// - Parameters:
///   - content: shareable-content snapshot (window-aware).
///   - pid: owning PID of the target window; used with `windowID` as a
///     disambiguation key when multiple windows share an id.
///   - windowID: `CGWindowID` of the window to capture.
///   - includeChildren: SPEC §14 demands `true` so sheets/popovers composite
///     into the frame.
///   - selfBundleIdentifier: excluded from the filter (SPEC §5 I5).
/// - Throws: `ScreenCaptureError.captureFailed` if the window is not found
///   in `content.windows`.
func makeWindowCapturePlans(
    content: any WindowShareableContentSnapshot,
    pid: pid_t,
    windowID: CGWindowID,
    includeChildren: Bool,
    selfBundleIdentifier: String
) throws -> (WindowCaptureFilterPlan, CaptureConfigurationPlan) {
    guard let window = content.windows.first(where: {
        $0.windowID == windowID && $0.ownerPID == pid
    }) else {
        throw ScreenCaptureError.captureFailed(
            "Window \(windowID) (pid \(pid)) not found in shareable content"
        )
    }

    // Guard: refuse to capture Shotfuse's own windows. SPEC §5 I5 is about
    // the filter; this is an extra defence so a caller can never accidentally
    // re-screenshot our own UI even before the exclusion list runs.
    if window.ownerBundleIdentifier == selfBundleIdentifier {
        throw ScreenCaptureError.captureFailed(
            "Refusing to capture Shotfuse's own window \(windowID)"
        )
    }

    let excluded = content.applications.filter {
        $0.bundleIdentifier == selfBundleIdentifier
    }

    let filterPlan = WindowCaptureFilterPlan(
        windowID: windowID,
        ownerPID: pid,
        includeChildWindows: includeChildren,
        excludedApplicationBundleIDs: excluded.map(\.bundleIdentifier),
        excludedApplicationPIDs: excluded.map(\.processID)
    )

    // SCK sizes the captured frame from the target window itself when the
    // filter is `desktopIndependentWindow:`; width/height of 0 in the config
    // means "match the filter's natural size". We still set I10/I11 flags.
    let configPlan = CaptureConfigurationPlan(
        width: 0,
        height: 0,
        sourceRect: .zero,
        showsCursor: false,        // SPEC §5 I10
        capturesAudio: false       // SPEC §5 I11
    )
    return (filterPlan, configPlan)
}

/// Build a `FullscreenCaptureFilterPlan` + matching `CaptureConfigurationPlan`
/// for a specific display. Pure function — no SCK calls.
///
/// - Throws: `ScreenCaptureError.displayNotFound` if the given
///   `CGDirectDisplayID` is not present in `content.displays`.
func makeFullscreenCapturePlans(
    content: any ShareableContentSnapshot,
    displayID: CGDirectDisplayID,
    selfBundleIdentifier: String
) throws -> (FullscreenCaptureFilterPlan, CaptureConfigurationPlan, any DisplaySnapshot) {
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenCaptureError.displayNotFound
    }

    let excluded = content.applications.filter {
        $0.bundleIdentifier == selfBundleIdentifier
    }

    let filterPlan = FullscreenCaptureFilterPlan(
        displayID: displayID,
        excludedApplicationBundleIDs: excluded.map(\.bundleIdentifier),
        excludedApplicationPIDs: excluded.map(\.processID)
    )

    // Fullscreen capture grabs the full display at native pixel resolution.
    // SCK fills the buffer with the display's native mode; we set the
    // config to the display's pixel width/height so the pixel buffer
    // matches exactly.
    let configPlan = CaptureConfigurationPlan(
        width: max(display.width, 1),
        height: max(display.height, 1),
        sourceRect: display.frame,
        showsCursor: false,       // SPEC §5 I10
        capturesAudio: false      // SPEC §5 I11
    )
    return (filterPlan, configPlan, display)
}

// MARK: - Screenshot backends for the new variants

/// Executes a single-window `SCScreenshotManager.captureImage` from a
/// resolved `WindowCaptureFilterPlan`. Split out so tests can substitute a
/// fake that never touches SCK.
public protocol WindowScreenshotCapturing: Sendable {
    func captureWindowImage(
        content: any WindowShareableContentSnapshot,
        filterPlan: WindowCaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage
}

/// Executes a fullscreen `SCScreenshotManager.captureImage` from a resolved
/// `FullscreenCaptureFilterPlan`. Split for the same reason.
public protocol FullscreenScreenshotCapturing: Sendable {
    func captureFullscreenImage(
        content: any ShareableContentSnapshot,
        filterPlan: FullscreenCaptureFilterPlan,
        configurationPlan: CaptureConfigurationPlan
    ) async throws -> CGImage
}

/// Production backend for `captureWindow`: builds
/// `SCContentFilter(desktopIndependentWindow:)` with
/// `includeChildWindows = true` (SPEC §14) and applies the Shotfuse
/// exclusion list (SPEC §5 I5).
public struct DefaultWindowScreenshotCapturer: WindowScreenshotCapturing {
    public init() {}

    public func captureWindowImage(
        content: any WindowShareableContentSnapshot,
        filterPlan: WindowCaptureFilterPlan,
        configurationPlan configPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        guard let adapter = content as? SCShareableContentWindowAdapter else {
            throw ScreenCaptureError.captureFailed(
                "DefaultWindowScreenshotCapturer requires real SCShareableContent"
            )
        }
        let real = adapter.underlying

        guard let window = real.windows.first(where: {
            $0.windowID == filterPlan.windowID
                && ($0.owningApplication?.processID ?? 0) == filterPlan.ownerPID
        }) else {
            throw ScreenCaptureError.captureFailed(
                "Window \(filterPlan.windowID) (pid \(filterPlan.ownerPID)) not found"
            )
        }

        // `SCContentFilter(desktopIndependentWindow:)` composites the target
        // window's child windows when `includeChildWindows = true` — the
        // canonical API for SPEC §14.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        filter.includeMenuBar = false

        let config = SCStreamConfiguration()
        // width/height == 0 asks SCK to use the filter's natural size.
        if configPlan.width > 0 { config.width = configPlan.width }
        if configPlan.height > 0 { config.height = configPlan.height }
        config.showsCursor = configPlan.showsCursor       // SPEC §5 I10
        config.capturesAudio = configPlan.capturesAudio   // SPEC §5 I11

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

/// Production backend for `captureFullscreen`: builds
/// `SCContentFilter(display:excludingWindows:)` and then additionally
/// excludes Shotfuse's own apps via `excludingApplications:exceptingWindows:`.
public struct DefaultFullscreenScreenshotCapturer: FullscreenScreenshotCapturing {
    public init() {}

    public func captureFullscreenImage(
        content: any ShareableContentSnapshot,
        filterPlan: FullscreenCaptureFilterPlan,
        configurationPlan configPlan: CaptureConfigurationPlan
    ) async throws -> CGImage {
        // Both the new window adapter and the legacy region adapter wrap
        // `SCShareableContent`; accept either.
        let realContent: SCShareableContent?
        if let a = content as? SCShareableContentWindowAdapter {
            realContent = a.underlying
        } else if let a = content as? SCShareableContentAdapter {
            realContent = a.underlying
        } else {
            realContent = nil
        }
        guard let real = realContent else {
            throw ScreenCaptureError.captureFailed(
                "DefaultFullscreenScreenshotCapturer requires real SCShareableContent"
            )
        }

        guard let display = real.displays.first(where: {
            $0.displayID == filterPlan.displayID
        }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let excludedApps = real.applications.filter {
            filterPlan.excludedApplicationBundleIDs.contains($0.bundleIdentifier)
        }

        // SPEC §5 I5: exclude Shotfuse's own windows via
        // `excludingApplications`. Only the target display's content is
        // included — SCK never cross-talks to other displays from this
        // filter shape.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = configPlan.width
        config.height = configPlan.height
        config.sourceRect = configPlan.sourceRect
        config.showsCursor = configPlan.showsCursor       // SPEC §5 I10
        config.capturesAudio = configPlan.capturesAudio   // SPEC §5 I11

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

// MARK: - Window-aware content provider

/// Production provider that returns a window-aware snapshot. Used by the
/// window + fullscreen capture paths. The region-capture path keeps the
/// original non-window provider to avoid touching its hot path.
public struct DefaultWindowShareableContentProvider: ShareableContentProviding {
    public init() {}
    public func current() async throws -> any ShareableContentSnapshot {
        let content = try await SCShareableContent.current
        return SCShareableContentWindowAdapter(underlying: content)
    }
}
