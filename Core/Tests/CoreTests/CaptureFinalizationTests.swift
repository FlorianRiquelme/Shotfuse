import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Core

// MARK: - Fixtures

private struct Fixtures {
    static func display(id: CGDirectDisplayID = 1) -> DisplayMetadata {
        DisplayMetadata(
            id: id,
            nativeWidth: 3024,
            nativeHeight: 1964,
            nativeScale: 2.0,
            vendorID: "0x05AC",
            productID: "0xA050",
            serial: nil,
            localizedName: "Built-in Retina Display"
        )
    }

    /// Builds a 100x100 solid-red RGBA CGImage in sRGB space.
    static func redRectImage(width: Int = 100, height: Int = 100) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * bytesPerRow + col * 4
                pixels[offset + 0] = 0xFF // R
                pixels[offset + 1] = 0x30 // G
                pixels[offset + 2] = 0x30 // B
                pixels[offset + 3] = 0xFF // A
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = pixels.withUnsafeMutableBufferPointer { buf -> CGContext in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        return ctx.makeImage()!
    }

    static func frame(
        width: Int = 100,
        height: Int = 100,
        capturedAt: Date = Date()
    ) -> CapturedFrame {
        CapturedFrame(
            image: redRectImage(width: width, height: height),
            pixelBounds: CGRect(x: 0, y: 0, width: width, height: height),
            display: display(),
            capturedAt: capturedAt
        )
    }
}

