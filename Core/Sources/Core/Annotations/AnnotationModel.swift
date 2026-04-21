import CoreGraphics
import Foundation

// Vector annotation model per SPEC §6.4. All coordinates are in master-pixel
// space (SPEC §5 Invariant 6); widths / font sizes / blur sigma are stored in
// points and converted to master-pixels by the renderer using the capture's
// `master.dpi / 72` scale. Rendering is purely additive — the master is read,
// never mutated (Invariant 3).

/// v0.1 annotation tool taxonomy (SPEC §6.4): arrow, text, blur rect.
/// Encoded as a discriminated union keyed by `tool` in `annotations.json`.
public enum Annotation: Sendable, Equatable, Codable {
    case arrow(Arrow)
    case text(Text)
    case blurRect(BlurRect)

    /// Single arrow. `from` / `to` are master-pixel points.
    public struct Arrow: Sendable, Equatable, Codable {
        /// Tail (no arrowhead) in master-pixel space.
        public var from: Point
        /// Tip (arrowhead) in master-pixel space.
        public var to: Point
        /// Stroke color. Defaults to `#FF3B30` per §6.4.
        public var color: Color
        /// Stroke width in points (converted to master-pixel at render).
        public var width: Double

        public init(
            from: Point,
            to: Point,
            color: Color = .defaultArrow,
            width: Double = AnnotationDefaults.arrowWidthPoints
        ) {
            self.from = from
            self.to = to
            self.color = color
            self.width = width
        }
    }

    /// Single text label. `at` is master-pixel baseline origin; `string` is
    /// literal UTF-8 (no markdown / attributed); `font.size` is in points.
    public struct Text: Sendable, Equatable, Codable {
        /// Baseline origin in master-pixel space.
        public var at: Point
        /// UTF-8 string content. Not attributed.
        public var string: String
        /// Logical font. Defaults to system body (§6.4).
        public var font: Font
        /// Text fill color. Defaults to `#FF3B30` per §6.4.
        public var color: Color

        public init(
            at: Point,
            string: String,
            font: Font = .systemBody,
            color: Color = .defaultArrow
        ) {
            self.at = at
            self.string = string
            self.font = font
            self.color = color
        }
    }

    /// Gaussian-blur rectangle. `rect` is in master-pixel space; `sigma` is in
    /// points (converted at render time).
    public struct BlurRect: Sendable, Equatable, Codable {
        /// Region in master-pixel space.
        public var rect: Rect
        /// Gaussian sigma in points. Default 12pt per §6.4.
        public var sigma: Double

        public init(
            rect: Rect,
            sigma: Double = AnnotationDefaults.blurSigmaPoints
        ) {
            self.rect = rect
            self.sigma = sigma
        }
    }

    // MARK: - Codable (discriminated union)

    private enum CodingKeys: String, CodingKey { case tool }

    private enum Tool: String, Codable {
        case arrow
        case text
        case blurRect = "blur_rect"
    }

    public init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: CodingKeys.self)
        let tool = try tag.decode(Tool.self, forKey: .tool)
        let single = try decoder.singleValueContainer()
        switch tool {
        case .arrow:    self = .arrow(try single.decode(ArrowWire.self).payload)
        case .text:     self = .text(try single.decode(TextWire.self).payload)
        case .blurRect: self = .blurRect(try single.decode(BlurRectWire.self).payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .arrow(let a):
            try ArrowWire(payload: a).encode(to: encoder)
        case .text(let t):
            try TextWire(payload: t).encode(to: encoder)
        case .blurRect(let b):
            try BlurRectWire(payload: b).encode(to: encoder)
        }
    }

    // Wire forms embed `tool` as a discriminator while keeping the payload
    // flat so the on-disk JSON reads as
    //   { "tool": "arrow", "from": {...}, "to": {...}, "color": "#FF3B30", "width": 4 }
    private struct ArrowWire: Codable {
        let tool: Tool
        let from: Point
        let to: Point
        let color: Color
        let width: Double

        init(payload: Arrow) {
            self.tool = .arrow
            self.from = payload.from
            self.to = payload.to
            self.color = payload.color
            self.width = payload.width
        }

        var payload: Arrow {
            Arrow(from: from, to: to, color: color, width: width)
        }
    }

    private struct TextWire: Codable {
        let tool: Tool
        let at: Point
        let string: String
        let font: Font
        let color: Color

        init(payload: Text) {
            self.tool = .text
            self.at = payload.at
            self.string = payload.string
            self.font = payload.font
            self.color = payload.color
        }

        var payload: Text {
            Text(at: at, string: string, font: font, color: color)
        }
    }

    private struct BlurRectWire: Codable {
        let tool: Tool
        let rect: Rect
        let sigma: Double

        init(payload: BlurRect) {
            self.tool = .blurRect
            self.rect = payload.rect
            self.sigma = payload.sigma
        }

        var payload: BlurRect {
            BlurRect(rect: rect, sigma: sigma)
        }
    }
}

