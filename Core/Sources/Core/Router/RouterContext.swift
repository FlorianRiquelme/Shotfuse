// Core/Sources/Core/Router/RouterContext.swift
import Foundation

/// A context object supplied by the `CaptureCoordinator` at decision time,
/// providing all necessary information for the `Router` to make a prediction
/// about the capture's destination.
///
/// This struct is `Sendable` and `Codable` for safe, concurrent access and
/// potential serialization. It deliberately avoids reference types to
/// ensure immutability and thread safety.
///
/// - SeeAlso: §4 vocabulary
public struct RouterContext: Sendable, Codable, Equatable {
    /// A unique identifier for the capture event, typically a UUIDv7.
    public let id: String
    /// The bundle identifier of the frontmost application at the time of capture.
    public let bundleID: String?
    /// The title of the window being captured, if applicable.
    public let windowTitle: String?
    /// The `URL` of the Git repository root if the frontmost application
    /// is within a Git-managed project. `nil` otherwise.
    public let gitRoot: URL?
    /// A boolean indicating whether the frontmost application is capable of
    /// handling Obsidian URL schemes (e.g., if Obsidian is running and configured).
    /// May be `nil` if the host cannot detect this information.
    public let frontmostHasObsidianURL: Bool?
    /// The user's home directory.
    public let homeDirectory: URL
    /// The user's default projects directory. Defaults to `$HOME/Projects`.
    public let projectsDirectory: URL

    /// The last path component of `gitRoot`, which acts as the project's
    /// short name for destinations like `.projectScreenshots`. Nil if
    /// `gitRoot` is nil.
    public var gitRootBasename: String? { gitRoot?.lastPathComponent }

    public init(
        id: String,
        bundleID: String?,
        windowTitle: String?,
        gitRoot: URL?,
        frontmostHasObsidianURL: Bool?,
        homeDirectory: URL,
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
    ) {
        self.id = id
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.gitRoot = gitRoot
        self.frontmostHasObsidianURL = frontmostHasObsidianURL
        self.homeDirectory = homeDirectory
        self.projectsDirectory = projectsDirectory
    }
}
