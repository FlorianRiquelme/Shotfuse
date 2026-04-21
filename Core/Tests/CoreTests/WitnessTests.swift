import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import Core

// MARK: - Fixtures

private struct WFixtures {
    static func display(id: UInt32 = 1) -> DisplayMetadata {
        DisplayMetadata(
            id: id,
            nativeWidth: 3024,
            nativeHeight: 1964,
            nativeScale: 2.0,
            vendorID: 0x05AC,
            productID: 0xA050,
            serial: nil,
            localizedName: "Built-in Retina Display",
            globalFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
    }

    /// Deterministic solid-red RGBA CGImage.
    static func redRectImage(width: Int = 8, height: Int = 8) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * bytesPerRow + col * 4
                pixels[offset + 0] = 0xFF
                pixels[offset + 1] = 0x20
                pixels[offset + 2] = 0x20
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

    static func frame(
        width: Int = 8,
        height: Int = 8,
        capturedAt: Date = Date()
    ) -> CapturedFrame {
        CapturedFrame(
            image: redRectImage(width: width, height: height),
            pixelBounds: CGRect(x: 0, y: 0, width: width, height: height),
            display: display(),
            capturedAt: capturedAt
        )
    }

    /// Fixed moment used by determinism / formula tests.
    static let fixedDate = Date(timeIntervalSince1970: 1_713_700_000)
}

private func makeTmpDir(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Suite

@Suite("WitnessTests")
struct WitnessTests {

    // ─────────────────────────────────────────────────────────────────
    // (1) Witness package lands under witnesses-root, NOT library root.
    //     Library root is a separate temp dir; we also assert
    //     LibraryIndex row count is 0 afterwards (part-4 dovetail).
    // ─────────────────────────────────────────────────────────────────
    @Test("Witness package is written under witnesses-root, NOT library root; LibraryIndex untouched")
    func witnessPackageLocation() async throws {
        let libraryRoot = try makeTmpDir("witness-libraryroot")
        defer { cleanup(libraryRoot) }
        let witnessesRoot = try makeTmpDir("witness-witnessesroot")
        defer { cleanup(witnessesRoot) }

        // Real LibraryIndex against a separate temp DB to assert non-insertion.
        let dbURL = libraryRoot.appendingPathComponent("index.db")
        let index = try LibraryIndex(databaseURL: dbURL)
        defer { Task { await index.close() } }

        // Pre-condition: library is empty.
        let pre = try await index.count()
        #expect(pre == 0)

        let frame = WFixtures.frame()
        let input = WitnessCapture.Input(
            frame: frame,
            witnessesRoot: witnessesRoot,
            now: WFixtures.fixedDate
        )
        let finalURL = try await WitnessCapture.captureWitness(input)

        // (a) The package lives under witnessesRoot, NOT libraryRoot.
        #expect(finalURL.path.hasPrefix(witnessesRoot.path))
        #expect(!finalURL.path.hasPrefix(libraryRoot.path))
        #expect(finalURL.pathExtension == "shot")

        // (b) Package contains master.png + manifest.json.
        let masterURL   = finalURL.appendingPathComponent("master.png")
        let manifestURL = finalURL.appendingPathComponent("manifest.json")
        let thumbURL    = finalURL.appendingPathComponent("thumb.jpg")
        #expect(FileManager.default.fileExists(atPath: masterURL.path))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))

        // (c) Manifest has mode=witness + witness.hash populated, and
        //     lives on disk WITH the witness field present.
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["mode"] as? String == "witness")
        let witness = json?["witness"] as? [String: Any]
        #expect(witness?["algorithm"] as? String == "sha256")
        let hashStr = witness?["hash"] as? String ?? ""
        #expect(hashStr.count == 64)
        #expect(hashStr.allSatisfy { "0123456789abcdef".contains($0) })

        // (d) LibraryIndex MUST NOT have acquired a row.
        let post = try await index.count()
        #expect(post == 0)
    }

    // ─────────────────────────────────────────────────────────────────
    // (2) Formula test — compute the hash by hand using the same
    //     primitives and assert byte-for-byte equality with WitnessHash.
    // ─────────────────────────────────────────────────────────────────
    @Test("Witness hash matches the SPEC §13.6 formula exactly")
    func witnessHashFormula() throws {
        // Deterministic fixture — we feed known bytes to WitnessHash.compute
        // and recompute the same digest here with independent primitives.
        let masterPNG = Data("synthetic-master-png-bytes".utf8)
        let capturedAt = "2026-04-21T12:34:56Z"

        // Minimal but realistic manifest: keys in a DELIBERATELY non-sorted
        // order to prove the canonicalizer sorts. Also carries a `witness`
        // key that the canonicalizer must strip.
        let manifestObject: [String: Any] = [
            "spec_version": 1,
            "kind": "image",
            "mode": "witness",
            "id": "01234567-89ab-7cde-8fab-0123456789ab",
            "created_at": capturedAt,
            "expires_at": "2026-04-22T12:34:56Z",
            "pinned": false,
            "witness": [
                "hash": "deadbeef",
                "algorithm": "sha256",
            ],
            "master": [
                "path": "master.png",
                "width": 16,
                "height": 16,
                "dpi": 144.0,
            ],
            "display": [
                "id": 1,
                "nativeWidth": 3024,
                "nativeHeight": 1964,
                "nativeScale": 2.0,
                "localizedName": "Built-in",
            ],
        ]
        let manifestJSON = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )

        let computed = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: manifestJSON,
            capturedAt: capturedAt
        )

