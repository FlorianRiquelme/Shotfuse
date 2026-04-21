import Foundation
import Testing
@testable import Core

#if canImport(AppKit)
import AppKit
#endif

// SPEC §4 Limbo + §5 Invariants 2 & 5 + §13.4 SCA surfacing.
//
// These tests exercise the headless Limbo surface (`LimboContext`,
// `LimboAction`, `LimboTimeline`) plus minimal AppKit-bound
// construction checks on `LimboHUDController`. The controller tests
// pin the behavior the capture-pipeline wiring will depend on:
//   * `excludedWindows` publishes exactly the HUD panel so
//     `SCContentFilter` can exclude it (Invariant 5).
//   * `showsRedactButton` gates purely on SCA output per §13.4.
//
// All AppKit-touching tests are `@MainActor` so NSPanel construction
// is legal under Swift 6 strict concurrency.
@Suite("LimboHUDTests")
struct LimboHUDTests {

    // MARK: - Fixtures

    /// Synthesizes a `LimboContext` with stable URLs + a caller-specified
    /// sensitivity vector. URLs are synthetic — the HUD gracefully
    /// degrades to an empty thumbnail when the file does not exist.
    private static func makeContext(
        sensitivity: [String] = ["none"],
        duration: TimeInterval = 3.0
    ) -> LimboContext {
        let tmp = FileManager.default.temporaryDirectory
        let base = tmp.appendingPathComponent("limbo-\(UUID().uuidString).shot", isDirectory: true)
        return LimboContext(
            id: "01925b0d-1c2d-7001-9000-000000000001",
            thumbnailURL: base.appendingPathComponent("thumb.jpg"),
            masterURL: base.appendingPathComponent("master.png"),
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "ContentView.swift",
            sensitivity: sensitivity,
            durationSeconds: duration
        )
    }

    // MARK: - 1. LimboTimeline visibility math

    @Test("Timeline: within 2s → visible; after 10s → hidden; mouseover refresh extends but caps at 8s")
    func timelineVisibility() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let timeline = LimboTimeline(start: start)

        // At t+1s (within minSeconds) → still visible.
        #expect(timeline.isVisible(at: start.addingTimeInterval(1.0)))
        #expect(timeline.remainingSeconds(at: start.addingTimeInterval(1.0)) > 0)

        // At t+10s → past hard ceiling → hidden.
        #expect(!timeline.isVisible(at: start.addingTimeInterval(10.0)))
        #expect(timeline.remainingSeconds(at: start.addingTimeInterval(10.0)) == 0)

        // At t+2.5s with no interaction → hidden (baseline 2s deadline).
        #expect(!timeline.isVisible(at: start.addingTimeInterval(2.5)))

        // Mouseover at t+1.5s resets countdown to t+1.5+2 = t+3.5s.
        let refreshed = timeline.refreshed(at: start.addingTimeInterval(1.5))
        #expect(refreshed.isVisible(at: start.addingTimeInterval(3.0)))
        #expect(!refreshed.isVisible(at: start.addingTimeInterval(3.6)))

        // Hover must never push past the hard 8s ceiling.
        let lateHover = timeline.refreshed(at: start.addingTimeInterval(7.5))
        // Baseline would say 7.5 + 2 = 9.5, but ceiling is 8.
        #expect(lateHover.isVisible(at: start.addingTimeInterval(7.9)))
        #expect(!lateHover.isVisible(at: start.addingTimeInterval(8.0)))
        #expect(!lateHover.isVisible(at: start.addingTimeInterval(8.1)))

