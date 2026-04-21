import CryptoKit
import Foundation

// MARK: - Errors

public enum WitnessHashError: Error, Equatable, Sendable {
    /// The input manifest bytes were not valid JSON or did not decode to a
    /// JSON object (the only top-level shape SPEC §6.1 allows).
    case invalidManifestJSON(String)
    /// The manifest contained a value shape that the canonical-JSON emitter
    /// cannot serialize (should not happen for SPEC-conformant manifests).
    case unsupportedValueShape(String)
}

// MARK: - WitnessHash

/// Pure implementation of the SPEC §13.6 witness hash formula:
///
/// ```text
/// SHA-256( SHA-256(master_png_bytes)
///        || canonical_json(manifest without `witness` field)
///        || captured_at_utf8_bytes )
/// ```
///
/// The digest is returned as a hex-lowercase `String`.
///
/// "canonical_json" here means: JSON with object keys sorted lexicographically
/// at every nesting level, no insignificant whitespace, UTF-8 encoded. This
/// matches what external verifiers (shell scripts, small Python utilities)
/// can reproduce with minimal effort — deliberately simpler than JCS
/// (RFC 8785) to keep the v0.1 integrity layer self-contained.
///
/// The function is pure (no I/O, no randomness) so tests can pin it byte-for-byte.
public enum WitnessHash {

    // MARK: Public API

    /// Computes the witness hash for the given master PNG bytes, manifest JSON
    /// bytes, and captured-at ISO-8601 string.
    ///
    /// - Parameters:
    ///   - masterPNG: Raw `master.png` bytes.
    ///   - manifestJSON: The full `manifest.json` bytes. May contain a
    ///     `witness` key — this function strips it before canonicalizing.
    ///   - capturedAt: ISO-8601 UTC string (SPEC §6.1 `manifest.created_at`);
    ///     hashed as its UTF-8 representation.
    /// - Returns: SHA-256 digest, hex-lowercase.
    public static func compute(
        masterPNG: Data,
        manifestJSON: Data,
        capturedAt: String
    ) throws -> String {
        // 1. Inner hash: SHA-256 of the master PNG bytes.
        let innerDigest = SHA256.hash(data: masterPNG)
        let innerBytes = Data(innerDigest)

        // 2. Canonical JSON of the manifest with `witness` stripped.
        let stripped = try manifestWithoutWitnessField(manifestJSON)
        let canonicalBytes = try canonicalJSONBytes(from: stripped)

        // 3. UTF-8 bytes of captured_at.
        let tsBytes = Data(capturedAt.utf8)

        // 4. Concatenate and hash.
        var buf = Data()
        buf.reserveCapacity(innerBytes.count + canonicalBytes.count + tsBytes.count)
        buf.append(innerBytes)
        buf.append(canonicalBytes)
        buf.append(tsBytes)
        let outer = SHA256.hash(data: buf)
        return hexLowercase(outer)
    }

    /// Computes `canonical_json(manifest without `witness`)` — exposed so
    /// tests can assert canonicalization directly.
    public static func canonicalManifestBytes(_ manifestJSON: Data) throws -> Data {
        let stripped = try manifestWithoutWitnessField(manifestJSON)
        return try canonicalJSONBytes(from: stripped)
    }

    // MARK: - Manifest stripping

    /// Parses `manifestJSON`, removes the top-level `witness` key if present,
    /// and returns the resulting `Any` tree suitable for canonical emission.
    static func manifestWithoutWitnessField(_ manifestJSON: Data) throws -> Any {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(
                with: manifestJSON,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw WitnessHashError.invalidManifestJSON(error.localizedDescription)
        }
        guard var obj = parsed as? [String: Any] else {
            throw WitnessHashError.invalidManifestJSON(
                "top-level JSON value is not an object"
            )
        }
        obj.removeValue(forKey: "witness")
        return obj
    }

    // MARK: - Canonical JSON emitter
    //
    // Emits JSON with:
    //   * Object keys sorted lexicographically (Swift's default String ordering —
    //     UTF-8 byte order, which is also codepoint order for BMP chars).
    //   * No whitespace between tokens.
    //   * Strings escaped per RFC 8259 §7 (double-quote, backslash, control
    //     characters; other bytes passed through as UTF-8).
    //   * Numbers rendered via `JSONSerialization` against a single-element
    //     array to reuse its numeric formatter exactly — this keeps integer
    //     and double rendering consistent with the rest of the codebase.
    //   * `true`, `false`, `null` emitted as-is.