// MARK: - Primitive value types

/// Master-pixel-space 2D point. Stored as `Double` to avoid platform-specific
/// `CGFloat` size drift inside `annotations.json`.
public struct Point: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public init(_ cg: CGPoint) {
        self.x = Double(cg.x)
        self.y = Double(cg.y)
    }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Master-pixel-space rect. Origin is bottom-left per the rest of the codebase
/// (see `RegionGeometry`); renderer flips into the `CGContext` as needed.
public struct Rect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public init(_ cg: CGRect) {
        self.x = Double(cg.origin.x)
        self.y = Double(cg.origin.y)
        self.width = Double(cg.size.width)
        self.height = Double(cg.size.height)
    }
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 8-bit-per-channel RGBA color, serialized as a 7- or 9-char hex string
/// (`#RRGGBB` or `#RRGGBBAA`). 7-char form is treated as fully opaque.
public struct Color: Sendable, Equatable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// SPEC §6.4 default: `#FF3B30` (Apple's system red).
    public static let defaultArrow = Color(red: 0xFF, green: 0x3B, blue: 0x30)

    // MARK: Codable — hex string

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = Color.parse(hex: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid color hex string: \(s)"
            ))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hexString)
    }

    public var hexString: String {
        if alpha == 255 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    public static func parse(hex: String) -> Color? {
        guard hex.hasPrefix("#") else { return nil }
        let body = String(hex.dropFirst())
        guard body.count == 6 || body.count == 8 else { return nil }
        guard let v = UInt64(body, radix: 16) else { return nil }
        if body.count == 6 {
            return Color(
                red: UInt8((v >> 16) & 0xFF),
                green: UInt8((v >> 8) & 0xFF),
                blue: UInt8(v & 0xFF),
                alpha: 255
            )
        }
        return Color(
            red: UInt8((v >> 24) & 0xFF),
            green: UInt8((v >> 16) & 0xFF),
            blue: UInt8((v >> 8) & 0xFF),
            alpha: UInt8(v & 0xFF)
        )
    }

    /// `CGColor` in device-RGB space.
    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: CGFloat(alpha) / 255.0
        )
    }
}

/// Logical font reference. v0.1 stores the text-style token and a size in
/// points so the renderer can resolve with `NSFont.preferredFont(forTextStyle:)`
/// and override the size to the stored value. Bypasses the system's
/// dynamic-type resolution so renders are deterministic across user
/// accessibility settings.
public struct Font: Sendable, Equatable, Codable {
    public enum Style: String, Sendable, Codable {
        /// `.body` — SPEC §6.4 default for the text tool.
        case body
    }

    public var style: Style
    /// Point size. `.body` resolves to 17pt at default Dynamic Type.
    public var size: Double

    public init(style: Style, size: Double) {
        self.style = style
        self.size = size
    }

    /// System body at its default 17pt size (the SPEC §6.4 default).
    public static let systemBody = Font(style: .body, size: 17.0)
}

// MARK: - Top-level document

/// Root object serialized to `annotations.json`. Version field lets us evolve
/// the renderer without breaking old fixtures (§12 versioned spec deltas).
public struct AnnotationsDocument: Sendable, Equatable, Codable {
    /// Schema version. v0.1 = 1.
    public var specVersion: Int
    /// Ordered list; later items render on top.
    public var items: [Annotation]

    public init(specVersion: Int = AnnotationDefaults.specVersion, items: [Annotation] = []) {
        self.specVersion = specVersion
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case items
    }
}

// MARK: - Defaults

/// Canonical defaults per SPEC §6.4. Centralised so tests can reference the
/// same constants the inspector uses.
public enum AnnotationDefaults {
    /// `annotations.json` schema version.
    public static let specVersion = 1
    /// Arrow stroke width in points. SPEC §6.4.
    public static let arrowWidthPoints: Double = 4
    /// Blur sigma in points. SPEC §6.4.
    public static let blurSigmaPoints: Double = 12
    /// Head half-width as a multiple of stroke width (visual default; not
    /// load-bearing but must stay stable across renders to preserve byte
    /// identity).
    public static let arrowHeadScale: Double = 3
}