        // Remaining at start is exactly minSeconds.
        #expect(abs(timeline.remainingSeconds(at: start) - LimboTimelineBounds.minSeconds) < 1e-9)
    }

    // MARK: - 2. LimboAction keymap round-trip

    @Test("LimboAction keymap: e/p/t/esc/cmd_z round-trip; unknown token → nil")
    func actionKeymapRoundTrip() {
        // All declared cases parse from their raw value.
        for action in LimboAction.allCases {
            #expect(LimboAction(rawValue: action.rawValue) == action)
            #expect(LimboAction(keyToken: action.rawValue) == action)
        }
        // Exact contract per SPEC §4 keymap.
        #expect(LimboAction(keyToken: "e") == .edit)
        #expect(LimboAction(keyToken: "p") == .pin)
        #expect(LimboAction(keyToken: "t") == .tag)
        #expect(LimboAction(keyToken: "esc") == .deleteEsc)
        #expect(LimboAction(keyToken: "cmd_z") == .redirect)

        // Unknown keys → nil.
        #expect(LimboAction(keyToken: "q") == nil)
        #expect(LimboAction(keyToken: "") == nil)
        #expect(LimboAction(keyToken: "cmd+z") == nil)  // intentional: the dispatcher emits "cmd_z", not "cmd+z"
        #expect(LimboAction(keyToken: "E") == nil)      // case-sensitive by design
    }

    // MARK: - 3. LimboContext codable round-trip

    @Test("LimboContext encode/decode round-trip preserves all fields byte-identically")
    func contextCodableRoundTrip() throws {
        let original = Self.makeContext(
            sensitivity: ["password_field", "card_number"],
            duration: 5.0
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data1 = try encoder.encode(original)

        let decoded = try JSONDecoder().decode(LimboContext.self, from: data1)
        #expect(decoded == original)

        // Second encode must be byte-identical to the first — asserts no
        // ordering-sensitive fields sneak in.
        let data2 = try encoder.encode(decoded)
        #expect(data1 == data2)
    }

    // MARK: - 4. LimboHUDController smoke test + excludedWindows

    @Test("LimboHUDController instantiates; excludedWindows exposes exactly the HUD panel")
    @MainActor
    func controllerSmokeAndExcludedWindows() {
        let ctx = Self.makeContext()
        let controller = LimboHUDController(context: ctx)

        // One window — the single HUD panel (Invariant 5: CaptureEngine
        // hands this to SCContentFilter(...excludingWindows:)).
        #expect(controller.excludedWindows.count == 1)
        #expect(controller.excludedWindows.first is NSPanel)
    }

    // MARK: - 5. SCA sensitivity gating

    @Test("Sensitivity gating: ['none'] hides redact button; ['password_field'] surfaces it")
    @MainActor
    func sensitivityGatesRedactButton() {
        let clean = LimboHUDController(context: Self.makeContext(sensitivity: ["none"]))
        #expect(clean.showsRedactButton == false)

        let pwd = LimboHUDController(context: Self.makeContext(sensitivity: ["password_field"]))
        #expect(pwd.showsRedactButton == true)

        // Multi-finding combinations also surface the button.
        let combo = LimboHUDController(
            context: Self.makeContext(sensitivity: ["nudity", "card_number"])
        )
        #expect(combo.showsRedactButton == true)

        // Empty array defensively gates to false (no findings ⇒ nothing
        // to redact) — guards against an accidental empty-vector write.
        let empty = LimboHUDController(context: Self.makeContext(sensitivity: []))
        #expect(empty.showsRedactButton == false)
    }

    // MARK: - 6. Dispatch round-trip (covers keyboard path incidentally)

    @Test("Dispatch forwards the action verbatim to the callback")
    @MainActor
    func dispatchForwardsAction() async {
        let ctx = Self.makeContext()
        let received = ActionCollector()
        let controller = LimboHUDController(context: ctx) { action in
            received.append(action)
        }
        controller.dispatch(.edit)
        controller.dispatch(.pin)
        controller.dispatch(.deleteEsc)
        controller.dispatch(.redirect)
        #expect(received.all == [.edit, .pin, .deleteEsc, .redirect])
    }
}

// MARK: - Helpers

/// Tiny MainActor-isolated sink — avoids capturing a mutable array in
/// the `@Sendable` callback. The controller callback is
/// `@MainActor @Sendable` so we can close over this class safely on
/// the main actor.
@MainActor
private final class ActionCollector {
    private(set) var all: [LimboAction] = []
    func append(_ action: LimboAction) { all.append(action) }
}
