#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation

// Interactive AppKit canvas for editing annotations on top of a displayed
// master image. Keeps as little logic as possible: hit-testing + tool dispatch
// live here; the actual pixel drawing is shared with the headless renderer
// via `drawAnnotationsPreview`. This way the on-screen preview and the
// exported PNG cannot drift.
//
// SPEC §5 Invariants honored:
//  - I2: UI layer is AppKit (NSView), not SwiftUI.
//  - I3: the canvas never mutates `master`. Live edits accumulate in the
//        `AnnotationsDocument`; final bytes are produced by the headless
//        renderer.
//  - I6: all interaction coordinates are converted to master-pixel space on
//        input. The view's bounds are mapped 1:1 onto master-pixel space via
//        `pointToPixelScale`.

/// Currently-selected tool in the canvas. The public type drives the toolbar
/// in the SwiftUI inspector strip (kept in the App target).
public enum AnnotationTool: Sendable, Equatable {
    case arrow
    case text
    case blurRect
}

/// NSView delegate. Calls fire on the main actor because the canvas itself is
/// main-actor isolated.
@MainActor
public protocol AnnotationCanvasDelegate: AnyObject {
    /// Called after every mutation of the committed annotation list.
    func annotationCanvas(_ canvas: AnnotationCanvas, didUpdate document: AnnotationsDocument)
}

/// AppKit canvas — draws the master + live annotations + a transient preview
/// shape for the in-flight gesture. Commits new annotations to its
/// `document` on mouseUp.
@MainActor
public final class AnnotationCanvas: NSView {

    /// Immutable source image. Displayed at full resolution scaled into the
    /// view bounds. Never mutated by the canvas.
    public let master: CGImage

    /// Points → master-pixel scale. Defaults to 2 (Retina). Used when
    /// converting mouse events (view-local points) into master-pixel coords.
    public var pointToPixelScale: CGFloat

    /// Committed annotations. Publishable via `delegate`.
    public private(set) var document: AnnotationsDocument {
        didSet { delegate?.annotationCanvas(self, didUpdate: document) }
    }

    /// Currently-selected tool.
    public var tool: AnnotationTool = .arrow

    /// Text to insert when the active tool is `.text`. The inspector writes
    /// this before committing the next tap.
    public var pendingText: String = ""

    /// Delegate receives updates on every commit.
    public weak var delegate: AnnotationCanvasDelegate?

    /// Point currently under an in-flight drag, in master-pixel space. Nil
    /// when idle. Exposed for tests.
    public private(set) var dragStartPixel: CGPoint?
    public private(set) var dragCurrentPixel: CGPoint?

