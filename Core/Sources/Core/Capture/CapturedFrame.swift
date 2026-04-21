import CoreGraphics
import Foundation

/// Output of `ScreenCaptureKit` single-frame capture (Wave 1 / P1.2) and input
/// to the capture-pipeline finalization stage (P1.3).
///
/// `pixelBounds` is in **master-pixel space** (SPEC §5 I6; §6.3 OCR bboxes also
/// live in this space). `image` carries the raw pixels that will be written as
/// `master.png` inside the `.shot` package.
///
/// `CGImage` is not `Sendable` in the standard library; we mark this type as
/// `@unchecked Sendable` because ownership is transferred: the producer
/// releases its reference as soon as it yields a `CapturedFrame`, and the
/// consumer takes it through the capture pipeline without aliasing.
public struct CapturedFrame: @unchecked Sendable {
    public let image: CGImage
    public let pixelBounds: CGRect
    public let display: DisplayMetadata
    public let capturedAt: Date

    public init(
        image: CGImage,
        pixelBounds: CGRect,
        display: DisplayMetadata,
        capturedAt: Date
    ) {
        self.image = image
        self.pixelBounds = pixelBounds
        self.display = display
        self.capturedAt = capturedAt
    }
}
