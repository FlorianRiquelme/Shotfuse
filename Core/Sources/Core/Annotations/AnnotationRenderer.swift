#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Headless-capable renderer: takes an immutable `master.png` CGImage +
// annotations and produces a PNG Data. Pure free function by design so it can
// run off the main thread and in tests without a runloop (SPEC §5 I2 keeps
// UI interaction in AppKit but the pixel pipeline itself is AppKit-free apart
// from font resolution).
//
// Determinism guarantees:
//  - Same inputs + same machine + same macOS minor ⇒ byte-identical PNG.
//  - Drawing uses CoreGraphics with fixed bitmap info; no GPU path.
//  - Blur is a deterministic three-pass box-blur (Wells-Paul Gaussian
//    approximation); CoreImage is avoided because it can dispatch to the GPU
//    and produce non-bit-exact output across renders.
//  - PNG encoding goes through `CGImageDestination` (Path A) or
//    `NSBitmapImageRep` (Path B). Within a single path the output is
//    reproducible; the two paths are close enough for SSIM ≥ 0.995 (see
//    `AnnotationsTests`).
//
// SPEC §5 Invariants honored:
//  - I3: renderer only reads the master CGImage; never writes back.
//  - I6: annotations are in master-pixel space; widths / font / sigma are in
//        points and scaled by `master.dpi / 72` here at render time.

/// Errors surfaced by `AnnotationRenderer`.
public enum AnnotationRendererError: Error, Sendable, Equatable {
    /// Bitmap context could not be created (allocation / parameter failure).
    case contextUnavailable
    /// PNG encoding failed.
    case encodingFailed
}

/// Which backend path to use. Both are pure and deterministic within
/// themselves; they exist so tests can compare SSIM across two distinct code
/// paths that simulate two macOS minor versions.
public enum AnnotationRenderBackend: Sendable {
    /// `CGContext` + `CGImageDestination` path. This is the default.
    case coreGraphics
    /// `NSBitmapImageRep` + `NSGraphicsContext` path.
    case bitmapImageRep
}

/// Pure entry point. Renders `master` with `annotations` stamped on top and
/// returns PNG bytes. Does **not** touch the filesystem and does **not**
/// mutate `master`.
///
/// - Parameters:
///   - master: Immutable source CGImage (typically `master.png` decoded).
///   - annotations: Annotation list; renders in order, later items on top.
///   - pointToPixelScale: `master.dpi / 72`. Points → master-pixel scale for
///     stroke widths, font sizes, and blur sigma. Defaults to 2.0 (Retina).
///   - backend: Which render path to use. See `AnnotationRenderBackend`.
///
/// - Throws: `AnnotationRendererError` on context / encoding failure.
public func renderAnnotations(
    master: CGImage,
    annotations: AnnotationsDocument,
    pointToPixelScale: CGFloat = 2.0,
    backend: AnnotationRenderBackend = .coreGraphics
) throws -> Data {
    let width = master.width
    let height = master.height

    switch backend {
    case .coreGraphics:
        return try renderViaCoreGraphics(
            master: master,
            annotations: annotations,
            width: width,
            height: height,
            pointToPixelScale: pointToPixelScale
        )
    case .bitmapImageRep:
        return try renderViaBitmapImageRep(
            master: master,
            annotations: annotations,
            width: width,
            height: height,
            pointToPixelScale: pointToPixelScale
        )
    }
}

// MARK: - Backend A: CGContext + CGImageDestination

private func renderViaCoreGraphics(
    master: CGImage,
    annotations: AnnotationsDocument,
    width: Int,
    height: Int,
    pointToPixelScale: CGFloat
) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw AnnotationRendererError.contextUnavailable
    }
    let bytesPerRow = width * 4
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw AnnotationRendererError.contextUnavailable
    }

    // Lay the master down at full native resolution. Annotations live in the
    // same master-pixel coordinate system.
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: width, height: height))

    drawAnnotations(
        into: ctx,
        master: master,
        items: annotations.items,
        pointToPixelScale: pointToPixelScale
    )

    guard let cgImage = ctx.makeImage() else {
        throw AnnotationRendererError.encodingFailed
    }
    return try encodePNG(cgImage: cgImage)
}

