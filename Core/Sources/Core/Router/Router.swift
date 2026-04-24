import Foundation
import os

// CC_SHA256 is part of CommonCrypto, which is usually available on Apple platforms.
// Imported here (rather than at the bottom of the file) so the `extension String`
// redaction helper below can call it. This conditional import keeps the file
// portable to hypothetical non-Apple environments.
#if canImport(CommonCrypto)
import CommonCrypto
#else
#error("CommonCrypto not available")
#endif

/// Protocol for opening Obsidian URLs, abstracting `NSWorkspace.open(_:)` for Core.
///
/// - Tag: ObsidianOpener
public protocol ObsidianOpener: Sendable {
    func open(_ url: URL) async throws
}

/// Protocol for interacting with the file system, abstracting operations for testability.
///
/// - Tag: FileSystemProbe
public protocol FileSystemProbe: Sendable {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func isWritableFile(atPath path: String) -> Bool
    func isWritableDirectory(atPath path: String) -> Bool
    func currentDirectoryURL() -> URL
    func homeDirectoryForCurrentUser() -> URL
    func removeItem(at url: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func fileSize(at url: URL) throws -> UInt64
    func fileHandle(forWritingTo url: URL) throws -> FileHandle
    func fileHandle(forUpdating url: URL) throws -> FileHandle
}

/// Default implementation of `FileSystemProbe` using `FileManager`.
///
/// - Tag: DefaultFileSystemProbe
public struct DefaultFileSystemProbe: FileSystemProbe {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    public func isWritableFile(atPath path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    public func isWritableDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return FileManager.default.isWritableFile(atPath: path)
            }
        }
        return false
    }

    public func currentDirectoryURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    public func homeDirectoryForCurrentUser() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.moveItem(at: srcURL, to: dstURL)
    }

    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.copyItem(at: srcURL, to: dstURL)
    }

    public func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? UInt64 ?? 0
    }

    public func fileHandle(forWritingTo url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        return try FileHandle(forWritingTo: url)
    }

    public func fileHandle(forUpdating url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        return try FileHandle(forUpdating: url)
    }
}


/// Represents the outcome of a side effect operation after a decision.
///
/// - Tag: RouterSideEffectResult
public enum RouterSideEffectResult: Sendable, Codable, Equatable {
    /// The destination was successfully handled.
    case handled(RouterDestination)
    /// The original destination failed, and the Router fell back to another destination.
    case fellBackToClipboard(reason: FallbackReason)

    public enum FallbackReason: String, Sendable, Codable, Equatable {
        case missingCapture = "missing_capture"
        case notWritable = "destination_not_writable"
        case obsidianOpenFailed = "obsidian_open_failed"
        case unknownError = "unknown_error"

        /// End-user wording for UI surfaces. Keep this path-free and content-free.
        public var humanName: String {
            switch self {
            case .missingCapture: return "capture file missing"
            case .notWritable: return "destination not writable"
            case .obsidianOpenFailed: return "Obsidian unavailable"
            case .unknownError: return "delivery failed"
            }
        }
    }

    /// The destination that actually received the capture after fallback handling.
    public var deliveredDestination: RouterDestination {
        switch self {
        case .handled(let destination): return destination
        case .fellBackToClipboard: return .clipboard
        }
    }

    /// End-user wording for toast / chooser feedback. It deliberately omits paths.
    public var humanName: String {
        switch self {
        case .handled(let destination):
            return destination.humanName
        case .fellBackToClipboard(let reason):
            return "Clipboard (fallback: \(reason.humanName))"
        }
    }
}

/// Represents a single line of telemetry data to be written to the telemetry file.
///
/// - Tag: RouterTelemetryLine
public struct RouterTelemetryLine: Sendable, Codable {
    public let id: String // UUIDv7 from RouterContext
    public let ts: String // ISO-8601 UTC timestamp
    public let predicted: String // slug of top prediction
    public let chosen: String // slug of chosen destination
    public let top_score: Double
    public let second_score: Double

    /// Initializes a `RouterTelemetryLine`.
    ///
    /// - Parameters:
    ///   - id: The UUIDv7 from the `RouterContext`.
    ///   - ts: The ISO-8601 UTC timestamp of the decision.
    ///   - predicted: The slug of the top predicted destination.
    ///   - chosen: The slug of the chosen destination.
    ///   - top_score: The score of the top predicted destination.
    ///   - second_score: The score of the second predicted destination.
    public init(id: String, ts: String, predicted: String, chosen: String, top_score: Double, second_score: Double) {
        self.id = id
        self.ts = ts
        self.predicted = predicted
        self.chosen = chosen
        self.top_score = top_score
        self.second_score = second_score
    }
}

