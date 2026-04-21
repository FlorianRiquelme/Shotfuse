import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - SENSITIVE_BUNDLES (SPEC §13.3)

/// Bundle-ID pattern match for SENSITIVE_BUNDLES gating.
///
/// Patterns come in two flavors per SPEC §13.3:
///   * `.exact("com.apple.keychainaccess")` — full string match.
///   * `.prefix("com.1password.")`         — any bundle ID starting with this
///     prefix (the trailing `.` is included in the stored prefix so that
///     `com.1passwordify` does NOT match).
enum SensitiveBundlePattern: Sendable, Equatable {
    case exact(String)
    case prefix(String)

    func matches(_ bundleID: String) -> Bool {
        switch self {
        case .exact(let s):  return bundleID == s
        case .prefix(let p): return bundleID.hasPrefix(p)
        }
    }
}

/// Bundles whose frontmost activity suppresses capture (SPEC §13.3).
///
/// Each `com.*.*` entry is encoded as a prefix pattern. Note that
/// `com.agilebits.onepassword*` in the spec is a GLOB (no intervening dot), so
/// it matches `com.agilebits.onepassword7`, `com.agilebits.onepassword-ci`,
/// etc. — encoded here as `.prefix("com.agilebits.onepassword")`.
public let SENSITIVE_BUNDLES: [String] = [
    "com.1password.*",
    "com.agilebits.onepassword*",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
    "com.lastpass.*",
    "com.bitwarden.*",
]

/// Compiled form of `SENSITIVE_BUNDLES` used at matching time.
let SENSITIVE_BUNDLE_PATTERNS: [SensitiveBundlePattern] = [
    .prefix("com.1password."),
    .prefix("com.agilebits.onepassword"),
    .exact("com.apple.keychainaccess"),
    .exact("com.apple.Passwords"),
    .prefix("com.lastpass."),
    .prefix("com.bitwarden."),
]

/// Returns `true` iff `bundleID` matches any SPEC §13.3 sensitive bundle.
public func isSensitiveBundle(_ bundleID: String) -> Bool {
    SENSITIVE_BUNDLE_PATTERNS.contains { $0.matches(bundleID) }
}

// MARK: - Errors

public enum CaptureFinalizationError: Error, Equatable, Sendable {
    /// Suppressed because the frontmost app is in SENSITIVE_BUNDLES. No `.shot`
    /// or `.shot.tmp` was written.
    case suppressedBySensitiveBundle(bundleID: String)
    /// CoreGraphics/ImageIO encoding of `master.png` or `thumb.jpg` failed.
    case imageEncodingFailed(String)
    /// JSON encoding of `manifest.json` or `context.json` failed.
    case serializationFailed(String)
}

// MARK: - Manifest (SPEC §6.1)

/// `manifest.json` v1 — SPEC §6.1.
public struct Manifest: Codable, Equatable, Sendable {
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

    public let spec_version: Int
    public let id: String
    public let created_at: String
    public let expires_at: String?
    public let mode: String
    public let kind: String
    public let master: Master
    public let display: DisplayMetadata
    public let tags: [String]?
    public let pinned: Bool
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
        self.sensitivity = sensitivity
    }
}

// MARK: - Context payload (SPEC §6.2)

/// `context.json` v1 — SPEC §6.2. Flattened keys (`frontmost.bundle_id`) are
/// emitted as dotted fields under a nested `frontmost` object for JSON shape;
/// the written JSON uses the nested shape described in SPEC §6.2.
public struct CaptureContextPayload: Codable, Equatable, Sendable {
    public struct Frontmost: Codable, Equatable, Sendable {
        public let bundle_id: String
        public let window_title: String?
        public let file_url: String?
        public let git_root: String?
        public let browser_url: String?
    }

    public let frontmost: Frontmost
    public let clipboard: String?
    public let clipboard_truncated: Bool?
    public let ax_available: Bool
    public let captured_at: String
}

// MARK: - UUIDv7

/// Tiny RFC 9562 UUIDv7 generator. Format:
///
///     00112233-4455-7rrr-Vrrr-rrrrrrrrrrrr
///     └──── unix ms ───┘ ^   ^
///                     ver  variant (0b10xx)
///
/// Bytes 0..5  = 48-bit unix-ms timestamp, big-endian.
/// Byte  6     = 0x70 | (rand & 0x0F)  ← version nibble fixed to 7.
/// Byte  8     = 0x80 | (rand & 0x3F)  ← variant top bits fixed to 0b10.
/// All other bytes are cryptographic random.
public enum UUIDv7 {
    /// Generates a UUIDv7 string in canonical 8-4-4-4-12 hex-dash form.
    public static func generate(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)

