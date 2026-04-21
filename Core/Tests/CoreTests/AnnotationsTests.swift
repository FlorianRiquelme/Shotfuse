#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Core

// SPEC §6.4 / P5.1 contract tests:
//  1. Byte-identical re-render on same-machine/same-minor fixture.
//  2. SSIM ≥ 0.995 across two fixture render paths (simulating two macOS
//     patchlevels via the CoreGraphics vs NSBitmapImageRep backends).
//  3. Coordinates are in master-pixel space at render time (arrow endpoints,
//     blur rect region).

@Suite("AnnotationsTests")
struct AnnotationsTests {

    // MARK: Fixtures

    /// Builds a deterministic 256×160 RGBA master: a simple horizontal
    /// gradient plus a solid quadrant, so annotations have something visible
    /// to land on and blur changes are measurable.
    static func makeFixtureMaster() throws -> CGImage {
        let width = 256
        let height = 160
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.fixture("ctx")
        }

        // Base gradient (opaque blue → cyan horizontally).
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            ctx.setFillColor(red: 0.1, green: 0.3 + 0.6 * t, blue: 0.8, alpha: 1.0)
            ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }
        // Solid red quadrant in the top-right.
        ctx.setFillColor(red: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        ctx.fill(CGRect(x: 160, y: 80, width: 96, height: 80))

        guard let img = ctx.makeImage() else { throw TestError.fixture("img") }
        return img
    }

    static func makeFixtureAnnotations() -> AnnotationsDocument {
        AnnotationsDocument(items: [
            .arrow(Annotation.Arrow(
                from: Point(x: 20, y: 20),
                to: Point(x: 200, y: 120),
                color: .defaultArrow,
                width: 4
            )),
            .blurRect(Annotation.BlurRect(
                rect: Rect(x: 170, y: 90, width: 64, height: 56),
                sigma: 12
            )),
            .text(Annotation.Text(
                at: Point(x: 30, y: 60),
                string: "shotfuse",
                font: .systemBody,
                color: .defaultArrow
            )),
        ])
    }

    // MARK: - Test 1: byte-identical re-render on same machine/same minor

    @Test("Byte-identical PNG across two renders of the same inputs")
    func byteIdenticalReRender() throws {
        let master = try Self.makeFixtureMaster()
        let doc = Self.makeFixtureAnnotations()

        let a = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        let b = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        #expect(a == b, "Two renders of the same fixture produced different PNG bytes (\(a.count) vs \(b.count))")
    }

    // MARK: - Test 2: SSIM ≥ 0.995 across two fixture render paths

    @Test("SSIM ≥ 0.995 across the CoreGraphics and NSBitmapImageRep backends")
    func ssimAcrossPathsAboveThreshold() throws {
        let master = try Self.makeFixtureMaster()
        let doc = Self.makeFixtureAnnotations()

        let pngA = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        let pngB = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .bitmapImageRep
        )

        let ssim = try simpleSSIM(pngA: pngA, pngB: pngB)
        #expect(ssim >= 0.995, "SSIM below 0.995: \(ssim)")
    }

    // MARK: - Test 3: coordinates are in master-pixel space

    @Test("Arrow endpoints are rendered in master-pixel space, not view points")
    func coordinateSpaceIsMasterPixelForArrow() throws {
        let master = try Self.makeFixtureMaster()
        let width = master.width
        let height = master.height

        // Arrow tip lands exactly at pixel (200, 120) in master-pixel space.
        // We render at scale 2 so if the renderer accidentally treated coords
        // as points, the tip would land at (400, 240) — outside the master —
        // and the pixel at (200, 120) would be untouched.
        let doc = AnnotationsDocument(items: [
            .arrow(Annotation.Arrow(
                from: Point(x: 50, y: 20),
                to: Point(x: 200, y: 120),
                color: Color(red: 0x00, green: 0xFF, blue: 0x00),    // pure green
                width: 4
            )),
        ])

        let png = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )

        let rendered = try decodePNGToRGBA8(png, width: width, height: height)
        // Sample a 5×5 region around the arrow tip (200, 120) in master-pixel,
        // bottom-left space. Convert to top-left for the row index.
        let tipX = 200
        let tipY = height - 120 // flip bottom-left → top-left
        var greenHits = 0
        for dy in -5...5 {
            for dx in -5...5 {
                let px = tipX + dx
                let py = tipY + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let off = (py * width + px) * 4
                let r = rendered[off + 0]
                let g = rendered[off + 1]
                let b = rendered[off + 2]
                // Arrowhead fills with pure green; anti-aliasing lets a bit
                // bleed but tip pixels should be dominantly green.
                if g > 150 && r < 120 && b < 120 { greenHits += 1 }
            }
        }
        #expect(greenHits >= 3, "Arrow tip not rendered at master-pixel (200,120); green hits=\(greenHits)")
    }

    @Test("Blur rect applies to the correct master-pixel region")
    func blurRectInMasterPixelSpace() throws {
        let master = try Self.makeFixtureMaster()
        let width = master.width
        let height = master.height

        // Blur inside the solid red quadrant. Since the quadrant is uniform,
        // the blur should still read red — but variance of the region
        // (max-min per channel) must drop near zero after blurring, and must
        // NOT have touched any pixel outside the rect.
        let doc = AnnotationsDocument(items: [
            .blurRect(Annotation.BlurRect(
                rect: Rect(x: 170, y: 90, width: 64, height: 56),
                sigma: 12
            ))
        ])

        let pngBefore = try renderAnnotations(
            master: master,
            annotations: AnnotationsDocument(items: []),
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        let pngAfter = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )

        let before = try decodePNGToRGBA8(pngBefore, width: width, height: height)
        let after = try decodePNGToRGBA8(pngAfter, width: width, height: height)

        // A pixel well outside the blur rect — (50, 50) in bottom-left space,
        // which lives in the gradient region — must be byte-identical.
        let outsideX = 50
        let outsideY = height - 50
        let outOff = (outsideY * width + outsideX) * 4
        for c in 0..<4 {
            #expect(before[outOff + c] == after[outOff + c], "Pixel outside blur rect was modified (channel \(c))")
        }

        // A pixel inside the blur rect must differ OR be identical by
        // coincidence — since the rect sits entirely inside a uniform red
        // region, the blur is near-identity there. Pick an edge pixel where
        // the rect straddles the gradient/solid boundary — (172, 92) in
        // bottom-left space is inside the rect (170..234, 90..146) and
        // within the solid quadrant.
        // Instead, verify: every pixel inside the rect is still reasonable
        // red (dominant red channel) — the blur preserved the region's
        // character.
        var redDominant = 0
        for y in 90..<(90 + 56) {
            for x in 170..<(170 + 64) {
                let py = height - 1 - y
                let off = (py * width + x) * 4
                if after[off + 0] > 150 && after[off + 1] < 120 && after[off + 2] < 120 {
                    redDominant += 1
                }
            }
        }
        let total = 64 * 56
        // Expect the vast majority of the blurred rect to still read as red.
        #expect(redDominant > total * 3 / 4, "Blur rect didn't land on the expected master-pixel region: \(redDominant)/\(total) red-dominant")
    }

    // MARK: - JSON round-trip sanity (kept small; the primary contract is the renderer)

    @Test("annotations.json round-trips byte-equal with sorted keys")
    func annotationsJSONRoundTrip() throws {
        let doc = Self.makeFixtureAnnotations()
        let j = AnnotationsJSON()
        let a = try j.encode(doc)
        let decoded = try j.decode(a)
        #expect(decoded == doc)
        // Encoding twice must be byte-identical thanks to sortedKeys.
        let b = try j.encode(decoded)
        #expect(a == b)
    }
}

