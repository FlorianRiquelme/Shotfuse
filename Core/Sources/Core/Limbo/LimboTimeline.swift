import Foundation

// Headless visibility state machine for the Limbo HUD.
//
// SPEC §4 — the HUD is visible for 2–8 seconds after a capture. The lower
// bound guarantees the user has enough time to see the capture; the upper
// bound is the hard ceiling before the capture auto-commits to whatever
// Router chose. Mouseover "refreshes" the timeline back to the minimum
// window so hovering acts as a non-intrusive "hold".
//
// This type is a pure value computation: it takes (start, now, last
// mouseover) and returns remaining visibility. No AppKit, no timers. The
// controller polls it; tests drive it deterministically with fixed dates.

/// Bounds for the Limbo visibility window per SPEC §4.
public enum LimboTimelineBounds {
    /// Minimum visibility window — 2s. Any refresh resets the countdown
    /// to at least this.
    public static let minSeconds: TimeInterval = 2.0
    /// Hard ceiling — 8s. No activity can extend past this from the
    /// original `start` instant.
    public static let maxSeconds: TimeInterval = 8.0
}

/// Pure, value-typed visibility state computed for a given instant.
public struct LimboTimeline: Sendable, Equatable {
    /// When the HUD first became visible (capture finalization instant).
    public let start: Date
    /// Most recent mouseover event, if any. `nil` before the first hover.
    public let lastMouseoverAt: Date?

    public init(start: Date, lastMouseoverAt: Date? = nil) {
        self.start = start
        self.lastMouseoverAt = lastMouseoverAt
    }

    /// Records a new mouseover at `at`. Returns a new timeline — the type
    /// is a value, callers own the latest instance.
    public func refreshed(at instant: Date) -> LimboTimeline {
        LimboTimeline(start: start, lastMouseoverAt: instant)
    }

    /// Seconds of visibility remaining at `now`. Zero means "hide".
    ///
    /// Rule (SPEC §4):
    ///   - If `now - start >= 8s` → 0 (hard ceiling).
    ///   - Else: the baseline deadline is `start + 2s`. A mouseover at
    ///     `t` extends the deadline to `t + 2s`, but never past
    ///     `start + 8s`. Remaining = `effectiveDeadline - now`, floored
    ///     at 0.
    public func remainingSeconds(at now: Date) -> TimeInterval {
        let elapsedSinceStart = now.timeIntervalSince(start)

        // Hard ceiling — nothing can extend past this.
        if elapsedSinceStart >= LimboTimelineBounds.maxSeconds {
            return 0
        }

        // Baseline deadline: start + min window.
        let baselineDeadline = start.addingTimeInterval(LimboTimelineBounds.minSeconds)
        // Mouseover deadline: last hover + min window, if any.
        let hoverDeadline = lastMouseoverAt?.addingTimeInterval(LimboTimelineBounds.minSeconds)
        let hardCeiling = start.addingTimeInterval(LimboTimelineBounds.maxSeconds)

        // Effective deadline is the latest of baseline and hover, capped
        // at the hard ceiling.
        var effective = baselineDeadline
        if let h = hoverDeadline, h > effective {
            effective = h
        }
        if effective > hardCeiling {
            effective = hardCeiling
        }

        let remaining = effective.timeIntervalSince(now)
        return remaining > 0 ? remaining : 0
    }

    /// Convenience — `true` iff the HUD should still be on screen at
    /// `now`.
    public func isVisible(at now: Date) -> Bool {
        remainingSeconds(at: now) > 0
    }
}