        // Fill 10..15 with random first; we'll overwrite the first 9 bytes
        // with timestamp + version/variant.
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }

        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000.0))
        bytes[0] = UInt8((ms >> 40) & 0xFF)
        bytes[1] = UInt8((ms >> 32) & 0xFF)
        bytes[2] = UInt8((ms >> 24) & 0xFF)
        bytes[3] = UInt8((ms >> 16) & 0xFF)
        bytes[4] = UInt8((ms >> 8) & 0xFF)
        bytes[5] = UInt8(ms & 0xFF)

        // Version 7 in the high nibble of byte 6.
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        // Variant 0b10 in the high two bits of byte 8.
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return format(bytes)
    }

    private static func format(_ b: [UInt8]) -> String {
        func hex(_ x: UInt8) -> String {
            let s = String(x, radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        let h = b.map(hex)
        return
            h[0] + h[1] + h[2] + h[3] + "-" +
            h[4] + h[5] + "-" +
            h[6] + h[7] + "-" +
            h[8] + h[9] + "-" +
            h[10] + h[11] + h[12] + h[13] + h[14] + h[15]
    }

    /// Validates that `s` is a UUIDv7 by shape and version nibble.
    public static func isValid(_ s: String) -> Bool {
        // 36 chars: 8-4-4-4-12 with dashes at 8, 13, 18, 23.
        guard s.count == 36 else { return false }
        let chars = Array(s)
        let dashIndices = [8, 13, 18, 23]
        for i in dashIndices {
            if chars[i] != "-" { return false }
        }
        // Version nibble is at index 14 (first char of third group).
        if chars[14] != "7" { return false }
        // Variant: first char of fourth group (index 19) must be 8, 9, a, or b.
        let variant = chars[19]
        if !["8", "9", "a", "b", "A", "B"].contains(variant) { return false }
        // Rest must be hex.
        for (i, c) in chars.enumerated() {
            if dashIndices.contains(i) { continue }
            if !c.isHexDigit { return false }
        }
        return true
    }
}

// MARK: - Image encoding helpers

/// Encodes a `CGImage` to PNG bytes.
func encodePNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CaptureFinalizationError.imageEncodingFailed("create PNG destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw CaptureFinalizationError.imageEncodingFailed("finalize PNG")
    }
    return data as Data
}

/// Encodes a `CGImage` to a JPEG thumbnail whose longest side is exactly
/// `maxDimension` pixels (or smaller if the source is already smaller).
func encodeJPEGThumbnail(_ image: CGImage, maxDimension: Int, quality: Double = 0.85) throws -> Data {
    let srcW = image.width
    let srcH = image.height
    let maxSide = max(srcW, srcH)

    // Choose target dimensions preserving aspect ratio.
    let scale: Double
    if maxSide <= maxDimension {
        scale = 1.0
    } else {
        scale = Double(maxDimension) / Double(maxSide)
    }
    let tw = max(1, Int((Double(srcW) * scale).rounded()))
    let th = max(1, Int((Double(srcH) * scale).rounded()))

    // Downscale via CGContext with sRGB color space.
    guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
        throw CaptureFinalizationError.imageEncodingFailed("no color space for thumbnail")
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
        throw CaptureFinalizationError.imageEncodingFailed("create thumbnail CGContext")
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
    guard let scaled = ctx.makeImage() else {
        throw CaptureFinalizationError.imageEncodingFailed("make scaled CGImage")
    }

    // Encode to JPEG.
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw CaptureFinalizationError.imageEncodingFailed("create JPEG destination")
    }
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw CaptureFinalizationError.imageEncodingFailed("finalize JPEG")
    }
    return data as Data
}

// MARK: - Clipboard helpers

/// Truncates `s` to at most `maxBytes` UTF-8 bytes without splitting a grapheme
/// cluster. Returns `(truncatedString, didTruncate)`.
func truncateClipboard(_ s: String, maxBytes: Int) -> (String, Bool) {
    let fullBytes = s.utf8.count
    if fullBytes <= maxBytes { return (s, false) }

    // Walk grapheme clusters, accumulating UTF-8 byte cost, stopping at the
    // last cluster that still fits in maxBytes.
    var accepted = ""
    var bytes = 0
    for cluster in s {
        let clusterBytes = String(cluster).utf8.count
        if bytes + clusterBytes > maxBytes { break }
        accepted.append(cluster)
        bytes += clusterBytes
    }
    return (accepted, true)
}

