import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

public enum RedactAndResaveError: Error, Sendable, Equatable {
    case originalMasterMissing
    case originalManifestMissing
    case imageDecodeFailed(String)
    case imageEncodeFailed(String)
    case serializationFailed(String)
    case destinationInvalid
    case ioFailure(String)
}

// MARK: - RedactAndResave

/// Produces a NEW `.shot/` package from an existing one, with the supplied
/// master-pixel-space rectangles Gaussian-blurred on `master.png`.
///
/// Invariant: the ORIGINAL `master.png` is never mutated (SPEC §5 I3). The
/// new package gets a fresh UUIDv7, a `redacted_from` field linking back to
/// the original id, and `sensitivity: ["none"]`.
public struct RedactAndResave {

    /// Gaussian blur radius, in master pixels, applied to every redaction
    /// rectangle. Tuned for "clearly unreadable" rather than "aesthetic."
    public static let defaultBlurRadius: Double = 24.0

    public init() {}

    /// Creates a redacted copy of `sourcePackage` at `destinationPackage`.
    ///
    /// - Parameters:
    ///   - sourcePackage: URL of the existing `.shot/` directory.
    ///   - destinationPackage: URL for the new `.shot/` directory. MUST end
    ///     in `.shot` and MUST NOT already exist.
    ///   - rects: Rectangles to blur, in master-pixel space (same origin as
    ///     `CapturedFrame.pixelBounds`; top-left origin, y grows down).
    ///   - blurRadius: Gaussian blur radius in master pixels.
    ///   - now: Clock injection for deterministic tests.
    public func redact(
        sourcePackage: URL,
        to destinationPackage: URL,
        rects: [CGRect],
        blurRadius: Double = RedactAndResave.defaultBlurRadius,
        now: Date = Date()
    ) throws {
        guard destinationPackage.pathExtension == "shot" else {
            throw RedactAndResaveError.destinationInvalid
        }

        let fm = FileManager.default
        let srcManifestURL = sourcePackage.appendingPathComponent("manifest.json")
        let srcMasterURL = sourcePackage.appendingPathComponent("master.png")

        guard fm.fileExists(atPath: srcManifestURL.path) else {
            throw RedactAndResaveError.originalManifestMissing
        }
        guard fm.fileExists(atPath: srcMasterURL.path) else {
            throw RedactAndResaveError.originalMasterMissing
        }

        // ─────────────────────────────────────────────────────────────────
        // (1) Load + parse the original manifest as a generic dictionary
        //     (forward-compat: we only model what we need).
        // ─────────────────────────────────────────────────────────────────
        let srcManifestData: Data
        do {
            srcManifestData = try Data(contentsOf: srcManifestURL)
        } catch {
            throw RedactAndResaveError.ioFailure("read src manifest: \(error.localizedDescription)")
        }

        guard var srcManifest = (try? JSONSerialization.jsonObject(with: srcManifestData))
                as? [String: Any] else {
            throw RedactAndResaveError.serializationFailed("src manifest not a JSON object")
        }

        guard let originalID = srcManifest["id"] as? String else {
            throw RedactAndResaveError.serializationFailed("src manifest has no id")
        }

        // ─────────────────────────────────────────────────────────────────
        // (2) Load master.png as a CGImage.
        // ─────────────────────────────────────────────────────────────────
        guard let srcImage = Self.loadPNG(at: srcMasterURL) else {
            throw RedactAndResaveError.imageDecodeFailed("decode master.png")
        }

        // ─────────────────────────────────────────────────────────────────
        // (3) Produce the redacted CGImage by Gaussian-blurring each rect.
        //     Rects in master-pixel space use a top-left origin; CoreImage
        //     uses bottom-left. We flip each rect into CoreImage space.
        // ─────────────────────────────────────────────────────────────────
        let redactedImage: CGImage
        do {
            redactedImage = try Self.applyBlurs(
                to: srcImage,
                rects: rects,
                blurRadius: blurRadius
            )
        } catch let err as RedactAndResaveError {
            throw err
        } catch {
            throw RedactAndResaveError.imageEncodeFailed("blur: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────
        // (4) Build the new manifest: new UUIDv7, `redacted_from` link,
        //     `sensitivity: ["none"]`, same display / master metadata.
        //     We start from the source manifest and override the fields
        //     that MUST change so optional/unknown keys are preserved.
        // ─────────────────────────────────────────────────────────────────
        srcManifest["id"] = UUIDv7.generate(now: now)
        srcManifest["created_at"] = ISO8601UTC.string(from: now)
        srcManifest["redacted_from"] = originalID
        srcManifest["sensitivity"] = [SensitivityTag.none.rawValue]

        let newManifestData: Data
        do {
            newManifestData = try JSONSerialization.data(
                withJSONObject: srcManifest,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw RedactAndResaveError.serializationFailed("encode new manifest: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────
        // (5) Encode redacted master.png bytes. Re-use `encodePNG` from the
        //     Capture module (same module — internal visibility suffices).
        // ─────────────────────────────────────────────────────────────────
        let newMasterPNG: Data
        do {
            newMasterPNG = try encodePNG(redactedImage)
        } catch {
            throw RedactAndResaveError.imageEncodeFailed(String(describing: error))
        }

        // ─────────────────────────────────────────────────────────────────
        // (6) Copy side-car files (thumb.jpg, context.json) as-is so the
        //     new package is a complete `.shot`. We deliberately skip
        //     `manifest.json` (just rewrote) and `master.png` (just
        //     re-encoded). If a side-car is missing, we simply don't ship
        //     it in the new package — we never fabricate metadata.
        // ─────────────────────────────────────────────────────────────────
        var extraFiles: [String: Data] = [:]
        for sideCar in ["thumb.jpg", "context.json"] {
            let srcURL = sourcePackage.appendingPathComponent(sideCar)
            if let data = try? Data(contentsOf: srcURL) {
                extraFiles[sideCar] = data
            }
        }
        extraFiles["master.png"] = newMasterPNG

        // ─────────────────────────────────────────────────────────────────
        // (7) Atomic write via `ShotPackageWriter` — same fsync-before-
        //     rename discipline as first-capture (SPEC §5 I12).
        // ─────────────────────────────────────────────────────────────────
        var writer = ShotPackageWriter()
        do {
            try writer.write(
                to: destinationPackage,
                manifest: newManifestData,
                files: extraFiles
            )
        } catch let err as ShotPackageWriterError {
            // Normalize writer errors to our own error domain so callers
            // don't need to import two error types.
            switch err {
            case .invalidFinalURL:     throw RedactAndResaveError.destinationInvalid
            case .destinationExists:   throw RedactAndResaveError.ioFailure("destination exists")
            case .ioFailure(let msg):  throw RedactAndResaveError.ioFailure(msg)
            }
        }
    }

    // MARK: - Helpers

    /// Reads a PNG from disk into a `CGImage`. Returns `nil` on decode failure.
    private static func loadPNG(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Applies a Gaussian blur to each master-pixel-space rectangle in `rects`.
    ///
    /// Uses CoreImage's `CIGaussianBlur` for each crop, composites the
    /// blurred crop back over the source in CI space, then rasterizes to
    /// `CGImage` via a `CIContext`. Rects outside the image bounds are
    /// intersected with the image rect and skipped if empty.
    private static func applyBlurs(
        to srcImage: CGImage,
        rects: [CGRect],
        blurRadius: Double
    ) throws -> CGImage {
        let ctx = CIContext(options: nil)
        let ciSource = CIImage(cgImage: srcImage)
        let imgW = CGFloat(srcImage.width)
        let imgH = CGFloat(srcImage.height)
        let imgRect = CGRect(x: 0, y: 0, width: imgW, height: imgH)

        var composited: CIImage = ciSource

        for rect in rects {
            // Convert master-pixel (top-left origin) → CoreImage (bottom-left).
            let ciRect = CGRect(
                x: rect.origin.x,
                y: imgH - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            ).intersection(imgRect)
            guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else {
                continue
            }

            // Crop the source to the rect, blur the crop, crop back to rect
            // (Gaussian blur expands the extent by its radius; we crop to
            // prevent halos bleeding outside the rect). Then composite over
            // the running result.
            let cropped = ciSource.cropped(to: ciRect)
            guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
                throw RedactAndResaveError.imageEncodeFailed("CIGaussianBlur unavailable")
            }
            blurFilter.setValue(cropped.clampedToExtent(), forKey: kCIInputImageKey)
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            guard let blurredFull = blurFilter.outputImage else {
                throw RedactAndResaveError.imageEncodeFailed("blur produced nil output")
            }
            let blurred = blurredFull.cropped(to: ciRect)
            composited = blurred.composited(over: composited)
        }

        guard let cg = ctx.createCGImage(composited, from: imgRect) else {
            throw RedactAndResaveError.imageEncodeFailed("rasterize redacted image")
        }
        return cg
    }
}
