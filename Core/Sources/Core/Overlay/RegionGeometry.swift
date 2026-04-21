import CoreGraphics
import Foundation

// Pure geometry helpers for the region-selection overlay (SPEC §5 I6 — canonical
// point space + display metadata; §6.1 `display` schema).
//
// These helpers are AppKit-free so they can be unit-tested without spinning up
// real `NSWindow`s or real `NSScreen`s. The overlay itself lives in
// `RegionSelectionOverlay.swift` and consumes these helpers at runtime.

/// Full display metadata per SPEC §6.1 `manifest.json.display`.
///
/// `CGDirectDisplayID` alone is unstable across reboots and reconnects, so
/// vendor / product / serial are captured alongside the runtime id for robust
/// rematch by downstream phases (library index, re-open workflow).
public struct DisplayMetadata: Sendable, Equatable, Codable {
    /// `CGDirectDisplayID` at capture time. Not stable across reboots.
    public let id: UInt32
    /// Native pixel width of the display's current mode (from `CGDisplayCopyDisplayMode`).
    public let nativeWidth: Int
    /// Native pixel height of the display's current mode.
    public let nativeHeight: Int
    /// `backingScaleFactor` (native-pixels-per-point).
    public let nativeScale: CGFloat
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let serial: UInt32?
    public let localizedName: String
    /// Display's frame in the global canonical point-space coordinate system
    /// (bottom-left origin, as reported by `NSScreen.frame`).
    public let globalFrame: CGRect

    public init(
        id: UInt32,
        nativeWidth: Int,
        nativeHeight: Int,
        nativeScale: CGFloat,
        vendorID: UInt32?,
        productID: UInt32?,
        serial: UInt32?,
        localizedName: String,
        globalFrame: CGRect
    ) {
        self.id = id
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.nativeScale = nativeScale
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.localizedName = localizedName
        self.globalFrame = globalFrame
    }
}

/// Result of a region-selection gesture — what `RegionSelectionOverlay.present()` returns.
///
/// `rect` is in canonical point-space on the *resolved target display* (display-local
/// coordinates, i.e., origin is the display's own origin, not the global origin).
/// Conversion to pixel space or global space is deferred until last-moment render
/// per SPEC §5 I6.
public struct RegionSelection: Sendable, Equatable {
    /// Selection rectangle in display-local canonical point space.
    public let rect: CGRect
    /// Resolved target display (hit-tested against the release point).
    public let display: DisplayMetadata

    public init(rect: CGRect, display: DisplayMetadata) {
        self.rect = rect
        self.display = display
    }
}

/// Stateless geometry calculator shared by the overlay and the unit tests.
///
/// The runtime overlay receives mouse events in window-local coordinates. This
/// helper converts them to display-local canonical point space and resolves
/// multi-display gestures via release-point hit-testing.
public enum RegionGeometry {
    /// Builds a normalized rect from two corner points in the same coordinate
    /// space (guarantees non-negative width/height regardless of drag direction).
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(a.x - b.x)
        let h = abs(a.y - b.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Resolves a release point (in global canonical point space) to the display
    /// whose `globalFrame` contains it. Returns nil if no display matches
    /// (shouldn't happen for real cursor positions but we never force-unwrap).
    public static func display(
        containing globalPoint: CGPoint,
        displays: [DisplayMetadata]
    ) -> DisplayMetadata? {
        for d in displays where d.globalFrame.contains(globalPoint) {
            return d
        }
        return nil
    }

    /// Converts a point from global canonical point space (the `NSScreen` coord
    /// system, shared across all displays) to the given display's local
    /// coord space (origin = display's own bottom-left).
    public static func toDisplayLocal(
        global point: CGPoint,
        display: DisplayMetadata
    ) -> CGPoint {
        CGPoint(
            x: point.x - display.globalFrame.origin.x,
            y: point.y - display.globalFrame.origin.y
        )
    }

    /// Converts a rect from global canonical point space to the given display's
    /// local coord space.
    public static func toDisplayLocal(
        global rect: CGRect,
        display: DisplayMetadata
    ) -> CGRect {
        CGRect(
            origin: toDisplayLocal(global: rect.origin, display: display),
            size: rect.size
        )
    }

    /// Builds a `RegionSelection` from a drag that started at `startGlobal` and
    /// released at `endGlobal`, both expressed in global canonical point space.
    /// The target display is resolved by hit-testing the release point against
    /// `displays`. Returns nil if the release point is outside every display.
    public static func selection(
        startGlobal: CGPoint,
        endGlobal: CGPoint,
        displays: [DisplayMetadata]
    ) -> RegionSelection? {
        guard let target = display(containing: endGlobal, displays: displays) else {
            return nil
        }
        let globalRect = rect(from: startGlobal, to: endGlobal)
        let localRect = toDisplayLocal(global: globalRect, display: target)
        return RegionSelection(rect: localRect, display: target)
    }
}