/// Represents the host's decision regarding the Router's prediction.
///
/// - Tag: RouterHostDecision
public enum RouterHostDecision: Sendable {
    /// The Router's automatic decision (when `shouldAutoDeliver == true`).
    case auto
    /// The user explicitly chose a destination from the 3-option chooser.
    case userChoseFromChooser(RouterDestination)
    /// The user redirected to a destination via Cmd+Z from a toast.
    case userRedirectedViaCmdZ(RouterDestination)
}

/// Represents the final outcome after a Router decision, including the chosen destination
/// and the result of any side effects.
///
/// - Tag: RouterOutcome
public struct RouterOutcome: Sendable {
    public let chosen: RouterDestination
    public let sideEffectResult: RouterSideEffectResult
}

/// The core actor for predicting and deciding capture destinations.
///
/// This actor encapsulates the logic for scoring potential destinations, making a decision
/// (auto-deliver or show chooser), executing side effects, and logging telemetry.
/// It adheres to strict concurrency requirements.
///
/// - Tag: Router
/// - SeeAlso: §4 vocabulary: `Router`
public actor Router {
    private let logger = os.Logger(subsystem: "dev.friquelme.shotfuse", category: "router")
    private let telemetryURL: URL
    private let fileSystem: FileSystemProbe
    private let obsidianOpener: ObsidianOpener
    private let scoringModel = RouterScoringModel()
    private let telemetryEncoder: JSONEncoder

    /// The maximum size for the telemetry file before rotation (10 MB).
    private let telemetryRotationThreshold: UInt64 = 10 * 1024 * 1024 // 10 MB
    /// The number of telemetry file rotations to keep (2 rotations).
    private let telemetryRotationCount: Int = 2 // telemetry.jsonl, telemetry.1.jsonl, telemetry.2.jsonl

    /// Initializes the `Router` actor.
    ///
    /// - Parameters:
    ///   - telemetryDirectory: The directory where telemetry files will be stored (e.g., `~/.shotfuse`).
    ///   - fileSystem: A `FileSystemProbe` conforming object for file system interactions.
    ///   - obsidianOpener: An `ObsidianOpener` conforming object for opening Obsidian URLs.
    public init(telemetryDirectory: URL, fileSystem: FileSystemProbe, obsidianOpener: ObsidianOpener) {
        self.telemetryURL = telemetryDirectory.appendingPathComponent("telemetry.jsonl")
        self.fileSystem = fileSystem
        self.obsidianOpener = obsidianOpener
        self.telemetryEncoder = JSONEncoder()
        self.telemetryEncoder.outputFormatting = .sortedKeys // Ensure stable key order
        self.telemetryEncoder.dateEncodingStrategy = .iso8601 // ISO-8601 for timestamps
    }

    /// Predicts the best destination for a capture based on the provided context.
    ///
    /// This function performs the scoring but does not execute any side effects or make a final decision.
    ///
    /// - Parameter context: The `RouterContext` for the current capture.
    /// - Returns: A `RouterPrediction` containing the top two destinations, their scores, and
    ///            whether auto-delivery is recommended.
    /// - SeeAlso: §7 taxonomy, §7.1 decision rule
    public func predict(_ context: RouterContext) -> RouterPrediction {
        let scoredDestinations = scoringModel.score(context: context)
        let prediction = RouterPrediction(scoredDestinations: scoredDestinations)
        logger.info("Prediction: Top \(prediction.top.dest.logDescription) (\(prediction.top.score)), Second \(prediction.second.dest.logDescription) (\(prediction.second.score)). Auto-deliver: \(prediction.shouldAutoDeliver)")
        return prediction
    }

    /// Makes a final decision about the capture destination and executes side effects.
    ///
    /// - Parameters:
    ///   - context: The `RouterContext` for the current capture.
    ///   - prediction: The `RouterPrediction` made earlier.
    ///   - hostDecision: The decision from the hosting environment (auto, user-chosen, or redirected).
    /// - Returns: A `RouterOutcome` detailing the chosen destination and side effect result.
    /// - Throws: An error if side effects fail critically.
    /// - SeeAlso: §7.1 decision rule
    public func decide(context: RouterContext, prediction: RouterPrediction, hostDecision: RouterHostDecision, packageURL: URL? = nil) async throws -> RouterOutcome {
        let chosenDestination: RouterDestination

        switch hostDecision {
        case .auto:
            chosenDestination = prediction.top.dest
        case .userChoseFromChooser(let dest), .userRedirectedViaCmdZ(let dest):
            chosenDestination = dest
        }

        let sideEffectResult = try await sideEffect(for: chosenDestination, context: context, packageURL: packageURL)

        // Log telemetry after side effect result is known
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)

        let telemetryLine = RouterTelemetryLine(
            id: context.id,
            ts: timestamp,
            predicted: prediction.top.dest.slug,
            chosen: chosenDestination.slug,
            top_score: prediction.top.score,
            second_score: prediction.second.score
        )
        await appendTelemetry(line: telemetryLine)

        return RouterOutcome(chosen: chosenDestination, sideEffectResult: sideEffectResult)
    }

    /// Executes the side effect for a given destination.
    ///
    /// - Parameters:
    ///   - destination: The `RouterDestination` to handle.
    ///   - context: The `RouterContext` for the current capture.
    /// - Returns: A `RouterSideEffectResult` indicating success or fallback.
    /// - Throws: `Error` if critical file system operations fail for a non-fallback path.
    /// - SeeAlso: §7.3 side-effect policy
    public func sideEffect(for destination: RouterDestination, context: RouterContext, packageURL: URL? = nil) async throws -> RouterSideEffectResult {
        switch destination {
        case .clipboard:
            // Clipboard handling is outside the Router's direct side-effect responsibility,
            // as it's typically handled by the capture engine itself or the UI.
            // Router only "decides" on it.
            logger.info("Side effect: Chosen destination is Clipboard. No direct file system side effect.")
            return .handled(.clipboard)

        case .projectScreenshots(let gitRootName):
            guard let gitRoot = context.gitRoot else {
                logger.error("Side effect: Project screenshots chosen but gitRoot is nil. Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .unknownError)
            }
            guard let packageURL else {
                logger.error("Side effect: Project screenshots chosen but capture package URL is nil. Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .missingCapture)
            }
            let masterURL = packageURL.appendingPathComponent("master.png")
            guard fileSystem.fileExists(atPath: masterURL.path) else {
                logger.error("Side effect: Project screenshots source master missing: \(masterURL.path.sha256Prefix). Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .missingCapture)
            }
            let targetDirectory = gitRoot.appendingPathComponent("screenshots", isDirectory: true)

            do {
                if !fileSystem.fileExists(atPath: targetDirectory.path) {
                    try fileSystem.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
                    logger.info("Side effect: Created directory for project screenshots: \(targetDirectory.path.sha256Prefix)")
                }

                guard fileSystem.isWritableDirectory(atPath: targetDirectory.path) else {
                    logger.error("Side effect: Project screenshots directory not writable: \(targetDirectory.path.sha256Prefix). Falling back to Clipboard.")
                    return .fellBackToClipboard(reason: .notWritable)
                }

                let targetFile = uniqueExportURL(in: targetDirectory, id: context.id, fileExtension: "png")
                try fileSystem.copyItem(at: masterURL, to: targetFile)
                logger.info("Side effect: Copied capture to project screenshots for \(gitRootName.sha256Prefix) at \(targetDirectory.path.sha256Prefix)")
                return .handled(.projectScreenshots(gitRootName: gitRootName))

            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
                logger.error("Side effect: Project screenshots permission denied: \(targetDirectory.path.sha256Prefix). Error: \(error.localizedDescription). Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .notWritable)
            } catch {
                logger.error("Side effect: Failed to deliver to project screenshots \(targetDirectory.path.sha256Prefix). Error: \(error.localizedDescription). Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .unknownError)
            }

        case .obsidianDaily:
            guard let packageURL else {
                logger.error("Side effect: Obsidian daily chosen but capture package URL is nil. Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .missingCapture)
            }
            let masterURL = packageURL.appendingPathComponent("master.png")
            guard fileSystem.fileExists(atPath: masterURL.path) else {
                logger.error("Side effect: Obsidian source master missing: \(masterURL.path.sha256Prefix). Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .missingCapture)
            }
            let obsidianURL = obsidianDailyAppendURL(masterURL: masterURL)
            do {
                try await obsidianOpener.open(obsidianURL)
                logger.info("Side effect: Delivered capture link to Obsidian daily note.")
                return .handled(.obsidianDaily)
            } catch {
                let errorType = String(describing: type(of: error))
                logger.error("Side effect: Failed to open Obsidian URL. Error type: \(errorType, privacy: .public). Falling back to Clipboard.")
                return .fellBackToClipboard(reason: .obsidianOpenFailed)
            }
        }
    }

    /// Returns a non-existing `<id>.ext` URL in the destination directory.
    /// If the id already exists (for example after a user redirects twice), a
    /// numeric suffix keeps routing append-only and avoids destructive overwrite.
    private func uniqueExportURL(in directory: URL, id: String, fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
        var suffix = 1
        while fileSystem.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(id)-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    /// Builds the official Obsidian daily-note URI with appendable markdown
    /// content. The appended content links to the immutable `master.png` inside
    /// the `.shot/` package, which keeps Router from writing into arbitrary vaults
    /// while still delivering the capture into the daily-note workflow.
    private func obsidianDailyAppendURL(masterURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "daily"
        components.queryItems = [
            URLQueryItem(name: "append", value: "true"),
            URLQueryItem(name: "content", value: "\n![](\(masterURL.absoluteString))\n")
        ]
        return components.url ?? URL(string: "obsidian://daily")!
    }

    /// Appends a telemetry line to `telemetry.jsonl` and manages file rotation.
    ///
    /// - Parameter line: The `RouterTelemetryLine` to append.
    /// - SeeAlso: §13.5 telemetry
    public func appendTelemetry(line: RouterTelemetryLine) async {
        do {
            try await rotateTelemetryFileIfNeeded()

            let data = try telemetryEncoder.encode(line)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logger.error("Telemetry: Failed to convert encoded JSON to string.")
                return
            }

            let lineWithNewline = (jsonString + "\n").data(using: .utf8)!

            let fileHandle = try fileSystem.fileHandle(forUpdating: telemetryURL)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: lineWithNewline)
            try fileHandle.synchronize()
            try fileHandle.close()

            logger.debug("Telemetry: Appended line for ID \(line.id.sha256Prefix)")

        } catch {
            logger.error("Telemetry: Failed to append line: \(error.localizedDescription)")
        }
    }

    /// Manages rotation of the telemetry file if it exceeds the `telemetryRotationThreshold`.
    /// Keeps `telemetryRotationCount` (2) rotations.
    private func rotateTelemetryFileIfNeeded() async throws {
        if fileSystem.fileExists(atPath: telemetryURL.path) {
            let currentSize = try fileSystem.fileSize(at: telemetryURL)
            if currentSize >= telemetryRotationThreshold {
                logger.info("Telemetry: Rotating telemetry file. Current size: \(currentSize) bytes.")

                // Delete oldest rotation (telemetry.2.jsonl)
                let oldestsURL = telemetryURL.deletingPathExtension().appendingPathExtension("2.jsonl")
                if fileSystem.fileExists(atPath: oldestsURL.path) {
                    try fileSystem.removeItem(at: oldestsURL)
                    logger.debug("Telemetry: Removed \(oldestsURL.lastPathComponent)")
                }

                // Move telemetry.1.jsonl to telemetry.2.jsonl
                let olderURL = telemetryURL.deletingPathExtension().appendingPathExtension("1.jsonl")
                if fileSystem.fileExists(atPath: olderURL.path) {
                    try fileSystem.moveItem(at: olderURL, to: oldestsURL)
                    logger.debug("Telemetry: Moved \(olderURL.lastPathComponent) to \(oldestsURL.lastPathComponent)")
                }

                // Move telemetry.jsonl to telemetry.1.jsonl
                try fileSystem.moveItem(at: telemetryURL, to: olderURL)
                logger.debug("Telemetry: Moved \(self.telemetryURL.lastPathComponent) to \(olderURL.lastPathComponent)")

                // Create a new empty telemetry.jsonl
                _ = try fileSystem.fileHandle(forWritingTo: telemetryURL) // Creates or truncates
                logger.info("Telemetry: New \(self.telemetryURL.lastPathComponent) created.")
            }
        }
    }
}

// MARK: - Redaction Helpers
extension String {
    /// Returns the first 8 characters of the SHA256 hash of the string for redaction purposes.
    ///
    /// - SeeAlso: §17.2 redaction
    fileprivate var sha256Prefix: String {
        guard let data = self.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined() // Shorten to 8 hex chars
    }
}