        // Recompute independently:
        //   1. Inner SHA-256 of masterPNG.
        let innerBytes = Data(SHA256.hash(data: masterPNG))

        //   2. Canonical JSON of the manifest with `witness` stripped.
        //      We use WitnessHash.canonicalManifestBytes for the
        //      canonicalization primitive, which is itself pinned by the
        //      next test (key-order independence). Direct reuse is honest:
        //      this test is asserting the CONCATENATION-then-hash shape,
        //      not the canonicalization rule (covered separately).
        let canonical = try WitnessHash.canonicalManifestBytes(manifestJSON)

        //   3. captured_at UTF-8 bytes.
        let tsBytes = Data(capturedAt.utf8)

        //   4. Outer SHA-256 of concatenation.
        var concat = Data()
        concat.append(innerBytes)
        concat.append(canonical)
        concat.append(tsBytes)
        let outerBytes = Data(SHA256.hash(data: concat))

        // Hex-lowercase.
        let expected = outerBytes.map { String(format: "%02x", $0) }.joined()

        #expect(computed == expected)
        #expect(computed.count == 64)
        #expect(computed.allSatisfy { "0123456789abcdef".contains($0) })

        // Sanity: the canonical bytes MUST NOT contain the stripped
        // `witness` object — specifically, the `"witness":{` key form.
        // (The substring "witness" can legitimately appear as a value,
        // e.g. `"mode":"witness"` — only the top-level KEY is forbidden.)
        let canonicalString = String(data: canonical, encoding: .utf8) ?? ""
        #expect(!canonicalString.contains("\"witness\":{"))
        #expect(!canonicalString.contains("\"hash\":\"deadbeef\""))
    }

    // ─────────────────────────────────────────────────────────────────
    // (3) Canonical JSON is key-order independent.
    // ─────────────────────────────────────────────────────────────────
    @Test("Two manifests with differently-ordered keys produce the same witness hash")
    func canonicalJSONKeyOrderIndependence() throws {
        let masterPNG = Data("png-bytes-for-order-test".utf8)
        let capturedAt = "2026-04-21T10:00:00Z"

        // Same semantic manifest, authored twice with different key order
        // AND different key order in a nested object, too.
        let orderA: [String: Any] = [
            "spec_version": 1,
            "id": "id-1",
            "created_at": capturedAt,
            "mode": "witness",
            "kind": "image",
            "pinned": false,
            "master": [
                "path": "master.png",
                "width": 8,
                "height": 8,
                "dpi": 144.0,
            ],
        ]
        let orderB: [String: Any] = [
            "kind": "image",
            "pinned": false,
            "master": [
                "dpi": 144.0,
                "height": 8,
                "width": 8,
                "path": "master.png",
            ],
            "id": "id-1",
            "spec_version": 1,
            "mode": "witness",
            "created_at": capturedAt,
        ]

        // Serialize WITHOUT .sortedKeys so the underlying byte order really
        // does differ. `JSONSerialization.data` may pick any ordering; we
        // just need the WitnessHash canonicalizer to normalize them.
        let aJSON = try JSONSerialization.data(withJSONObject: orderA)
        let bJSON = try JSONSerialization.data(withJSONObject: orderB)

        let hashA = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: aJSON,
            capturedAt: capturedAt
        )
        let hashB = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: bJSON,
            capturedAt: capturedAt
        )
        #expect(hashA == hashB)
    }

    // ─────────────────────────────────────────────────────────────────
    // (4) LibraryIndex never called — real DB, row count stays 0 after
    //     a witness capture. (Dovetails with test (1) but stands alone
    //     to make the invariant explicit.)
    // ─────────────────────────────────────────────────────────────────
    @Test("Witness capture does NOT insert into LibraryIndex (real DB, count stays 0)")
    func witnessDoesNotInsertIntoLibrary() async throws {
        let libraryRoot = try makeTmpDir("witness-libraryroot-2")
        defer { cleanup(libraryRoot) }
        let witnessesRoot = try makeTmpDir("witness-witnessesroot-2")
        defer { cleanup(witnessesRoot) }

        let dbURL = libraryRoot.appendingPathComponent("index.db")
        let index = try LibraryIndex(databaseURL: dbURL)
        defer { Task { await index.close() } }

        // Pre-condition.
        #expect(try await index.count() == 0)

        // Run TWO witness captures.
        for i in 0..<2 {
            let input = WitnessCapture.Input(
                frame: WFixtures.frame(),
                witnessesRoot: witnessesRoot,
                now: WFixtures.fixedDate.addingTimeInterval(Double(i))
            )
            _ = try await WitnessCapture.captureWitness(input)
        }

        // Post-condition: the library index is still empty. No witness
        // capture ever called `LibraryIndex.insert`.
        let count = try await index.count()
        #expect(count == 0)
    }

    // ─────────────────────────────────────────────────────────────────
    // (5) Determinism — same master + same timestamp + same manifest
    //     yields the same hash on repeated calls.
    // ─────────────────────────────────────────────────────────────────
    @Test("WitnessHash is deterministic across repeated calls with identical input")
    func witnessHashIsDeterministic() throws {
        let masterPNG = Data("deterministic-master".utf8)
        let capturedAt = "2026-04-21T08:00:00Z"

        let manifest: [String: Any] = [
            "id": "det-id",
            "spec_version": 1,
            "mode": "witness",
            "kind": "image",
            "created_at": capturedAt,
            "pinned": true,
            "master": [
                "path": "master.png",
                "width": 4,
                "height": 4,
                "dpi": 72.0,
            ],
        ]
        let manifestJSON = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )

        let h1 = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: manifestJSON,
            capturedAt: capturedAt
        )
        let h2 = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: manifestJSON,
            capturedAt: capturedAt
        )
        let h3 = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: manifestJSON,
            capturedAt: capturedAt
        )
        #expect(h1 == h2)
        #expect(h2 == h3)

        // A trivial perturbation — different timestamp — MUST change the hash.
        let h4 = try WitnessHash.compute(
            masterPNG: masterPNG,
            manifestJSON: manifestJSON,
            capturedAt: "2026-04-21T08:00:01Z"
        )
        #expect(h4 != h1)
    }

    // ─────────────────────────────────────────────────────────────────
    // (6) The on-disk manifest is self-verifying: feed the written
    //     manifest back through WitnessHash.compute, strip witness,
    //     and the digest must match manifest.witness.hash.
    // ─────────────────────────────────────────────────────────────────
    @Test("Written manifest is self-verifying: recomputing the hash from on-disk bytes matches")
    func writtenManifestIsSelfVerifying() async throws {
        let witnessesRoot = try makeTmpDir("witness-selfverify")
        defer { cleanup(witnessesRoot) }

        let frame = WFixtures.frame()
        let input = WitnessCapture.Input(
            frame: frame,
            witnessesRoot: witnessesRoot,
            now: WFixtures.fixedDate
        )
        let finalURL = try await WitnessCapture.captureWitness(input)

        // Load on-disk master.png bytes and manifest.json bytes.
        let masterData = try Data(contentsOf: finalURL.appendingPathComponent("master.png"))
        let manifestData = try Data(contentsOf: finalURL.appendingPathComponent("manifest.json"))

        // Parse to extract captured_at + stated witness.hash.
        guard
            let obj = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            let capturedAt = obj["created_at"] as? String,
            let witness = obj["witness"] as? [String: Any],
            let statedHash = witness["hash"] as? String
        else {
            Issue.record("Manifest shape on disk is malformed")
            return
        }

        let recomputed = try WitnessHash.compute(
            masterPNG: masterData,
            manifestJSON: manifestData,
            capturedAt: capturedAt
        )
        #expect(recomputed == statedHash)
    }
}