// MARK: - Backend B: NSBitmapImageRep + NSGraphicsContext

private func renderViaBitmapImageRep(
    master: CGImage,
    annotations: AnnotationsDocument,
    width: Int,
    height: Int,
    pointToPixelScale: CGFloat
) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ) else {
        throw AnnotationRendererError.contextUnavailable
    }

    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw AnnotationRendererError.contextUnavailable
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: width, height: height))

    drawAnnotations(
        into: ctx,
        master: master,
        items: annotations.items,
        pointToPixelScale: pointToPixelScale
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw AnnotationRendererError.encodingFailed
    }
    return data
}

// MARK: - Shared drawing core

private func drawAnnotations(
    into ctx: CGContext,
    master: CGImage,
    items: [Annotation],
    pointToPixelScale: CGFloat
) {
    AnnotationDrawCore.shared.draw(
        into: ctx,
        master: master,
        items: items,
        pointToPixelScale: pointToPixelScale
    )
}

/// Internal draw core. Not part of the public API surface but accessible
/// within the `Core` module so the interactive canvas and the headless
/// renderer both funnel through exactly the same CoreGraphics calls.
/// Intentionally not `@MainActor` — the caller owns the `CGContext`'s thread
/// affinity.
internal struct AnnotationDrawCore: Sendable {
    static let shared = AnnotationDrawCore()

    func draw(
        into ctx: CGContext,
        master: CGImage,
        items: [Annotation],
        pointToPixelScale: CGFloat
    ) {
        for item in items {
            switch item {
            case .blurRect(let b):
                _drawBlur(ctx: ctx, master: master, blur: b, scale: pointToPixelScale)
            case .arrow(let a):
                _drawArrow(ctx: ctx, arrow: a, scale: pointToPixelScale)
            case .text(let t):
                _drawText(ctx: ctx, text: t, scale: pointToPixelScale)
            }
        }
    }

    /// Exposed for the interactive canvas's in-flight drag preview. Not part
    /// of the public API.
    func drawArrow(ctx: CGContext, arrow: Annotation.Arrow, scale: CGFloat) {
        _drawArrow(ctx: ctx, arrow: arrow, scale: scale)
    }
}

// MARK: Arrow

private func _drawArrow(ctx: CGContext, arrow: Annotation.Arrow, scale: CGFloat) {
    let widthPx = CGFloat(arrow.width) * scale
    let from = arrow.from.cgPoint
    let to = arrow.to.cgPoint

    ctx.saveGState()
    defer { ctx.restoreGState() }

    ctx.setStrokeColor(arrow.color.cgColor)
    ctx.setFillColor(arrow.color.cgColor)
    ctx.setLineWidth(widthPx)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Shaft.
    ctx.beginPath()
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()

    // Head: isosceles triangle whose base sits at `to - headLen * direction`.
    let dx = Double(to.x - from.x)
    let dy = Double(to.y - from.y)
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return }

    let ux = dx / len
    let uy = dy / len
    let headLen = Double(widthPx) * AnnotationDefaults.arrowHeadScale
    let headHalf = Double(widthPx) * (AnnotationDefaults.arrowHeadScale / 2.0)

    let baseX = Double(to.x) - ux * headLen
    let baseY = Double(to.y) - uy * headLen
    // Perpendicular unit vector.
    let px = -uy
    let py = ux

    let p1 = CGPoint(x: baseX + px * headHalf, y: baseY + py * headHalf)
    let p2 = CGPoint(x: baseX - px * headHalf, y: baseY - py * headHalf)

    ctx.beginPath()
    ctx.move(to: to)
    ctx.addLine(to: p1)
    ctx.addLine(to: p2)
    ctx.closePath()
    ctx.fillPath()
}

