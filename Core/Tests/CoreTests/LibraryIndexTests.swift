import Foundation
import Testing
@testable import Core

@Suite("LibraryIndexTests")
struct LibraryIndexTests {

    // MARK: - Helpers

    private static func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libidx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeIndex(at tmp: URL) throws -> LibraryIndex {
        let dbURL = tmp.appendingPathComponent("index.db")
        return try LibraryIndex(databaseURL: dbURL)
    }

    private static func sampleRecord(
        id: String = UUID().uuidString,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        windowTitle: String? = "ContentView.swift",
        fileURL: String? = "file:///Users/dev/proj/Sources/App/ContentView.swift",
        bundleID: String? = "com.apple.dt.Xcode",
        gitRoot: String? = "/Users/dev/proj",
        browserURL: String? = nil,
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
            gitRoot: gitRoot,
            browserURL: browserURL,
            clipboard: clipboard,
            ocrText: ocrText
        )
    }

    // MARK: - Insert → fetch round-trip

    @Test("Insert-after-write: inserting a row then querying by id returns expected fields")
    func insertRoundTrip() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        let record = Self.sampleRecord(
            id: "cap-0001",
            createdAt: 1_700_000_000,
            windowTitle: "ContentView.swift — MyApp",
            fileURL: "file:///Users/dev/myapp/Sources/ContentView.swift",
            bundleID: "com.apple.dt.Xcode",
            gitRoot: "/Users/dev/myapp",
            clipboard: "let greeting = \"hello\""
        )

        try await idx.insert(record)

        let fetched = try await idx.fetch(id: "cap-0001")
        #expect(fetched != nil)
        #expect(fetched?.id == record.id)
        #expect(fetched?.createdAt == record.createdAt)
        #expect(fetched?.expiresAt == record.expiresAt)
        #expect(fetched?.pinned == false)
        #expect(fetched?.bundleID == record.bundleID)
        #expect(fetched?.windowTitle == record.windowTitle)
        #expect(fetched?.fileURL == record.fileURL)
        #expect(fetched?.gitRoot == record.gitRoot)
        #expect(fetched?.clipboard == record.clipboard)
        #expect(fetched?.ocrText == nil)

        // FTS-side reachability: the window title token should find this row.
        let hits = try await idx.searchIDs("ContentView")
        #expect(hits.contains("cap-0001"))
    }

    @Test("Fetch of unknown id returns nil; delete of unknown id is a no-op")
    func missingIDsHandledGracefully() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        let missing = try await idx.fetch(id: "does-not-exist")
        #expect(missing == nil)

        // Shouldn't throw.
        try await idx.delete(id: "does-not-exist")
    }

    @Test("Delete removes the row and drops it from FTS results")
    func deleteDropsFTS() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        try await idx.insert(Self.sampleRecord(id: "cap-del", windowTitle: "DeletableThing.swift"))
        #expect(try await idx.searchIDs("DeletableThing").contains("cap-del"))

        try await idx.delete(id: "cap-del")

        #expect(try await idx.fetch(id: "cap-del") == nil)
        #expect(try await idx.searchIDs("DeletableThing").isEmpty)
    }

    // MARK: - FTS5 latency

    @Test("FTS5 query latency p95 < 100ms on a 1000-row fixture")
    func ftsQueryLatency() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        // Insert 1000 rows. OCR text varies so the index has real distribution.
        let corpus = [
            "the quick brown fox jumps over the lazy dog",
            "Shotfuse captures pixels and AX tree snapshots",
            "SwiftUI cannot own SCStream or SCStreamOutput",
            "master png is written once and never modified",
            "FTS5 external content tables index full text",
            "macOS twenty six exposes SCSensitivityAnalyzer",
            "the Limbo HUD mediates destination choices",
            "RegisterEventHotKey avoids Input Monitoring TCC",
            "Carbon hotkeys are fine for v0.1",
            "Obsidian daily notes receive routed captures"
        ]

        for i in 0..<1000 {
            let id = String(format: "cap-%05d", i)
            let rec = Self.sampleRecord(
                id: id,
                createdAt: Int64(1_700_000_000 + i),
                windowTitle: "Window-\(i) \(corpus[i % corpus.count].split(separator: " ").first.map(String.init) ?? "x")",
                fileURL: "file:///tmp/row-\(i).swift",
                clipboard: corpus[i % corpus.count],
                ocrText: "row-\(i) token-\(i % 37) \(corpus[(i + 3) % corpus.count])"
            )
            try await idx.insert(rec)
        }
        #expect(try await idx.count() == 1000)

        // 100 queries, pick tokens that actually match something. Hyphens are
        // avoided because FTS5's query parser interprets `-x` as a column
        // filter; tokens like "token-3" would be parsed as "no such column: 3".
        let queries = [
            "pixels", "Shotfuse", "captures", "SCStream", "Limbo",
            "hotkeys", "Obsidian", "macOS", "Carbon", "master",
            "Window", "SwiftUI", "twenty", "external", "jumps",
            "routed", "notes", "daily", "lazy", "index"
        ]

        var samples: [Double] = []
        samples.reserveCapacity(100)

        // Warm-up — first query amortizes FTS/VFS init cost.
        _ = try await idx.searchIDs(queries[0])

        let clock = ContinuousClock()
        for i in 0..<100 {
            let q = queries[i % queries.count]
            let duration = try await clock.measure {
                _ = try await idx.searchIDs(q, limit: 50)
            }
            samples.append(duration.toMilliseconds())
        }

        let p95 = percentile(samples, 0.95)
        let p50 = percentile(samples, 0.50)
        print("LibraryIndex FTS5 latency — p50=\(String(format: "%.3f", p50))ms p95=\(String(format: "%.3f", p95))ms over \(samples.count) queries")
        #expect(p95 < 100.0, "p95 latency \(p95)ms exceeds 100ms budget")
    }

    // MARK: - OCR async enrichment

    @Test("OCR async enrichment: FTS finds the enriched row and the non-OCR row remains retrievable")
    func ocrEnrichment() async throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let idx = try Self.makeIndex(at: tmp)
        defer { Task { await idx.close() } }

        // 1. Insert `target` WITHOUT ocr_text — searchable only via its
        //    window title / file url / clipboard.
        let target = Self.sampleRecord(
            id: "cap-target",
            createdAt: 1_700_000_100,
            windowTitle: "TargetWindow",
            fileURL: "file:///tmp/target.swift",
            bundleID: "com.apple.dt.Xcode",
            gitRoot: "/tmp",
            browserURL: nil,
            clipboard: nil,
            ocrText: nil
        )
        try await idx.insert(target)

        // 2. Insert `other` — already has OCR text, unrelated to `target`.
        //    This row is the invariant we care about: after enriching `target`,
        //    `other` must still be retrievable by its own tokens.
        let other = Self.sampleRecord(
            id: "cap-other",
            createdAt: 1_700_000_050,
            windowTitle: "OtherWindow",
            fileURL: "file:///tmp/other.swift",
            bundleID: "com.apple.dt.Xcode",
            gitRoot: "/tmp",
            browserURL: nil,
            clipboard: nil,
            ocrText: "persimmon umbrella glacier"
        )
        try await idx.insert(other)

        // Before enrichment: OCR-only token "archaeopteryx" should match nothing.
        #expect(try await idx.searchIDs("archaeopteryx").isEmpty)

        // 3. Enrich `target` with OCR text containing a unique marker token.
        try await idx.updateOCR(for: "cap-target", ocrText: "archaeopteryx quicksilver nebula")

        // 4. FTS query against the new OCR token should find `target`.
        let ocrHits = try await idx.searchIDs("archaeopteryx")
        #expect(ocrHits == ["cap-target"], "expected target to be found by OCR term, got \(ocrHits)")

        // 5. `other` row must still be retrievable via its own pre-enrichment tokens.
        let otherHits = try await idx.searchIDs("persimmon")
        #expect(otherHits == ["cap-other"], "other row became unreachable after enrichment: \(otherHits)")

        // 6. Target's own non-OCR fields still work (window title path).
        let titleHits = try await idx.searchIDs("TargetWindow")
        #expect(titleHits == ["cap-target"])

        // 7. Round-trip: fetched record now carries the OCR text.
        let fetched = try await idx.fetch(id: "cap-target")
        #expect(fetched?.ocrText == "archaeopteryx quicksilver nebula")
    }

    // MARK: - percentile util

    /// Returns the (linear-interpolated) percentile of `samples`, `p ∈ [0,1]`.
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

// MARK: - Duration → ms helper

private extension Duration {
    func toMilliseconds() -> Double {
        // `components` returns (seconds: Int64, attoseconds: Int64).
        let c = self.components
        return Double(c.seconds) * 1_000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}