// MARK: - ISO-8601 UTC

/// ISO-8601 UTC serializer (`YYYY-MM-DDTHH:MM:SSZ`).
///
/// Implemented with `Date.ISO8601FormatStyle` — a value-typed, `Sendable`
/// format style — so it side-steps the non-`Sendable` `ISO8601DateFormatter`
/// class and plays well with Swift 6 strict concurrency. Seconds precision,
/// UTC (`Z`), no fractional seconds — matches SPEC §6.1 / §6.2 examples.
enum ISO8601UTC {
    static func string(from date: Date) -> String {
        let style = Date.ISO8601FormatStyle(
            timeZone: TimeZone(identifier: "UTC")!
        )
        return style.format(date)
    }

    static func date(from string: String) -> Date? {
        let style = Date.ISO8601FormatStyle(
            timeZone: TimeZone(identifier: "UTC")!
        )
        return try? style.parse(string)
    }
}

// MARK: - CaptureFinalization

/// Converts a `CapturedFrame` + runtime context into a fully-written `.shot/`
/// package on disk. Wires P1.2 output → `ShotPackageWriter` (SPEC §5 I12).
public struct CaptureFinalization {

    /// Pipeline context gathered synchronously by the capture engine at the
    /// `capturing → finalizing` transition (Spike A — `hq-91t` — verified
    /// p95 ≤ 0.5ms for AX snapshot). The caller is responsible for reading
    /// the pasteboard, AX tree, and TCC status before invoking `finalize`.
    public struct Context: Sendable {
        public let frontmostBundleID: String
        public let frontmostWindowTitle: String?
        public let frontmostFileURL: String?
        public let frontmostGitRoot: String?
        public let frontmostBrowserURL: String?
        /// Already-read pasteboard string (nil if pasteboard had no string).
        /// This is the raw value; SENSITIVE_BUNDLES gating + truncation happen
        /// inside `finalize`.
        public let clipboard: String?
        public let clipboardLastModifiedAt: Date
        public let clipboardLastModifierBundleID: String?
        public let axAvailable: Bool

        public init(
            frontmostBundleID: String,
            frontmostWindowTitle: String? = nil,
            frontmostFileURL: String? = nil,
            frontmostGitRoot: String? = nil,
            frontmostBrowserURL: String? = nil,
            clipboard: String? = nil,
            clipboardLastModifiedAt: Date = .distantPast,
            clipboardLastModifierBundleID: String? = nil,
            axAvailable: Bool
        ) {
            self.frontmostBundleID = frontmostBundleID
            self.frontmostWindowTitle = frontmostWindowTitle
            self.frontmostFileURL = frontmostFileURL
            self.frontmostGitRoot = frontmostGitRoot
            self.frontmostBrowserURL = frontmostBrowserURL
            self.clipboard = clipboard
            self.clipboardLastModifiedAt = clipboardLastModifiedAt
            self.clipboardLastModifierBundleID = clipboardLastModifierBundleID
            self.axAvailable = axAvailable
        }
    }

    /// Maximum UTF-8 byte length for `context.clipboard` per SPEC §6.2.
    public static let clipboardMaxBytes = 1024

    /// Thumbnail max dimension per SPEC §6 / §6 tree listing.
    public static let thumbnailMaxDimension = 256

    /// Default `Fuse` expiry window (24h) per SPEC §4 / §6.1.
    public static let defaultFuseInterval: TimeInterval = 24 * 60 * 60

