import AppKit
import Core
import Foundation

/// Production `ObsidianOpener` implementation. Delegates to
/// `NSWorkspace.shared.open(_:)` and throws when the system indicates
/// the URL could not be opened (e.g. Obsidian is not installed or has
/// denied the URL scheme).
///
/// Core cannot depend on `NSWorkspace` because the Core module is
/// intentionally UI-free; this adapter lives in the App target and is
/// injected into `Router` at launch.
public struct NSWorkspaceObsidianOpener: ObsidianOpener {

    public init() {}

    public func open(_ url: URL) async throws {
        try await MainActor.run {
            let opened = NSWorkspace.shared.open(url)
            if !opened {
                throw ObsidianOpenError.failedToOpen(url: url)
            }
        }
    }

    /// Typed error surfaced when `NSWorkspace.open` returns `false`.
    public enum ObsidianOpenError: LocalizedError {
        case failedToOpen(url: URL)

        public var errorDescription: String? {
            switch self {
            case .failedToOpen(let url):
                return "Failed to open URL: \(url.absoluteString)"
            }
        }
    }
}