// MARK: Text

private func _drawText(ctx: CGContext, text: Annotation.Text, scale: CGFloat) {
    let pointSize = CGFloat(text.font.size) * scale
    // Use `NSFont.preferredFont(forTextStyle:)` per §6.4, then override to a
    // fixed size so dynamic-type doesn't drift the render.
    let base = NSFont.preferredFont(forTextStyle: .body)
    let font = NSFont(descriptor: base.fontDescriptor, size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)

    ctx.saveGState()
    defer { ctx.restoreGState() }

    // CoreGraphics text Y grows upward (bottom-left origin), matching the
    // annotation coordinate system. No flip needed.
    let nsColor = NSColor(
        srgbRed: CGFloat(text.color.red) / 255.0,
        green: CGFloat(text.color.green) / 255.0,
        blue: CGFloat(text.color.blue) / 255.0,
        alpha: CGFloat(text.color.alpha) / 255.0
    )
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: nsColor,
    ]
    let attributed = NSAttributedString(string: text.string, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = text.at.cgPoint
    CTLineDraw(line, ctx)
}

// MARK: Blur

private func _drawBlur(
    ctx: CGContext,
    master: CGImage,
    blur: Annotation.BlurRect,
    scale: CGFloat
) {
    // Compute integer pixel rect clipped to the master.
    let r = blur.rect.cgRect
    let x = max(0, Int(r.origin.x.rounded(.down)))
    // `blur.rect.y` is in the bottom-left master-pixel space (matches CG
    // context Y). Convert to the master CGImage's top-left origin for
    // cropping: crop uses the CGImage's native coordinate system, which is
    // top-left, so we need to flip.
    let yBottom = max(0, Int(r.origin.y.rounded(.down)))
    let w = max(0, Int(r.size.width.rounded(.up)))
    let h = max(0, Int(r.size.height.rounded(.up)))
    guard w > 0, h > 0 else { return }
    let mw = master.width
    let mh = master.height
    let clampedW = min(w, mw - x)
    let clampedH = min(h, mh - yBottom)
    guard clampedW > 0, clampedH > 0 else { return }

    // CGImage cropping is in top-left space. Convert bottom-left y to top-left y.
    let yTop = mh - yBottom - clampedH
    let cropRect = CGRect(x: x, y: yTop, width: clampedW, height: clampedH)
    guard let crop = master.cropping(to: cropRect) else { return }

    // Re-decode the crop into a contiguous RGBA8 buffer we own.
    guard let rgba = decodeToRGBA8(crop) else { return }
    var pixels = rgba.pixels
    let sigmaPx = max(0.0, Double(blur.sigma) * Double(scale))
    boxBlur3Pass(pixels: &pixels, width: rgba.width, height: rgba.height, sigma: sigmaPx)

    // Re-wrap blurred pixels into a CGImage and composite back at the
    // original (bottom-left) destination rect.
    guard let blurred = makeCGImage(pixels: pixels, width: rgba.width, height: rgba.height) else {
        return
    }
    let destRect = CGRect(x: CGFloat(x), y: CGFloat(yBottom), width: CGFloat(clampedW), height: CGFloat(clampedH))
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.interpolationQuality = .none
    ctx.draw(blurred, in: destRect)
}

// MARK: - Deterministic RGBA8 helpers

/// Raw RGBA8 pixel buffer + dimensions.
private struct RGBA8 {
    var pixels: [UInt8]
    let width: Int
    let height: Int
}

/// Decodes any `CGImage` into an RGBA8 buffer we own and control. Ensures
/// downstream blur math operates on a deterministic, platform-independent
/// pixel layout.
private func decodeToRGBA8(_ image: CGImage) -> RGBA8? {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { return nil }
    return RGBA8(pixels: pixels, width: width, height: height)
}

