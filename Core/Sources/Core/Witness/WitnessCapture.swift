import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// NOTE: hotkey registration (Cmd+Shift+W) is wired in a later task alongside
// HotkeyRegistry (hq-qpn). This module only owns the capture path + hash.

// MARK: - Errors

public enum WitnessCaptureError: Error, Equatable, Sendable {
    /// PNG encoding of the captured master image failed.
    case imageEncodingFailed(String)
    /// JSON encoding of the witness manifest failed.
    case serializationFailed(String)
    /// The supplied witnesses-root URL could not be created.
    case witnessesRootUnavailable(String)
    /// Hash computation failed (bubbled from `WitnessHash.compute`).
    case hashFailed(String)
}

// MARK: - Witness manifest shape (SPEC §6.1 with `witness` present)
//
// The Core `Manifest` type baked under `Capture/CaptureFinalization.swift` does
// not carry a `witness` field (witness is mutually exclusive with the verbal
// / reference path, and `mode` there is hard-wired to "verbal"). We define a
// sibling type here so the witness path can emit the exact §6.1 shape without
// modifying the finalization module.

/// Witness-mode `manifest.json` (SPEC §6.1, with the §6.1 `witness` field).
///
/// Codable via `JSONEncoder(.sortedKeys)` produces a stable on-disk form. The
/// emitted JSON also feeds `WitnessHash.compute` — the hash strips `witness`
/// before canonicalizing, so emitting the field here is correct and
/// deterministic.
public struct WitnessManifest: Codable, Equatable, Sendable {
    public struct Master: Codable, Equatable, Sendable {
        public let path: String
        public let width: Int
        public let height: Int
        public let dpi: Double

        public init(path: String, width: Int, height: Int, dpi: Double) {
            self.path = path
            self.width = width
            self.height = height
            self.dpi = dpi
        }
    }

    /// Inner `witness` object: `{ hash, algorithm }` per SPEC §6.1.
    public struct WitnessInfo: Codable, Equatable, Sendable {
        public let hash: String
        public let algorithm: String

        public init(hash: String, algorithm: String = "sha256") {
            self.hash = hash
            self.algorithm = algorithm
        }
    }

    public let spec_version: Int
    public let id: String
    public let created_at: String
    public let expires_at: String?
    public let mode: String  // always "witness"
    public let kind: String  // always "image" in v0.1
    public let master: Master
    public let display: DisplayMetadata
    public let tags: [String]?
    public let pinned: Bool
    public let witness: WitnessInfo?
    public let sensitivity: [String]?

    public init(
        spec_version: Int,
        id: String,
        created_at: String,
        expires_at: String?,
        mode: String,
        kind: String,
        master: Master,
        display: DisplayMetadata,
        tags: [String]? = nil,
        pinned: Bool,
        witness: WitnessInfo? = nil,
        sensitivity: [String]? = nil
    ) {
        self.spec_version = spec_version
        self.id = id
        self.created_at = created_at
        self.expires_at = expires_at
        self.mode = mode
        self.kind = kind
        self.master = master
        self.display = display
        self.tags = tags
        self.pinned = pinned
        self.witness = witness
        self.sensitivity = sensitivity
    }
}

// MARK: - Witness capture

/// High-level, testable entry point for the witness-capture path (SPEC §4,
/// §13.6, §5 I3/I4/I12).
///
/// The real hotkey-driven flow will call `WitnessCapture.run(...)` from the
/// `CaptureEngine` state machine. For now this module stands alone so tests
/// can exercise the package-write + hash paths without TCC / hotkey
/// dependencies. Witness captures:
///
/// - Land on disk under the `witnessesRoot` (default `~/.shotfuse/witnesses/`),
///   **never** under the main library root.
/// - Carry `manifest.mode = "witness"` and `manifest.witness.hash` per §13.6.
/// - Are **never** inserted into `LibraryIndex` — this module does not hold a
///   reference to one and does not import the Library subsystem for inserts.
/// - Are **never** routed through `Limbo` — this function returns a `URL`,
///   period. Limbo / router integration lives elsewhere.
public enum WitnessCapture {

