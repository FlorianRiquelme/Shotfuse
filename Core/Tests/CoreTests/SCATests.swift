import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Core

// MARK: - Fixtures

private enum SCAFixtures {

    static func display(id: CGDirectDisplayID = 1) -> DisplayMetadata {
        DisplayMetadata(
            id: id,
            nativeWidth: 200,
            nativeHeight: 200,
            nativeScale: 1.0,
            vendorID: nil,
            productID: nil,
            serial: nil,
            localizedName: "Fixture Display",
            globalFrame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
    }

    /// Checkerboard image — distinct enough that post-blur SHA256 reliably
    /// differs from the source even with a modest blur radius.
    static func checkerImage(width: Int = 200, height: Int = 200) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * bytesPerRow + col * 4
                let onWhite = ((row / 10) + (col / 10)) % 2 == 0
                let v: UInt8 = onWhite ? 0xFF : 0x10
                pixels[offset + 0] = v
                pixels[offset + 1] = v
                pixels[offset + 2] = v
                pixels[offset + 3] = 0xFF
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

    static func frame(width: Int = 200, height: Int = 200) -> CapturedFrame {
        CapturedFrame(
            image: checkerImage(width: width, height: height),
            pixelBounds: CGRect(x: 0, y: 0, width: width, height: height),
            display: display(),
            capturedAt: Date()
        )
    }

    /// Finalize a fresh `.shot/` package into `tmp` and return its URL.
    static func writeShotPackage(in tmp: URL, named name: String = "fixture") throws -> URL {
        let finalURL = tmp.appendingPathComponent("\(name).shot")
        let ctx = CaptureFinalization.Context(
            frontmostBundleID: "com.apple.Safari", // non-sensitive
            axAvailable: true
        )
        var writer = ShotPackageWriter()
        try CaptureFinalization.finalize(
            frame: frame(),
            context: ctx,
            to: finalURL,
            writer: &writer
        )
        return finalURL
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private func makeTmpDir(prefix: String = "sca") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Suite

@Suite("SCATests")
struct SCATests {

    // ─────────────────────────────────────────────────────────────────────
    // (1) Analyzer stub + patchManifest merge
    // ─────────────────────────────────────────────────────────────────────
    @Test("Stub analyzer returns [.password_field] → patchManifest merges into manifest.json")
    func stubAnalyzerPatchesManifest() async throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        // Arrange: write a fresh capture.
        let shotURL = try SCAFixtures.writeShotPackage(in: tmp)
        let manifestURL = shotURL.appendingPathComponent("manifest.json")

        // Sanity: initial manifest has no `sensitivity` key yet.
        let initialData = try Data(contentsOf: manifestURL)
        let initialJSON = try JSONSerialization.jsonObject(with: initialData) as! [String: Any]
        #expect(initialJSON["sensitivity"] == nil || (initialJSON["sensitivity"] as? NSNull) != nil)

        // Act: stubbed analyzer → patchManifest.
        let analyzer: any SensitivityAnalyzing = StubSensitivityAnalyzer(tags: [.password_field])
        let masterURL = shotURL.appendingPathComponent("master.png")
        let tags = try await analyzer.analyze(fileURL: masterURL)
        #expect(tags == [.password_field])

        try patchManifest(url: shotURL, with: ManifestSensitivityField(tags))

        // Assert: manifest.json now has `sensitivity = ["password_field"]`.
        let patchedData = try Data(contentsOf: manifestURL)
        let patchedJSON = try JSONSerialization.jsonObject(with: patchedData) as! [String: Any]
        #expect(patchedJSON["sensitivity"] as? [String] == ["password_field"])

        // Other fields preserved.
        #expect((patchedJSON["id"] as? String) == (initialJSON["id"] as? String))
        #expect((patchedJSON["spec_version"] as? Int) == 1)
    }

    @Test("patchManifest accepts a direct manifest.json URL as well as a package URL")
    func patchManifestAcceptsFilePath() async throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let shotURL = try SCAFixtures.writeShotPackage(in: tmp)
        let manifestURL = shotURL.appendingPathComponent("manifest.json")

        try patchManifest(url: manifestURL, with: ManifestSensitivityField([.nudity]))
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL)) as! [String: Any]
        #expect(json["sensitivity"] as? [String] == ["nudity"])
    }

    @Test("patchManifest throws manifestMissing when the .shot has no manifest.json")
    func patchManifestMissing() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let empty = tmp.appendingPathComponent("empty.shot")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)

        #expect(throws: ManifestPatchError.self) {
            try patchManifest(url: empty, with: ManifestSensitivityField([.none]))
        }
    }

    @Test("StubSensitivityAnalyzer normalizes empty tag list to [.none]")
    func stubNormalizesEmpty() async throws {
        let analyzer = StubSensitivityAnalyzer(tags: [])
        let result = try await analyzer.analyze(SCAFixtures.checkerImage(width: 4, height: 4))
        #expect(result == [.none])
    }

    // ─────────────────────────────────────────────────────────────────────
    // (2) Redaction path
    // ─────────────────────────────────────────────────────────────────────
    @Test("redact: new .shot/ has new id, redacted_from=original, sensitivity=[none]; master bytes differ")
    func redactionHappyPath() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        // Arrange: original package.
        let original = try SCAFixtures.writeShotPackage(in: tmp, named: "orig")
        let originalMasterURL = original.appendingPathComponent("master.png")
        let originalMasterSHA = try SCAFixtures.sha256(of: originalMasterURL)
        let originalManifestJSON = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: original.appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        let originalID = originalManifestJSON["id"] as! String

        // Act: redact a visible central rectangle.
        let destination = tmp.appendingPathComponent("redacted.shot")
        let rects = [CGRect(x: 40, y: 40, width: 120, height: 120)]

        let tool = RedactAndResave()
        try tool.redact(
            sourcePackage: original,
            to: destination,
            rects: rects
        )

        // Assert: new package exists with redacted_from + sensitivity + new id.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: destination.path))
        let newManifestJSON = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        ) as! [String: Any]

        let newID = newManifestJSON["id"] as! String
        #expect(newID != originalID)
        #expect(UUIDv7.isValid(newID))
        #expect(newManifestJSON["redacted_from"] as? String == originalID)
        #expect(newManifestJSON["sensitivity"] as? [String] == ["none"])

        // Assert: new master.png bytes differ from the original.
        let newMasterURL = destination.appendingPathComponent("master.png")
        let newMasterSHA = try SCAFixtures.sha256(of: newMasterURL)
        #expect(newMasterSHA != originalMasterSHA)
    }

    // ─────────────────────────────────────────────────────────────────────
    // (3) Invariant 3: original master.png is byte-identical after redaction
    // ─────────────────────────────────────────────────────────────────────
    @Test("Invariant 3: original master.png SHA256 unchanged after redaction")
    func invariant3OriginalMasterUntouched() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let original = try SCAFixtures.writeShotPackage(in: tmp, named: "pristine")
        let originalMasterURL = original.appendingPathComponent("master.png")

        let shaBefore = try SCAFixtures.sha256(of: originalMasterURL)

        let destination = tmp.appendingPathComponent("redacted.shot")
        let tool = RedactAndResave()
        try tool.redact(
            sourcePackage: original,
            to: destination,
            rects: [CGRect(x: 20, y: 20, width: 80, height: 80)]
        )

        let shaAfter = try SCAFixtures.sha256(of: originalMasterURL)
        #expect(shaBefore == shaAfter, "master.png of ORIGINAL capture mutated — violates SPEC §5 I3")
    }

    @Test("redact: rejects destination that does not end in .shot")
    func redactRejectsBadDestination() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }
        let original = try SCAFixtures.writeShotPackage(in: tmp)

        let badDestination = tmp.appendingPathComponent("not-a-shot")
        let tool = RedactAndResave()

        #expect(throws: RedactAndResaveError.destinationInvalid) {
            try tool.redact(
                sourcePackage: original,
                to: badDestination,
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            )
        }
    }

    @Test("redact: empty rects array still produces a valid new package (no blur applied)")
    func redactWithEmptyRects() throws {
        let tmp = try makeTmpDir()
        defer { cleanup(tmp) }

        let original = try SCAFixtures.writeShotPackage(in: tmp, named: "norects")
        let destination = tmp.appendingPathComponent("redacted.shot")

        let tool = RedactAndResave()
        try tool.redact(
            sourcePackage: original,
            to: destination,
            rects: []
        )

        // New package exists and carries the redaction metadata even if no
        // pixels were actually blurred (the user may have confirmed redaction
        // with zero remaining rects).
        let json = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        #expect(json["sensitivity"] as? [String] == ["none"])
        #expect(json["redacted_from"] as? String != nil)
    }
}
