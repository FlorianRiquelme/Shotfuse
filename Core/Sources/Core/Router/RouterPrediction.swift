import Foundation

/// Represents a scoring model for predicting capture destinations based on the provided context.
/// This struct is pure, deterministic, and does not involve randomness.
public struct RouterScoringModel: Sendable {
    private let ideBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Example for a custom app
        "dev.zed.Zed"
    ]

    private let obsidianBundleIDs: Set<String> = [
        "md.obsidian",
        "com.apple.Notes"
    ]

    /// Scores all possible `RouterDestination`s based on the given context.
    ///
    /// - Parameter context: The `RouterContext` containing information about the capture.
    /// - Returns: An array of `(RouterDestination, Double)` tuples, sorted by score (descending),
    ///            with ties broken deterministically (Obsidian, Project, Clipboard).
    func score(context: RouterContext) -> [(dest: RouterDestination, score: Double)] {
        var scoredDestinations: [(dest: RouterDestination, score: Double)] = []

        // 1. Score Clipboard
        let clipboardScore = 0.1
        scoredDestinations.append((dest: .clipboard, score: clipboardScore))

        // 2. Score Project Screenshots only when a real git root exists.
        // Avoid adding an inactive `.projectScreenshots(gitRootName: "")` option;
        // chooser surfaces must never offer a project destination the Router
        // cannot actually deliver to.
        if let gitRootBasename = context.gitRootBasename, !gitRootBasename.isEmpty {
            let projectScreenshotsScore: Double
            if let bundleID = context.bundleID, ideBundleIDs.contains(bundleID) {
                projectScreenshotsScore = 0.95
            } else {
                projectScreenshotsScore = 0.0
            }
            scoredDestinations.append((dest: .projectScreenshots(gitRootName: gitRootBasename), score: projectScreenshotsScore))
        }

        // 3. Score Obsidian Daily
        var obsidianDailyScore = 0.0
        if let bundleID = context.bundleID, obsidianBundleIDs.contains(bundleID) {
            obsidianDailyScore = 0.90
        }
        scoredDestinations.append((dest: .obsidianDaily, score: obsidianDailyScore))

        // Sort by score descending, then by deterministic tie-breaking
        return scoredDestinations.sorted { (item1, item2) in
            if item1.score != item2.score {
                return item1.score > item2.score
            }
            // Tie-breaking: Obsidian > Project Screenshots > Clipboard
            switch (item1.dest, item2.dest) {
            case (.obsidianDaily, _): return true // Obsidian first
            case (_, .obsidianDaily): return false
            case (.projectScreenshots, _): return true // Project Screenshots second
            case (_, .projectScreenshots): return false
            case (.clipboard, _): return true // Clipboard last
            default: return false
            }
        }
    }
}


/// Represents the prediction made by the Router regarding the best destination for a capture.
///
/// - Tag: RouterPrediction
public struct RouterPrediction: Sendable {
    /// The top-scoring destination and its score.
    public let top: (dest: RouterDestination, score: Double)
    /// The second-highest scoring destination and its score.
    public let second: (dest: RouterDestination, score: Double)
    /// The full, sorted list of scored destinations (all three destinations).
    /// Used by the 3-option chooser to render one button per destination.
    ///
    /// - Note: Sorted descending by score with deterministic tie-breaking
    ///   identical to `top` / `second` (Obsidian > Project > Clipboard).
    public let all: [(dest: RouterDestination, score: Double)]
    /// Indicates whether the capture should be auto-delivered based on the decision rule.
    ///
    /// - Tag: RouterPrediction.shouldAutoDeliver
    public let shouldAutoDeliver: Bool

    /// Initializes a `RouterPrediction` from a sorted list of scored destinations.
    ///
    /// - Parameter scoredDestinations: An array of `(RouterDestination, Double)` tuples,
    ///                                 sorted in descending order by score with deterministic tie-breaking.
    public init(scoredDestinations: [(dest: RouterDestination, score: Double)]) {
        guard scoredDestinations.count >= 2 else {
            fatalError("RouterPrediction requires at least two scored destinations.")
        }
        self.top = scoredDestinations[0]
        self.second = scoredDestinations[1]
        self.all = scoredDestinations
        self.shouldAutoDeliver = self.top.score > 0.85 && self.second.score < 0.4
    }
}