    /// Writes `finalURL` as a complete `.shot/` package.
    ///
    /// - Parameters:
    ///   - frame: Captured pixels + display metadata (P1.2 output).
    ///   - context: Runtime pipeline context (see `Context`).
    ///   - finalURL: Destination path; MUST end in `.shot`.
    ///   - writer: `ShotPackageWriter` — passed `inout` because the writer
    ///     flips a `didFsyncManifest` test-hook flag.
    ///   - now: Clock injection for deterministic tests.
    /// - Throws:
    ///   - `CaptureFinalizationError.suppressedBySensitiveBundle` if
    ///     `context.frontmostBundleID ∈ SENSITIVE_BUNDLES`; nothing is written.
    ///   - `CaptureFinalizationError.imageEncodingFailed` / `.serializationFailed`
    ///     on encoding failure.
    ///   - `ShotPackageWriterError` on I/O failure.
    public static func finalize(
        frame: CapturedFrame,
        context: Context,
        to finalURL: URL,
        writer: inout ShotPackageWriter,
        now: Date = Date()
    ) throws {
        // ─────────────────────────────────────────────────────────────────
        // (1) SENSITIVE_BUNDLES gate — BEFORE any disk activity (SPEC §13.3).
        //     No .shot.tmp/ or .shot/ appears on disk when suppressed.
        // ─────────────────────────────────────────────────────────────────
        if isSensitiveBundle(context.frontmostBundleID) {
            throw CaptureFinalizationError.suppressedBySensitiveBundle(
                bundleID: context.frontmostBundleID
            )
        }

        // ─────────────────────────────────────────────────────────────────
        // (2) Build manifest.
        // ─────────────────────────────────────────────────────────────────
        let id = UUIDv7.generate(now: now)
        let createdAt = ISO8601UTC.string(from: now)
        let expiresAt = ISO8601UTC.string(from: now.addingTimeInterval(defaultFuseInterval))

        let pixelWidth = Int(frame.pixelBounds.width.rounded())
        let pixelHeight = Int(frame.pixelBounds.height.rounded())
        let dpi = 72.0 * frame.display.nativeScale

        let manifest = Manifest(
            spec_version: 1,
            id: id,
            created_at: createdAt,
            expires_at: expiresAt,
            mode: "verbal",
            kind: "image",
            master: Manifest.Master(
                path: "master.png",
                width: pixelWidth,
                height: pixelHeight,
                dpi: dpi
            ),
            display: frame.display,
            tags: nil,
            pinned: false,
            sensitivity: nil
        )

        // ─────────────────────────────────────────────────────────────────
        // (3) Build context.json with clipboard gate (SPEC §6.2 / §13.3).
        // ─────────────────────────────────────────────────────────────────
        let (clipboardValue, clipboardTruncated) = resolveClipboard(context: context, now: now)

        let ctxPayload = CaptureContextPayload(
            frontmost: CaptureContextPayload.Frontmost(
                bundle_id: context.frontmostBundleID,
                window_title: context.frontmostWindowTitle,
                file_url: context.frontmostFileURL,
                git_root: context.frontmostGitRoot,
                browser_url: context.frontmostBrowserURL
            ),
            clipboard: clipboardValue,
            clipboard_truncated: clipboardTruncated ? true : nil,
            ax_available: context.axAvailable,
            captured_at: createdAt
        )

        // ─────────────────────────────────────────────────────────────────
        // (4) Encode JSON blobs (with stable, readable output).
        // ─────────────────────────────────────────────────────────────────
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let manifestData: Data
        let contextData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw CaptureFinalizationError.serializationFailed("manifest: \(error.localizedDescription)")
        }
        do {
            contextData = try encoder.encode(ctxPayload)
        } catch {
            throw CaptureFinalizationError.serializationFailed("context: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────
        // (5) Encode master.png + thumb.jpg.
        // ─────────────────────────────────────────────────────────────────
        let masterPNG = try encodePNG(frame.image)
        let thumbJPEG = try encodeJPEGThumbnail(
            frame.image,
            maxDimension: thumbnailMaxDimension
        )

        // ─────────────────────────────────────────────────────────────────
        // (6) Hand off to ShotPackageWriter for the atomic write.
        // ─────────────────────────────────────────────────────────────────
        try writer.write(
            to: finalURL,
            manifest: manifestData,
            files: [
                "master.png":   masterPNG,
                "thumb.jpg":    thumbJPEG,
                "context.json": contextData,
            ]
        )
    }

    /// Applies SPEC §6.2 / §13.3 clipboard gating. Returns
    /// `(value, didTruncate)` where `value == nil` means "omit the key".
    static func resolveClipboard(context: Context, now: Date) -> (String?, Bool) {
        // Frontmost check is the outer gate; when it hits, caller already
        // aborted earlier — but be defensive if `resolveClipboard` is called
        // directly in tests.
        if isSensitiveBundle(context.frontmostBundleID) {
            return (nil, false)
        }
        guard let raw = context.clipboard else { return (nil, false) }

        // Last-modifier gate: skip if modifier is sensitive AND the write was
        // recent (< 60s). A stale sensitive write (≥ 60s old) does not
        // suppress capture — matches SPEC §6.2's "≥ 60s ago OR non-sensitive"
        // affirmative gate.
        if let modifier = context.clipboardLastModifierBundleID,
           isSensitiveBundle(modifier) {
            let age = now.timeIntervalSince(context.clipboardLastModifiedAt)
            if age < 60 {
                return (nil, false)
            }
        }

        let (truncated, didTruncate) = truncateClipboard(raw, maxBytes: clipboardMaxBytes)
        return (truncated, didTruncate)
    }
}