    public init(
        master: CGImage,
        pointToPixelScale: CGFloat = 2.0,
        document: AnnotationsDocument = AnnotationsDocument()
    ) {
        self.master = master
        self.pointToPixelScale = pointToPixelScale
        self.document = document
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: CGFloat(master.width) / pointToPixelScale,
            height: CGFloat(master.height) / pointToPixelScale
        ))
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Interface Builder not supported for AnnotationCanvas")
    }

    public override var isFlipped: Bool { false } // bottom-left origin.
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Fill with the master, scaled to view bounds (view is in points,
        // master is in pixels; CGContext handles the scaling).
        ctx.interpolationQuality = .high
        ctx.draw(master, in: bounds)

        // In-view drawing is in point space, but the shared draw core expects
        // master-pixel space. We scale the CTM so that 1 point = 1 master
        // pixel, then call the shared helper.
        ctx.scaleBy(x: 1.0 / pointToPixelScale, y: 1.0 / pointToPixelScale)

        drawAnnotationsPreview(
            into: ctx,
            master: master,
            items: document.items,
            pointToPixelScale: pointToPixelScale
        )

        // Transient preview for the in-flight gesture.
        if let a = dragStartPixel, let b = dragCurrentPixel {
            drawTransientPreview(ctx: ctx, tool: tool, from: a, to: b, scale: pointToPixelScale)
        }
    }

    // MARK: Mouse handling

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let pixel = CGPoint(x: p.x * pointToPixelScale, y: p.y * pointToPixelScale)

        if tool == .text {
            // Text is a single-click tool. Commit immediately so the user can
            // type-and-move.
            guard !pendingText.isEmpty else { return }
            let item = Annotation.Text(
                at: Point(pixel),
                string: pendingText,
                font: .systemBody,
                color: .defaultArrow
            )
            document.items.append(.text(item))
            needsDisplay = true
            return
        }

        dragStartPixel = pixel
        dragCurrentPixel = pixel
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragStartPixel != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragCurrentPixel = CGPoint(x: p.x * pointToPixelScale, y: p.y * pointToPixelScale)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard let start = dragStartPixel else { return }
        let p = convert(event.locationInWindow, from: nil)
        let end = CGPoint(x: p.x * pointToPixelScale, y: p.y * pointToPixelScale)
        dragStartPixel = nil
        dragCurrentPixel = nil

        switch tool {
        case .arrow:
            let item = Annotation.Arrow(
                from: Point(start),
                to: Point(end),
                color: .defaultArrow,
                width: AnnotationDefaults.arrowWidthPoints
            )
            document.items.append(.arrow(item))
        case .blurRect:
            let r = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
            if r.width > 0, r.height > 0 {
                let item = Annotation.BlurRect(
                    rect: Rect(r),
                    sigma: AnnotationDefaults.blurSigmaPoints
                )
                document.items.append(.blurRect(item))
            }
        case .text:
            // Handled in mouseDown; nothing to commit here.
            break
        }
        needsDisplay = true
    }

    // MARK: Hit testing (exposed for tests)

    /// Returns the top-most annotation whose bounding box contains `pixel`
    /// (master-pixel space), or nil if none. Used by tests and future
    /// selection UI.
    public func annotationHit(at pixel: CGPoint) -> Annotation? {
        for item in document.items.reversed() {
            switch item {
            case .arrow(let a):
                let r = CGRect(
                    x: min(a.from.x, a.to.x),
                    y: min(a.from.y, a.to.y),
                    width: abs(a.from.x - a.to.x),
                    height: abs(a.from.y - a.to.y)
                ).insetBy(dx: -8, dy: -8)
                if r.contains(pixel) { return item }
            case .blurRect(let b):
                if b.rect.cgRect.contains(pixel) { return item }
            case .text(let t):
                let approx = CGRect(
                    x: t.at.x,
                    y: t.at.y,
                    width: CGFloat(t.string.count) * CGFloat(t.font.size) * 0.6,
                    height: CGFloat(t.font.size) * 1.2
                )
                if approx.contains(pixel) { return item }
            }
        }
        return nil
    }
}

/// Shared preview helper. Public so the (headless) tests can assert that the
/// canvas preview goes through the same code path as the exported render.
/// Internally delegates to the renderer's draw core via the bridge below.
///
/// Lives at module scope (not inside `AnnotationCanvas`) so it's callable
/// from non-main-actor contexts; the caller is responsible for the `ctx`'s
/// thread affinity.
public func drawAnnotationsPreview(
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

/// In-flight drag preview. Not committed to `document`; drawn directly each
/// frame in the canvas's `draw(_:)`.
private func drawTransientPreview(
    ctx: CGContext,
    tool: AnnotationTool,
    from: CGPoint,
    to: CGPoint,
    scale: CGFloat
) {
    switch tool {
    case .arrow:
        let preview = Annotation.Arrow(
            from: Point(from),
            to: Point(to),
            color: .defaultArrow,
            width: AnnotationDefaults.arrowWidthPoints
        )
        AnnotationDrawCore.shared.drawArrow(ctx: ctx, arrow: preview, scale: scale)
    case .blurRect:
        // Draw a dashed outline — we don't actually blur during drag because
        // the operation is expensive; the commit in mouseUp runs it once.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(Color.defaultArrow.cgColor)
        ctx.setLineWidth(1 * scale)
        ctx.setLineDash(phase: 0, lengths: [4 * scale, 4 * scale])
        let r = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(from.x - to.x),
            height: abs(from.y - to.y)
        )
        ctx.stroke(r)
    case .text:
        break
    }
}

#endif