    static func canonicalJSONBytes(from value: Any) throws -> Data {
        var out = Data()
        try appendCanonical(value, to: &out)
        return out
    }

    private static func appendCanonical(_ value: Any, to out: inout Data) throws {
        // NSNull → null.
        if value is NSNull {
            out.append(contentsOf: "null".utf8)
            return
        }

        // Booleans — must be tested BEFORE `NSNumber` because `Bool` bridges
        // to `NSNumber` and would otherwise render as `1` / `0`.
        if let b = value as? Bool, isExactlyBool(value) {
            out.append(contentsOf: (b ? "true" : "false").utf8)
            return
        }

        // Strings.
        if let s = value as? String {
            appendJSONString(s, to: &out)
            return
        }

        // Integers — emitted directly to avoid `1.0` style rendering.
        if let n = value as? NSNumber, !isExactlyBool(value) {
            // Differentiate integer vs floating via objCType. 'c' is Bool on
            // Apple platforms; 'f'/'d' are floats/doubles; everything else
            // (i, s, l, q, I, S, L, Q) is an integer family.
            let type = String(cString: n.objCType)
            if type == "f" || type == "d" {
                appendDouble(n.doubleValue, to: &out)
            } else {
                out.append(contentsOf: n.stringValue.utf8)
            }
            return
        }

        // Arrays.
        if let arr = value as? [Any] {
            out.append(UInt8(ascii: "["))
            for (i, element) in arr.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try appendCanonical(element, to: &out)
            }
            out.append(UInt8(ascii: "]"))
            return
        }

        // Objects — keys sorted lexicographically.
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted()
            out.append(UInt8(ascii: "{"))
            for (i, key) in keys.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                appendJSONString(key, to: &out)
                out.append(UInt8(ascii: ":"))
                try appendCanonical(dict[key] as Any, to: &out)
            }
            out.append(UInt8(ascii: "}"))
            return
        }

        throw WitnessHashError.unsupportedValueShape(
            "cannot canonicalize value of type \(type(of: value))"
        )
    }

    /// Distinguishes `Bool` bridged via `NSNumber` from numeric `NSNumber`.
    /// `JSONSerialization` decodes true/false as `__NSCFBoolean` whose
    /// `objCType` is `"c"`.
    private static func isExactlyBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        let t = String(cString: n.objCType)
        return t == "c" && (n === NSNumber(value: true) || n === NSNumber(value: false))
    }

    /// RFC 8259 string escaping. Appends a JSON-quoted form of `s` to `out`.
    private static func appendJSONString(_ s: String, to out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":
                out.append(contentsOf: "\\\"".utf8)
            case "\\":
                out.append(contentsOf: "\\\\".utf8)
            case "\u{08}":
                out.append(contentsOf: "\\b".utf8)
            case "\u{0C}":
                out.append(contentsOf: "\\f".utf8)
            case "\n":
                out.append(contentsOf: "\\n".utf8)
            case "\r":
                out.append(contentsOf: "\\r".utf8)
            case "\t":
                out.append(contentsOf: "\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    // Other C0 controls → \u00XX.
                    let hex = String(format: "\\u%04x", scalar.value)
                    out.append(contentsOf: hex.utf8)
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Double formatter — matches common canonical-JSON renderings:
    /// integral doubles emit without the `.0` suffix (e.g., `72` not `72.0`),
    /// fractional doubles use Swift's default `String(describing:)` output.
    private static func appendDouble(_ d: Double, to out: inout Data) {
        if d.isNaN || d.isInfinite {
            // SPEC §6.1 has no NaN/Inf fields. Fall back to "null" rather
            // than emitting invalid JSON; this path is unreachable for
            // SPEC-conformant manifests.
            out.append(contentsOf: "null".utf8)
            return
        }
        if d == d.rounded() && abs(d) < 1e16 {
            let asInt = Int64(d)
            out.append(contentsOf: String(asInt).utf8)
        } else {
            out.append(contentsOf: String(d).utf8)
        }
    }

    // MARK: - Hex

    private static func hexLowercase<S: Sequence>(_ data: S) -> String
    where S.Element == UInt8 {
        let chars: [Character] = [
            "0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f",
        ]
        var out = String()
        for byte in data {
            out.append(chars[Int(byte >> 4)])
            out.append(chars[Int(byte & 0x0F)])
        }
        return out
    }
}