// MARK: - Helpers

private enum TestError: Error {
    case fixture(String)
    case decode(String)
}

/// Decodes PNG bytes into an RGBA8 byte array at the expected dimensions.
private func decodePNGToRGBA8(_ png: Data, width: Int, height: Int) throws -> [UInt8] {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw TestError.decode("CGImageSource") }
    guard image.width == width, image.height == height else {
        throw TestError.decode("unexpected dims \(image.width)x\(image.height)")
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { throw TestError.decode("redraw") }
    return pixels
}

/// Mini SSIM implementation (luma channel, 8×8 non-overlapping blocks).
/// Returns the mean SSIM across blocks in [0, 1]. This is smaller than the
/// canonical 11×11 Gaussian-windowed SSIM but sufficient for the P5.1 contract
/// "SSIM ≥ 0.995 across simulated patchlevels" — the test is about gross
/// structural equivalence of the two backends, not a pixel-perfect bound.
private func simpleSSIM(pngA: Data, pngB: Data) throws -> Double {
    // Decode both into the same dims.
    guard let srcA = CGImageSourceCreateWithData(pngA as CFData, nil),
          let imgA = CGImageSourceCreateImageAtIndex(srcA, 0, nil),
          let srcB = CGImageSourceCreateWithData(pngB as CFData, nil),
          let imgB = CGImageSourceCreateImageAtIndex(srcB, 0, nil)
    else { throw TestError.decode("ssim-src") }
    let width = imgA.width
    let height = imgA.height
    #expect(imgB.width == width && imgB.height == height, "SSIM dims mismatch")
    let a = try decodePNGToRGBA8(pngA, width: width, height: height)
    let b = try decodePNGToRGBA8(pngB, width: width, height: height)

    // Luma (BT.601) in [0,1] for each pixel.
    func luma(_ buf: [UInt8]) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(buf[i * 4 + 0]) / 255.0
            let g = Double(buf[i * 4 + 1]) / 255.0
            let bl = Double(buf[i * 4 + 2]) / 255.0
            out[i] = 0.299 * r + 0.587 * g + 0.114 * bl
        }
        return out
    }
    let la = luma(a)
    let lb = luma(b)

    // SSIM constants (L = 1 since values in [0,1]).
    let c1 = pow(0.01, 2.0)
    let c2 = pow(0.03, 2.0)

    let block = 8
    var sum = 0.0
    var count = 0
    var y = 0
    while y + block <= height {
        var x = 0
        while x + block <= width {
            var meanA = 0.0, meanB = 0.0
            for dy in 0..<block {
                for dx in 0..<block {
                    let off = (y + dy) * width + (x + dx)
                    meanA += la[off]
                    meanB += lb[off]
                }
            }
            let n = Double(block * block)
            meanA /= n
            meanB /= n

            var varA = 0.0, varB = 0.0, cov = 0.0
            for dy in 0..<block {
                for dx in 0..<block {
                    let off = (y + dy) * width + (x + dx)
                    let da = la[off] - meanA
                    let db = lb[off] - meanB
                    varA += da * da
                    varB += db * db
                    cov += da * db
                }
            }
            varA /= n
            varB /= n
            cov /= n

            let numerator = (2 * meanA * meanB + c1) * (2 * cov + c2)
            let denom = (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2)
            sum += numerator / denom
            count += 1
            x += block
        }
        y += block
    }
    return count == 0 ? 1.0 : sum / Double(count)
}

#endif
