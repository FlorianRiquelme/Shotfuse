import CoreGraphics
import Foundation

/// Stable description of a physical display, per SPEC §6.1 `display` field.
///
/// `CGDirectDisplayID` alone is unstable across reboot/reconnect, so we carry
/// vendor/product/serial and native pixel dimensions to enable robust rematch
/// at replay/export time.
public struct DisplayMetadata: Sendable, Codable, Equatable {
    public let id: CGDirectDisplayID
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let nativeScale: Double
    public let vendorID: String?
    public let productID: String?
    public let serial: String?
    public let localizedName: String

    public init(
        id: CGDirectDisplayID,
        nativeWidth: Int,
        nativeHeight: Int,
        nativeScale: Double,
        vendorID: String? = nil,
        productID: String? = nil,
        serial: String? = nil,
        localizedName: String
    ) {
        self.id = id
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.nativeScale = nativeScale
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.localizedName = localizedName
    }
}

/// Output of the region-selection overlay (Wave 1 / P1.1) and input to
/// `ScreenCaptureKit` frame capture (P1.2).
///
/// `rect` is in **canonical point space on the target display** (SPEC §5 I6 —
/// DPI conversion happens at render/export time, never at storage).
public struct RegionSelection: Sendable, Equatable {
    public let rect: CGRect
    public let display: DisplayMetadata

    public init(rect: CGRect, display: DisplayMetadata) {
        self.rect = rect
        self.display = display
    }
}
