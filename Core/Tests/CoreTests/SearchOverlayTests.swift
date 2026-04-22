import Foundation
import Testing
@testable import Core

@Suite("SearchOverlayTests")
struct SearchOverlayTests {

    // MARK: - Helpers

    private static func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeIndex(at tmp: URL) throws -> LibraryIndex {
        try LibraryIndex(databaseURL: tmp.appendingPathComponent("index.db"))
    }

    private static func record(
        id: String,
        createdAt: Int64 = 1_700_000_000,
        windowTitle: String? = nil,
        fileURL: String? = nil,
        bundleID: String? = nil,
        clipboard: String? = nil,
        ocrText: String? = nil
    ) -> LibraryRecord {
        LibraryRecord(
            id: id,
            createdAt: createdAt,
            expiresAt: createdAt + 24 * 3600,
            pinned: false,
            bundleID: bundleID,
            windowTitle: windowTitle,
            fileURL: fileURL,
            gitRoot: nil,
            browserURL: nil,
            clipboard: clipboard,
            ocrText: ocrText
        )
    }

    // MARK: - 1. FTS5 latency on 1000-row fixture

    @Test("Search overlay query p95 latency < 100ms on 1000-row fixture")
    func searchLatency() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        // Realistic mix — frontmost apps, file paths, OCR noise.
        let apps = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "md.obsidian",
            "com.apple.Safari",
            "com.tinyspeck.slackmacgap"
        ]
        let titleWords = [
            "ContentView", "AppDelegate", "Router", "LibraryIndex",
            "ScreenCaptureKit", "CaptureEngine", "manifest", "telemetry",
            "Shotfuse", "README"
        ]
        let ocrCorpus = [
            "the quick brown fox jumps over the lazy dog",
            "Shotfuse captures pixels and AX tree snapshots",
            "SwiftUI cannot own SCStream or SCStreamOutput",
            "master png is written once and never modified",
            "FTS5 external content tables index full text"
        ]

        for i in 0..<1000 {
            let id = String(format: "cap-%05d", i)
            let rec = Self.record(
                id: id,
                createdAt: Int64(1_700_000_000 + i),
                windowTitle: "\(titleWords[i % titleWords.count])-\(i).swift",
                fileURL: "file:///Users/dev/proj/Sources/row\(i).swift",
                bundleID: apps[i % apps.count],
                clipboard: ocrCorpus[i % ocrCorpus.count],
                ocrText: "row\(i) marker\(i % 19) \(ocrCorpus[(i + 2) % ocrCorpus.count])"
            )
            try await idx.insert(rec)
        }

        // Realistic type-ahead queries through the sanitizer — no caller
        // should ever bypass it.
        let rawQueries = [
            "ContentView", "Shotfuse", "manifest", "CaptureEngine",
            "Router", "quick brown", "SwiftUI", "pixels", "AX tree",
            "Xcode", "marker5", "row123", "index"
        ]

        // Warm-up amortizes FTS/VFS init cost.
        _ = try await idx.searchIDs(SearchQuery.sanitize(rawQueries[0]))

        var samples: [Double] = []
        samples.reserveCapacity(100)
        let clock = ContinuousClock()
        for i in 0..<100 {
            let q = SearchQuery.sanitize(rawQueries[i % rawQueries.count])
            let d = try await clock.measure {
                _ = try await idx.searchIDs(q, limit: 50)
            }
            samples.append(d.toMilliseconds())
        }

        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        print("SearchOverlay FTS5 latency — p50=\(String(format: "%.3f", p50))ms p95=\(String(format: "%.3f", p95))ms over \(samples.count) queries")
        #expect(p95 < 100.0, "p95 latency \(p95)ms exceeds 100ms budget")
    }

    // MARK: - 2. Sanitizer round-trip

    @Test("Sanitizer neutralizes unquoted hyphens; sanitized query round-trips to a hit")
    func sanitizerRoundTrip() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        // Insert a row whose token contains a hyphen — this is the failing
        // case a naïve caller would hit.
        let hyphenatedTitle = "plan-phase-02"
        try await idx.insert(Self.record(
            id: "cap-hyph",
            windowTitle: hyphenatedTitle,
            fileURL: "file:///tmp/plan-phase-02.md"
        ))

        // Raw input with a hyphen would crash FTS5 as "no such column" —
        // sanitizer must quote it.
        let raw = "plan-phase-02"
        let sanitized = SearchQuery.sanitize(raw)
        #expect(sanitized.contains("\""), "expected sanitizer to quote hyphen-bearing token, got \(sanitized)")

        // Round-trip: sanitized query finds the inserted row.
        let hits = try await idx.searchIDs(sanitized)
        #expect(hits == ["cap-hyph"], "expected sanitized query to hit the inserted row, got \(hits)")

        // Sanity: empty input returns empty string (caller short-circuits).
        #expect(SearchQuery.sanitize("") == "")
        #expect(SearchQuery.sanitize("   ") == "")

        // Wildcard is preserved.
        let wild = SearchQuery.sanitize("plan*")
        #expect(wild.hasSuffix("*"))
    }

    // MARK: - 3. Top-1 correctness across window_title, bundle_id, ocr_text

    @Test("Top-1 hit: window_title, file_url, bundle_id, and ocr_text each find the expected row")
    func topOneCorrectness() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        // Fixture: four rows, each with a unique marker in exactly one FTS
        // column (schema v2 adds `bundle_id`, so bundle-id lookup is native).
        let rowByTitle = Self.record(
            id: "row-title",
            createdAt: 1_700_001_000,
            windowTitle: "uniqueTitleMarkerAardvark",
            fileURL: "file:///tmp/a.swift",
            bundleID: "com.apple.Safari",
            clipboard: nil,
            ocrText: "irrelevant ocr payload"
        )
        let rowByFileURL = Self.record(
            id: "row-file",
            createdAt: 1_700_002_000,
            windowTitle: "SomeEditor",
            fileURL: "file:///tmp/uniqueBundleMarkerBaboon.swift",
            bundleID: "com.microsoft.VSCode",
            clipboard: nil,
            ocrText: "irrelevant ocr payload"
        )
        let rowByBundleID = Self.record(
            id: "row-bundle",
            createdAt: 1_700_002_500,
            windowTitle: "YetAnotherEditor",
            fileURL: "file:///tmp/b.swift",
            bundleID: "dev.zed.UniqueBundleMarkerDingo",
            clipboard: nil,
            ocrText: "irrelevant ocr payload"
        )
        let rowByOCR = Self.record(
            id: "row-ocr",
            createdAt: 1_700_003_000,
            windowTitle: "AnotherEditor",
            fileURL: "file:///tmp/c.swift",
            bundleID: "md.obsidian",
            clipboard: nil,
            ocrText: "uniqueOcrMarkerCapybara among other scanned tokens"
        )
        try await idx.insert(rowByTitle)
        try await idx.insert(rowByFileURL)
        try await idx.insert(rowByBundleID)
        try await idx.insert(rowByOCR)

        // Window-title marker.
        let titleHits = try await idx.searchIDs(SearchQuery.sanitize("uniqueTitleMarkerAardvark"))
        #expect(titleHits.first == "row-title", "top-1 by window_title mismatch: \(titleHits)")

        // File-URL marker.
        let fileHits = try await idx.searchIDs(SearchQuery.sanitize("uniqueBundleMarkerBaboon"))
        #expect(fileHits.first == "row-file", "top-1 by file_url mismatch: \(fileHits)")

        // bundle_id marker — schema v2.
        let bundleHits = try await idx.searchIDs(SearchQuery.sanitize("UniqueBundleMarkerDingo"))
        #expect(bundleHits.first == "row-bundle", "top-1 by bundle_id mismatch: \(bundleHits)")

        // OCR marker.
        let ocrHits = try await idx.searchIDs(SearchQuery.sanitize("uniqueOcrMarkerCapybara"))
        #expect(ocrHits.first == "row-ocr", "top-1 by ocr_text mismatch: \(ocrHits)")
    }

    // MARK: - 4. HotkeyRegistry failure path (via mock protocol)

    @Test("HotkeyRegistry: registering the same id twice throws alreadyRegistered")
    @MainActor
    func hotkeyRegistryDoubleRegisterFails() async throws {
        let mock = MockHotkeyRegistry()

        try mock.register(id: 42, keyCode: 1, modifiers: 0) { }

        #expect(throws: HotkeyRegistryError.self) {
            try mock.register(id: 42, keyCode: 1, modifiers: 0) { }
        }

        // Unregister → re-register succeeds.
        mock.unregister(id: 42)
        try mock.register(id: 42, keyCode: 1, modifiers: 0) { }
    }

    @Test("HotkeyRegistry: configured failure is surfaced through the throwing API")
    @MainActor
    func hotkeyRegistryFailuresSurface() async throws {
        let mock = MockHotkeyRegistry()
        mock.failNextRegister = .registrationFailed(id: 7, status: -9878)

        #expect(throws: HotkeyRegistryError.self) {
            try mock.register(id: 7, keyCode: 1, modifiers: 0) { }
        }

        // After a failure the id is NOT recorded — a retry path is possible.
        mock.failNextRegister = nil
        try mock.register(id: 7, keyCode: 1, modifiers: 0) { }
    }

    // MARK: - percentile util

    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] + frac * (sorted[hi] - sorted[lo])
    }
}

// MARK: - MockHotkeyRegistry

/// Test-only `HotkeyRegistering` that never touches Carbon. Lets us exercise
/// the controller's failure path deterministically without grabbing real
/// global hotkeys on the test host.
@MainActor
final class MockHotkeyRegistry: HotkeyRegistering {
    /// If non-nil, the NEXT call to `register` throws this error and clears
    /// the slot. Subsequent calls proceed normally.
    var failNextRegister: HotkeyRegistryError?

    private(set) var registered: [UInt32: () -> Void] = [:]

    func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws {
        if let err = failNextRegister {
            failNextRegister = nil
            throw err
        }
        if registered[id] != nil {
            throw HotkeyRegistryError.alreadyRegistered(id: id)
        }
        registered[id] = handler
    }

    func unregister(id: UInt32) {
        registered.removeValue(forKey: id)
    }

    /// Test helper — synthesize a hotkey firing without going through Carbon.
    func fire(id: UInt32) {
        registered[id]?()
    }
}

// MARK: - Duration → ms helper

private extension Duration {
    func toMilliseconds() -> Double {
        let c = self.components
        return Double(c.seconds) * 1_000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}
