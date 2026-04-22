import CoreGraphics
import Foundation
#if canImport(Vision)
import Vision
#endif

// MARK: - OCR payload shape (SPEC §6.3)

/// Encodable projection of `ocr.json` per SPEC §6.3:
///
///     { "vision_version": string,
///       "locale_hints":  [string],
///       "results": [ { "text": string,
///                      "bbox": [x, y, w, h],   // master-pixel space
///                      "confidence": 0..1,
///                      "lang": string } ] }
///
/// Bounding boxes are in master-pixel space with origin at the top-left of the
/// image (Vision hands us normalized rects with bottom-left origin; we flip in
/// `OCRRecognizer.recognize` before encoding).
public struct OCRPayload: Codable, Equatable, Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public let text: String
        public let bbox: [Int]      // [x, y, w, h]
        public let confidence: Double
        public let lang: String

        public init(text: String, bbox: [Int], confidence: Double, lang: String) {
            self.text = text
            self.bbox = bbox
            self.confidence = confidence
            self.lang = lang
        }
    }

    public let vision_version: String
    public let locale_hints: [String]
    public let results: [Result]

    public init(vision_version: String, locale_hints: [String], results: [Result]) {
        self.vision_version = vision_version
        self.locale_hints = locale_hints
        self.results = results
    }

    /// Concatenation of every result's `text` joined by newlines. Used to feed
    /// `captures_fts.ocr_text` at index-insert time.
    public var concatenatedText: String {
        results.map(\.text).joined(separator: "\n")
    }
}

// MARK: - OCRRecognizer

/// Thin wrapper around `VNRecognizeTextRequest` that produces an `OCRPayload`
/// for a `CGImage`. The capture pipeline runs this synchronously inside
/// `CaptureFinalization.finalize` so `ocr.json` ships alongside `master.png` in
/// the atomic package write (SPEC §2 Weekend 1 DoD).
///
/// SPEC §6.3 calls OCR "best-effort async" — running it inline is a deliberate
/// v0.1 simplification to satisfy the Weekend 1 DoD contract that `ocr.json`
/// MUST exist in every `.shot/` package. Background re-OCR / queue scheduling
/// remains a post-v0.1 concern.
public enum OCRRecognizer {

    /// Matches the `vision_version` emitted in `ocr.json`.
    public static let visionVersion = "macos26.vision.2"

    /// Default locale hints applied to every Vision request in v0.1.
    public static let defaultLocaleHints = ["en-US"]

    /// Runs text recognition on `image` and returns an `OCRPayload` whose
    /// `bbox`es are in master-pixel space with top-left origin.
    ///
    /// Never throws — Vision errors are swallowed and surfaced as an empty
    /// `results` list so the capture path never fails because OCR failed
    /// (SPEC §13.4 "best-effort" principle, applied here to keep the
    /// finalize path atomic even when Vision is flaky).
    public static func recognize(
        image: CGImage,
        localeHints: [String] = defaultLocaleHints
    ) -> OCRPayload {
        #if canImport(Vision)
        let width = image.width
        let height = image.height

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !localeHints.isEmpty {
            request.recognitionLanguages = localeHints
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Swallow — best-effort.
            return OCRPayload(
                vision_version: visionVersion,
                locale_hints: localeHints,
                results: []
            )
        }

        let observations = (request.results ?? [])
        var results: [OCRPayload.Result] = []
        results.reserveCapacity(observations.count)
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            if text.isEmpty { continue }

            // Vision normalized coords: origin bottom-left, range [0,1].
            // Flip y so the emitted bbox uses top-left origin (SPEC §6.3
            // "master-pixel space").
            let rect = obs.boundingBox
            let x = Int((rect.origin.x * CGFloat(width)).rounded())
            let w = Int((rect.size.width * CGFloat(width)).rounded())
            let h = Int((rect.size.height * CGFloat(height)).rounded())
            let yBottomLeft = rect.origin.y * CGFloat(height)
            let y = Int((CGFloat(height) - yBottomLeft - CGFloat(h)).rounded())

            let lang = localeHints.first ?? "en-US"
            results.append(
                OCRPayload.Result(
                    text: text,
                    bbox: [max(0, x), max(0, y), max(0, w), max(0, h)],
                    confidence: Double(candidate.confidence),
                    lang: lang
                )
            )
        }

        return OCRPayload(
            vision_version: visionVersion,
            locale_hints: localeHints,
            results: results
        )
        #else
        return OCRPayload(
            vision_version: visionVersion,
            locale_hints: localeHints,
            results: []
        )
        #endif
    }

    /// Convenience wrapper that returns a JSON-encoded `ocr.json` body, ready
    /// to hand to `ShotPackageWriter`.
    public static func recognizeJSON(
        image: CGImage,
        localeHints: [String] = defaultLocaleHints
    ) throws -> Data {
        let payload = recognize(image: image, localeHints: localeHints)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }
}