/// Wraps an RGBA8 buffer back into a `CGImage`.
private func makeCGImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

/// Three-pass box blur approximating a Gaussian. The radius for each pass is
/// derived from the desired sigma via the standard Wells formula
/// `r = round(sqrt(12σ²/n + 1) − 1) / 2` with n = 3 passes. Completely
/// deterministic — no floating point in the inner loop after radius is fixed.
private func boxBlur3Pass(pixels: inout [UInt8], width: Int, height: Int, sigma: Double) {
    guard sigma > 0, width > 0, height > 0 else { return }
    let radius = boxBlurRadius(forSigma: sigma)
    guard radius >= 1 else { return }

    var buf = pixels
    for _ in 0..<3 {
        boxBlurPass(src: buf, dst: &pixels, width: width, height: height, radius: radius, horizontal: true)
        boxBlurPass(src: pixels, dst: &buf, width: width, height: height, radius: radius, horizontal: false)
    }
    pixels = buf
}

/// Integer radius for a 3-pass box-blur approximation of a Gaussian with the
/// given sigma in pixels.
private func boxBlurRadius(forSigma sigma: Double) -> Int {
    // r = (sqrt(12σ²/n + 1) − 1) / 2 with n = 3.
    let n = 3.0
    let r = ((12.0 * sigma * sigma / n + 1.0).squareRoot() - 1.0) / 2.0
    return max(0, Int(r.rounded()))
}

/// One axis of a box blur. Reads from `src`, writes to `dst`. Handles edges by
/// clamping (replicate) — simple, deterministic, good enough for opaque
/// in-image redaction.
private func boxBlurPass(
    src: [UInt8],
    dst: inout [UInt8],
    width: Int,
    height: Int,
    radius: Int,
    horizontal: Bool
) {
    let window = radius * 2 + 1
    if horizontal {
        for y in 0..<height {
            let rowStart = y * width * 4
            for x in 0..<width {
                var rs = 0, gs = 0, bs = 0, a_s = 0
                for k in -radius...radius {
                    let xx = min(max(x + k, 0), width - 1)
                    let off = rowStart + xx * 4
                    rs += Int(src[off + 0])
                    gs += Int(src[off + 1])
                    bs += Int(src[off + 2])
                    a_s += Int(src[off + 3])
                }
                let off = rowStart + x * 4
                dst[off + 0] = UInt8(rs / window)
                dst[off + 1] = UInt8(gs / window)
                dst[off + 2] = UInt8(bs / window)
                dst[off + 3] = UInt8(a_s / window)
            }
        }
    } else {
        for y in 0..<height {
            for x in 0..<width {
                var rs = 0, gs = 0, bs = 0, a_s = 0
                for k in -radius...radius {
                    let yy = min(max(y + k, 0), height - 1)
                    let off = (yy * width + x) * 4
                    rs += Int(src[off + 0])
                    gs += Int(src[off + 1])
                    bs += Int(src[off + 2])
                    a_s += Int(src[off + 3])
                }
                let off = (y * width + x) * 4
                dst[off + 0] = UInt8(rs / window)
                dst[off + 1] = UInt8(gs / window)
                dst[off + 2] = UInt8(bs / window)
                dst[off + 3] = UInt8(a_s / window)
            }
        }
    }
}

// MARK: - PNG encoding

/// Encodes a CGImage to PNG bytes via `CGImageDestination`. No metadata is
/// written (no tIME chunk, no text chunks) so output is reproducible byte-for-
/// byte across runs.
private func encodePNG(cgImage: CGImage) throws -> Data {
    let mdata = CFDataCreateMutable(nil, 0)!
    guard let dest = CGImageDestinationCreateWithData(
        mdata,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw AnnotationRendererError.encodingFailed
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw AnnotationRendererError.encodingFailed
    }
    return mdata as Data
}

#endif