    /// Default on-disk home for witness packages.
    public static func defaultWitnessesRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".shotfuse", isDirectory: true)
            .appendingPathComponent("witnesses", isDirectory: true)
    }

    /// Thumbnail longest-side (mirrors `CaptureFinalization.thumbnailMaxDimension`).
    public static let thumbnailMaxDimension = 256

    /// Default `Fuse` interval — witness captures are retained 24h like
    /// verbal/reference captures unless pinned. SPEC §13 leaves the witness
    /// retention knob to the user; we pick parity with the default for
    /// consistency.
    public static let defaultFuseInterval: TimeInterval = 24 * 60 * 60

    /// Input bundle for a witness capture. Separated from the call so tests
    /// can construct a known fixture cleanly.
    public struct Input: Sendable {
        public let frame: CapturedFrame
        /// Witnesses-root override; defaults to `~/.shotfuse/witnesses/`.
        public let witnessesRoot: URL
        /// Fixed clock injection for deterministic tests.
        public let now: Date
        /// Stable UUIDv7 override for deterministic tests (otherwise generated).
        public let idOverride: String?

        public init(
            frame: CapturedFrame,
            witnessesRoot: URL = WitnessCapture.defaultWitnessesRoot(),
            now: Date = Date(),
            idOverride: String? = nil
        ) {
            self.frame = frame
            self.witnessesRoot = witnessesRoot
            self.now = now
            self.idOverride = idOverride
        }
    }

    // MARK: Entry point

    /// Captures → writes a witness `.shot/` package → returns its final URL.
    ///
    /// Intentionally kept narrow: we take a pre-captured `CapturedFrame` (same
    /// shape the real `ScreenCapturer.captureFrame` produces) and handle only
    /// the "bypass Limbo, hash, write to witnesses root" slice. The caller
    /// (future `CaptureEngine` witness branch) is responsible for driving the
    /// SCK capture and handing us the frame.
    public static func captureWitness(
        _ input: Input
    ) async throws -> URL {
        try ensureDirectory(input.witnessesRoot)

        let id = input.idOverride ?? UUIDv7.generate(now: input.now)
        let createdAt = ISO8601UTC.string(from: input.now)
        let expiresAt = ISO8601UTC.string(
            from: input.now.addingTimeInterval(defaultFuseInterval)
        )

        // 1. Encode master.png.
        let masterPNG: Data
        do {
            masterPNG = try encodeWitnessPNG(input.frame.image)
        } catch {
            throw WitnessCaptureError.imageEncodingFailed(
                "master.png: \(error.localizedDescription)"
            )
        }

        // 2. Build the manifest WITHOUT the witness field first — hash input.
        let pixelWidth = Int(input.frame.pixelBounds.width.rounded())
        let pixelHeight = Int(input.frame.pixelBounds.height.rounded())
        let dpi = 72.0 * input.frame.display.nativeScale

        let manifestNoWitness = WitnessManifest(
            spec_version: 1,
            id: id,
            created_at: createdAt,
            expires_at: expiresAt,
            mode: "witness",
            kind: "image",
            master: WitnessManifest.Master(
                path: "master.png",
                width: pixelWidth,
                height: pixelHeight,
                dpi: dpi
            ),
            display: input.frame.display,
            tags: nil,
            pinned: false,
            witness: nil,
            sensitivity: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let manifestNoWitnessData: Data
        do {
            manifestNoWitnessData = try encoder.encode(manifestNoWitness)
        } catch {
            throw WitnessCaptureError.serializationFailed(
                "manifest(pre-hash): \(error.localizedDescription)"
            )
        }

        // 3. Compute the hash using the exact SPEC §13.6 formula.
        let hash: String
        do {
            hash = try WitnessHash.compute(
                masterPNG: masterPNG,
                manifestJSON: manifestNoWitnessData,
                capturedAt: createdAt
            )
        } catch {
            throw WitnessCaptureError.hashFailed(error.localizedDescription)
        }

        // 4. Re-emit the manifest with `witness` populated. The hash formula
        //    explicitly strips `witness` before canonicalizing, so the written
        //    manifest is reproducible: a verifier takes the on-disk manifest,
        //    drops `witness`, canonicalizes, and replays the formula.
        let finalManifest = WitnessManifest(
            spec_version: 1,
            id: id,
            created_at: createdAt,
            expires_at: expiresAt,
            mode: "witness",
            kind: "image",
            master: manifestNoWitness.master,
            display: input.frame.display,
            tags: nil,
            pinned: false,
            witness: WitnessManifest.WitnessInfo(hash: hash, algorithm: "sha256"),
            sensitivity: nil
        )

        let finalManifestData: Data
        do {
            let prettyEncoder = JSONEncoder()
            prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            finalManifestData = try prettyEncoder.encode(finalManifest)
        } catch {
            throw WitnessCaptureError.serializationFailed(
                "manifest(final): \(error.localizedDescription)"
            )
        }

        // 5. Encode thumbnail. We reuse the same encoder shape as the verbal
        //    pipeline for consistency but don't depend on its helper (which
        //    is file-private to Capture/). The duplicate is intentional — the
        //    Witness module is explicitly carved out as read-only of Capture.
        let thumbJPEG: Data
        do {
            thumbJPEG = try encodeWitnessThumbnail(
                input.frame.image,
                maxDimension: thumbnailMaxDimension
            )
        } catch {
            throw WitnessCaptureError.imageEncodingFailed(
                "thumb.jpg: \(error.localizedDescription)"
            )
        }

        // 6. Atomic package write — we reuse the production `ShotPackageWriter`
        //    so the .shot/.shot.tmp/fsync-before-rename guarantees (§5 I12)
        //    hold for witness packages too.
        let packageName = "\(createdAt.replacingOccurrences(of: ":", with: "-"))_witness.shot"
        let finalURL = input.witnessesRoot.appendingPathComponent(packageName)

        var writer = ShotPackageWriter()
        try writer.write(
            to: finalURL,
            manifest: finalManifestData,
            files: [
                "master.png": masterPNG,
                "thumb.jpg":  thumbJPEG,
            ]
        )

        // 7. Explicit non-routing: no LibraryIndex.insert, no Limbo handoff,
        //    no Router prediction. Return the URL and let the caller log.
        return finalURL
    }

    // MARK: - Helpers (local copies; see `.thumbnailMaxDimension` comment above)

    private static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw WitnessCaptureError.witnessesRootUnavailable(
                "\(url.path): \(error.localizedDescription)"
            )
        }
    }

    static func encodeWitnessPNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WitnessCaptureError.imageEncodingFailed(
                "create PNG destination"
            )
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw WitnessCaptureError.imageEncodingFailed("finalize PNG")
        }
        return data as Data
    }

    static func encodeWitnessThumbnail(
        _ image: CGImage,
        maxDimension: Int,
        quality: Double = 0.85
    ) throws -> Data {
        let srcW = image.width
        let srcH = image.height
        let maxSide = max(srcW, srcH)

        let scale: Double
        if maxSide <= maxDimension {
            scale = 1.0
        } else {
            scale = Double(maxDimension) / Double(maxSide)
        }
        let tw = max(1, Int((Double(srcW) * scale).rounded()))
        let th = max(1, Int((Double(srcH) * scale).rounded()))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WitnessCaptureError.imageEncodingFailed(
                "no color space for thumbnail"
            )
        }
        let bitsPerComponent = 8
        let bytesPerRow = tw * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: tw,
            height: th,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WitnessCaptureError.imageEncodingFailed(
                "create thumbnail CGContext"
            )
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else {
            throw WitnessCaptureError.imageEncodingFailed("make scaled CGImage")
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw WitnessCaptureError.imageEncodingFailed(
                "create JPEG destination"
            )
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw WitnessCaptureError.imageEncodingFailed("finalize JPEG")
        }
        return data as Data
    }
}
