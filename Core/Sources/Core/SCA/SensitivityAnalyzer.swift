import CoreGraphics
import Foundation
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif

// MARK: - Tags (SPEC §6.1 / §13.4)

/// Categories surfaced in `manifest.json.sensitivity`.
///
/// SPEC §6.1 defines the allowed values: any of `nudity`, `password_field`,
/// `card_number`, or the singleton `none`. We model these as an ordered enum
/// so callers can pattern-match and persist stable raw strings.
public enum SensitivityTag: String, Codable, Sendable, Equatable, CaseIterable {
    case nudity
    case password_field
    case card_number
    /// Singleton marker: no sensitive content detected. When present it MUST
    /// be the only tag in the array (see SPEC §13.4).
    case none
}

// MARK: - Analyzer protocol

/// Abstraction over `SCSensitivityAnalyzer` so tests can stub results without
/// triggering the real framework (which requires `SCSensitivityAnalysisPolicy`
/// to be enabled in System Settings).
///
/// Conforming implementations MUST be `Sendable` — they may be invoked from
/// any actor context. They MUST also return `[.none]` (and only `[.none]`)
/// when no sensitive content was detected; callers rely on that invariant
/// to merge a well-formed `sensitivity` array into the manifest.
public protocol SensitivityAnalyzing: Sendable {
    /// Analyze a `CGImage` in memory. Preferred in tests.
    func analyze(_ image: CGImage) async throws -> [SensitivityTag]

    /// Analyze a `master.png` on disk. Preferred in production — avoids
    /// re-decoding the pixels the capture engine already wrote.
    func analyze(fileURL: URL) async throws -> [SensitivityTag]
}

// MARK: - Errors

public enum SensitivityAnalyzerError: Error, Sendable, Equatable {
    /// Framework call returned an error we could not map to a tag.
    case frameworkError(String)
    /// Device policy is `Disabled` — analyzer cannot run. Callers should
    /// treat this as "sensitivity analysis unavailable" (SPEC §13.4 implicitly
    /// allows the array to be omitted when unavailable; in-line we return
    /// `[.none]` to keep the manifest shape stable).
    case policyDisabled
}

// MARK: - Real (framework-backed) analyzer

/// Production `SensitivityAnalyzing` implementation backed by
/// `SCSensitivityAnalyzer` (macOS 14+).
///
/// NOTE on granularity: Apple's public API only exposes an
/// `SCSensitivityAnalysis.isSensitive` boolean (see SDK header); it does NOT
/// return per-category information. To honor SPEC §6.1's tag vocabulary we
/// map a positive result to a single configurable tag (default `.nudity`,
/// matching the family of content the framework is documented to detect).
/// More granular classification is left to post-v0.1 work when Apple ships
/// per-category APIs — today the contract is "one bit of sensitivity".
#if canImport(SensitiveContentAnalysis)
@available(macOS 14.0, *)
public struct RealSensitivityAnalyzer: SensitivityAnalyzing {
    /// Tag applied when `SCSensitivityAnalysis.isSensitive == true`.
    /// Defaults to `.nudity` (the framework's documented detection target).
    public let positiveTag: SensitivityTag

    public init(positiveTag: SensitivityTag = .nudity) {
        self.positiveTag = positiveTag
    }

    public func analyze(_ image: CGImage) async throws -> [SensitivityTag] {
        let analyzer = SCSensitivityAnalyzer()
        if analyzer.analysisPolicy == .disabled {
            throw SensitivityAnalyzerError.policyDisabled
        }
        let result: SCSensitivityAnalysis
        do {
            result = try await analyzer.analyzeImage(image)
        } catch {
            throw SensitivityAnalyzerError.frameworkError(error.localizedDescription)
        }
        return result.isSensitive ? [positiveTag] : [.none]
    }

    public func analyze(fileURL: URL) async throws -> [SensitivityTag] {
        let analyzer = SCSensitivityAnalyzer()
        if analyzer.analysisPolicy == .disabled {
            throw SensitivityAnalyzerError.policyDisabled
        }
        let result: SCSensitivityAnalysis
        do {
            result = try await analyzer.analyzeImage(at: fileURL)
        } catch {
            throw SensitivityAnalyzerError.frameworkError(error.localizedDescription)
        }
        return result.isSensitive ? [positiveTag] : [.none]
    }
}
#endif

// MARK: - Stub analyzer (for tests / TCC-free environments)

/// Test/CI-friendly `SensitivityAnalyzing` that returns a canned tag list.
///
/// The stub is `Sendable`: it captures its canned response by value. Use one
/// instance per scenario — e.g. `StubSensitivityAnalyzer(tags: [.password_field])`.
public struct StubSensitivityAnalyzer: SensitivityAnalyzing {
    public let tags: [SensitivityTag]

    public init(tags: [SensitivityTag]) {
        // Normalize per SPEC §13.4: empty list → `[.none]`.
        if tags.isEmpty {
            self.tags = [.none]
        } else {
            self.tags = tags
        }
    }

    public func analyze(_ image: CGImage) async throws -> [SensitivityTag] {
        tags
    }

    public func analyze(fileURL: URL) async throws -> [SensitivityTag] {
        tags
    }
}
