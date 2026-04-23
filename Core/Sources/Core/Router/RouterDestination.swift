// Core/Sources/Core/Router/RouterDestination.swift
import Foundation

/// Defines the possible destinations for a captured screenshot.
///
/// This enum is `Sendable` and `Codable` for safe, concurrent access and
/// potential serialization. It represents the three exact destinations
/// specified in the Shotfuse taxonomy.
///
/// - SeeAlso: §7 taxonomy
public enum RouterDestination: Sendable, Codable, Equatable, CaseIterable, CustomStringConvertible {
    /// The default fallback destination: the system clipboard.
    case clipboard
    /// A project-specific screenshots directory, identified by the Git root's basename.
    case projectScreenshots(gitRootName: String)
    /// The Obsidian daily note, accessed via its URL scheme.
    case obsidianDaily

    /// A stable, machine-readable slug for each destination, used in telemetry.
    /// - SeeAlso: §13.5 telemetry
    public var slug: String {
        switch self {
        case .clipboard: return "clipboard"
        case .projectScreenshots: return "project_screenshots"
        case .obsidianDaily: return "obsidian_daily"
        }
    }

    /// A redaction-safe description suitable for logging.
    /// Does NOT include actual paths or sensitive information.
    /// - SeeAlso: §17.2 redaction
    public var logDescription: String {
        switch self {
        case .clipboard: return "clipboard"
        case .projectScreenshots(let gitRootName): return "project_screenshots(\"\(gitRootName)\")"
        case .obsidianDaily: return "obsidian_daily"
        }
    }

    public var description: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .projectScreenshots(let gitRootName): return "Project: \(gitRootName)"
        case .obsidianDaily: return "Obsidian Daily Note"
        }
    }

    /// Human-readable label for UI surfaces (toast, chooser). Unlike `description`,
    /// this label is suitable for end-user presentation and kept here so the
    /// wording is testable alongside `.slug` / `.logDescription`.
    public var humanName: String {
        switch self {
        case .clipboard:
            return "Clipboard"
        case .projectScreenshots(let gitRootName):
            return "Project screenshots (\(gitRootName))"
        case .obsidianDaily:
            return "Obsidian daily note"
        }
    }

    /// All possible cases for deterministic testing and iteration.
    public static var allCases: [RouterDestination] {
        // For projectScreenshots, we use a placeholder gitRootName for `allCases`
        // as the actual name is determined at runtime.
        [.clipboard, .projectScreenshots(gitRootName: "placeholder"), .obsidianDaily]
    }
}