private func makeTmpDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("capfin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Suite

@Suite("CaptureFinalizationTests")
struct CaptureFinalizationTests {

    // ─────────────────────────────────────────────────────────────────
    // (a) Sensitive bundle abort — SPEC §13.3
    // ─────────────────────────────────────────────────────────────────
    @Test("Sensitive bundle: 1Password frontmost throws suppressedBySensitiveBundle; no .shot or .shot.tmp written")
    func sensitiveBundleAborts() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        let tempURL  = tmp.appendingPathComponent("cap.shot.tmp")

        let frame = Fixtures.frame()
        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.1password.1Password",
            axAvailable: true
        )

        var writer = ShotPackageWriter()
        var thrown: Error?
        do {
            try CaptureFinalization.finalize(frame: frame, context: ctx, to: finalURL, writer: &writer)
            Issue.record("Expected suppressedBySensitiveBundle to throw")
        } catch {
            thrown = error
        }

        // Error shape.
        let fe = thrown as? CaptureFinalizationError
        #expect(fe == .suppressedBySensitiveBundle(bundleID: "com.1password.1Password"))

        // Neither the final package nor the staging dir exists.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: finalURL.path))
        #expect(!fm.fileExists(atPath: tempURL.path))
        #expect(!writer.didFsyncManifest)
    }

    @Test("SENSITIVE_BUNDLES prefix matching covers every SPEC §13.3 family")
    func sensitiveBundlePatternCoverage() {
        // Prefix matches.
        #expect(isSensitiveBundle("com.1password.1Password"))
        #expect(isSensitiveBundle("com.1password.1Password7"))
        #expect(isSensitiveBundle("com.agilebits.onepassword"))
        #expect(isSensitiveBundle("com.agilebits.onepassword7"))
        #expect(isSensitiveBundle("com.lastpass.LastPass"))
        #expect(isSensitiveBundle("com.bitwarden.desktop"))
        // Exact matches.
        #expect(isSensitiveBundle("com.apple.keychainaccess"))
        #expect(isSensitiveBundle("com.apple.Passwords"))
        // Near-misses that MUST NOT match.
        #expect(!isSensitiveBundle("com.apple.Notes"))
        #expect(!isSensitiveBundle("com.apple.passwords"))       // case-sensitive
        #expect(!isSensitiveBundle("com.1passwordify"))          // no dot boundary
        #expect(!isSensitiveBundle("com.apple.Safari"))
    }

    // ─────────────────────────────────────────────────────────────────
    // (b) Clipboard last-modifier is sensitive within 60s → omit key.
    // ─────────────────────────────────────────────────────────────────
    @Test("Clipboard skipped when last-modifier is sensitive within 60s")
    func clipboardSkippedBySensitiveModifier() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        let now = Date()
        // Modifier wrote the clipboard 5s ago (< 60s).
        let recent = now.addingTimeInterval(-5)

        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari", // non-sensitive frontmost
            clipboard: "super secret password",
            clipboardLastModifiedAt: recent,
            clipboardLastModifierBundleID: "com.1password.1Password",
            axAvailable: true
        )

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(),
            context: ctx,
            to: finalURL,
            writer: &writer,
            now: now
        )

        // Load and parse context.json. `clipboard` key absent; `clipboard_truncated` absent or false.
        let contextData = try Data(contentsOf: finalURL.appendingPathComponent("context.json"))
        let json = try JSONSerialization.jsonObject(with: contextData) as! [String: Any]
        #expect(json["clipboard"] == nil)
        if let truncated = json["clipboard_truncated"] as? Bool {
            #expect(truncated == false)
        }
    }

    @Test("Clipboard included when sensitive-modifier write is older than 60s")
    func clipboardIncludedWhenSensitiveWriteIsStale() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        let now = Date()
        // Modifier wrote the clipboard 90s ago (≥ 60s).
        let stale = now.addingTimeInterval(-90)

        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari",
            clipboard: "hello world",
            clipboardLastModifiedAt: stale,
            clipboardLastModifierBundleID: "com.1password.1Password",
            axAvailable: true
        )

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(),
            context: ctx,
            to: finalURL,
            writer: &writer,
            now: now
        )

        let contextData = try Data(contentsOf: finalURL.appendingPathComponent("context.json"))
        let json = try JSONSerialization.jsonObject(with: contextData) as! [String: Any]
        #expect(json["clipboard"] as? String == "hello world")
    }

    @Test("Clipboard truncated: long input → clipboard_truncated = true, bytes ≤ 1024")
    func clipboardTruncation() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        // 2048 ASCII bytes (each byte = 1 UTF-8 byte).
        let huge = String(repeating: "A", count: 2048)

        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari",
            clipboard: huge,
            clipboardLastModifiedAt: Date(),
            clipboardLastModifierBundleID: "com.apple.Safari",
            axAvailable: true
        )

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(),
            context: ctx,
            to: finalURL,
            writer: &writer
        )

        let contextData = try Data(contentsOf: finalURL.appendingPathComponent("context.json"))
        let json = try JSONSerialization.jsonObject(with: contextData) as! [String: Any]
        let clip = json["clipboard"] as? String
        #expect(clip != nil)
        #expect(clip!.utf8.count <= CaptureFinalization.clipboardMaxBytes)
        #expect(json["clipboard_truncated"] as? Bool == true)
    }

    @Test("Truncation is grapheme-aware: no split clusters")
    func clipboardGraphemeAwareTruncation() {
        // A grapheme cluster that's 4 UTF-8 bytes — the family emoji is heavier,
        // but a flag sequence (2 regional-indicator scalars = 8 UTF-8 bytes) is
        // cleanly splittable at a scalar boundary but MUST NOT split at the
        // cluster boundary. Use a string of flags just past the limit.
        // Using 🇩🇪 (8 UTF-8 bytes per cluster).
        let flag = "🇩🇪"
        #expect(flag.utf8.count == 8)
        // 130 flags = 1040 UTF-8 bytes — just over 1024. Expect truncation to
        // stop at the last full cluster boundary below 1024.
        let s = String(repeating: flag, count: 130)
        #expect(s.utf8.count == 1040)
        let (out, didTruncate) = truncateClipboard(s, maxBytes: 1024)
        #expect(didTruncate)
        #expect(out.utf8.count <= 1024)
        // Count must be a whole number of 8-byte clusters.
        #expect(out.utf8.count % 8 == 0)
    }

    // ─────────────────────────────────────────────────────────────────
    // (c) ax_available = false propagates.
    // ─────────────────────────────────────────────────────────────────
    @Test("ax_available = false propagates through to context.json")
    func axAvailableFalsePropagates() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")

        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari",
            axAvailable: false
        )

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(),
            context: ctx,
            to: finalURL,
            writer: &writer
        )

        let contextData = try Data(contentsOf: finalURL.appendingPathComponent("context.json"))
        let json = try JSONSerialization.jsonObject(with: contextData) as! [String: Any]
        #expect(json["ax_available"] as? Bool == false)
    }

    @Test("ax_available = true propagates through to context.json")
    func axAvailableTruePropagates() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")

        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari",
            axAvailable: true
        )

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(),
            context: ctx,
            to: finalURL,
            writer: &writer
        )

        let contextData = try Data(contentsOf: finalURL.appendingPathComponent("context.json"))
        let json = try JSONSerialization.jsonObject(with: contextData) as! [String: Any]
        #expect(json["ax_available"] as? Bool == true)
    }

    // ─────────────────────────────────────────────────────────────────
    // (d) Manifest fields exact — SPEC §6.1
    // ─────────────────────────────────────────────────────────────────
    @Test("Manifest fields exact after successful finalize")
    func manifestFieldsExact() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        let now = Date(timeIntervalSince1970: 1_713_705_192) // 2024-04-21T11:13:12Z (stable)
        let frame = Fixtures.frame(width: 100, height: 100, capturedAt: now)

        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: frame,
            context: CaptureFinalization.Context(
                frontmostBundleID: "com.apple.dt.Xcode",
                axAvailable: true
            ),
            to: finalURL,
            writer: &writer,
            now: now
        )

        let manifestData = try Data(contentsOf: finalURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        // spec_version
        #expect(manifest.spec_version == 1)
        // id is a valid UUIDv7 with version nibble == '7'
        #expect(UUIDv7.isValid(manifest.id))
        // Position 14 of the string must be literally '7'.
        let idChars = Array(manifest.id)
        #expect(idChars[14] == "7")
        // created_at: ISO-8601 UTC parseable
        #expect(ISO8601UTC.date(from: manifest.created_at) != nil)
        // expires_at: created_at + 24h
        let created = ISO8601UTC.date(from: manifest.created_at)!
        let expires = ISO8601UTC.date(from: manifest.expires_at!)!
        let delta = expires.timeIntervalSince(created)
        #expect(abs(delta - 24 * 3600) < 1) // sub-second tolerance
        // pinned, mode, kind
        #expect(manifest.pinned == false)
        #expect(manifest.mode == "verbal")
        #expect(manifest.kind == "image")
        // master.width/height match frame.pixelBounds
        #expect(manifest.master.width == Int(frame.pixelBounds.width))
        #expect(manifest.master.height == Int(frame.pixelBounds.height))
        // display.id matches frame.display.id
        #expect(manifest.display.id == frame.display.id)
    }

    @Test("Happy path writes master.png, thumb.jpg, context.json, manifest.json")
    func happyPathWritesAllFiles() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(width: 300, height: 150),
            context: CaptureFinalization.Context(
                frontmostBundleID: "com.apple.dt.Xcode",
                frontmostWindowTitle: "CaptureFinalization.swift",
                axAvailable: true
            ),
            to: finalURL,
            writer: &writer
        )

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: finalURL.path))
        #expect(fm.fileExists(atPath: finalURL.appendingPathComponent("master.png").path))
        #expect(fm.fileExists(atPath: finalURL.appendingPathComponent("thumb.jpg").path))
        #expect(fm.fileExists(atPath: finalURL.appendingPathComponent("context.json").path))
        #expect(fm.fileExists(atPath: finalURL.appendingPathComponent("manifest.json").path))

        // master.png has PNG magic bytes.
        let master = try Data(contentsOf: finalURL.appendingPathComponent("master.png"))
        #expect(master.count >= 8)
        #expect(master[0..<8] == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        // thumb.jpg has JPEG magic bytes.
        let thumb = try Data(contentsOf: finalURL.appendingPathComponent("thumb.jpg"))
        #expect(thumb.count >= 3)
        #expect(thumb[0..<3] == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test("Thumbnail respects 256px max dimension")
    func thumbnailBounded() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("cap.shot")
        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: Fixtures.frame(width: 1024, height: 768),
            context: CaptureFinalization.Context(
                frontmostBundleID: "com.apple.dt.Xcode",
                axAvailable: true
            ),
            to: finalURL,
            writer: &writer
        )

        // Decode thumb.jpg and verify max side ≤ 256.
        let thumbData = try Data(contentsOf: finalURL.appendingPathComponent("thumb.jpg"))
        let src = CGImageSourceCreateWithData(thumbData as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        let w = props[kCGImagePropertyPixelWidth] as! Int
        let h = props[kCGImagePropertyPixelHeight] as! Int
        #expect(max(w, h) <= 256)
        // 1024x768 → target max side 256 → 256x192.
        #expect(max(w, h) == 256)
    }

    @Test("UUIDv7 validator accepts valid and rejects invalid shapes")
    func uuidV7Validator() {
        // Freshly generated ones should validate.
        for _ in 0..<32 {
            let id = UUIDv7.generate()
            #expect(UUIDv7.isValid(id), "expected valid UUIDv7: \(id)")
            // Version nibble literally '7'.
            #expect(Array(id)[14] == "7")
        }
        // Invalid shapes.
        #expect(!UUIDv7.isValid(""))
        #expect(!UUIDv7.isValid("not-a-uuid"))
        // UUIDv4 has '4' in the version slot.
        #expect(!UUIDv7.isValid(UUID().uuidString.lowercased()))
    }
}
