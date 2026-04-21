import Foundation
import Testing
@testable import Core

@Suite("FuseGCTests")
struct FuseGCTests {

    // MARK: - Helpers

    private static func makeTmpLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fusegc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// ISO8601 formatter used for fabricating `expires_at` values in the
    /// manifests written by these tests. Matches the production writer's
    /// expected wire format.
    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Writes a fake `.shot/` package at `url` with a manifest that carries
    /// `expires_at` and `pinned` plus a couple of extra unknown fields, so
    /// we assert the parser's schema-tolerance at the same time.
    @discardableResult
    private static func writePackage(
        at url: URL,
        expiresAt: Date,
        pinned: Bool,
        malformed: Bool = false,
        missingManifest: Bool = false,
        extraField: (key: String, value: String)? = ("sensitivity", "none")
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: false)

        if missingManifest {
            return url
        }

        let manifestURL = url.appendingPathComponent("manifest.json")
        if malformed {
            try Data("this is not json {".utf8).write(to: manifestURL)
            return url
        }

        var obj: [String: Any] = [
            "id": UUID().uuidString,
            "expires_at": iso(expiresAt),
            "pinned": pinned,
        ]
        if let extra = extraField {
            obj[extra.key] = extra.value
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: manifestURL)
        return url
    }

    // MARK: - Tests

    @Test("Pinned package with expired timestamp is NOT deleted")
    func pinnedNeverDeleted() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let longAgo = now.addingTimeInterval(-48 * 3600) // 2 days ago

        let pkg = lib.appendingPathComponent("2026-01-01T00-00-00.shot")
        try Self.writePackage(at: pkg, expiresAt: longAgo, pinned: true)

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.skippedPinned.map(\.lastPathComponent) == [pkg.lastPathComponent])
        #expect(result.skippedTmp.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: pkg.path))
    }

    @Test("Unpinned package past expires_at IS deleted")
    func unpinnedExpiredDeleted() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-3600) // 1 hour ago

        let pkg = lib.appendingPathComponent("2026-01-01T01-00-00.shot")
        try Self.writePackage(at: pkg, expiresAt: expired, pinned: false)

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.map(\.lastPathComponent) == [pkg.lastPathComponent])
        #expect(result.skippedPinned.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pkg.path))
    }

    @Test("Unpinned package still within fuse window is NOT deleted")
    func unpinnedFreshKept() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3600) // 1 hour ahead

        let pkg = lib.appendingPathComponent("fresh.shot")
        try Self.writePackage(at: pkg, expiresAt: future, pinned: false)

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.skippedPinned.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: pkg.path))
    }

    @Test(".shot.tmp/ staging directories are tracked and NEVER deleted")
    func staleStagingSkipped() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let staging = lib.appendingPathComponent("in-flight.shot.tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        // Populate it with a half-written manifest to simulate a crash mid-write.
        try Data("half".utf8).write(to: staging.appendingPathComponent("manifest.json"))

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.skippedPinned.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(result.skippedTmp.map(\.lastPathComponent) == [staging.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("Malformed manifest goes to errors and the package is NOT deleted")
    func malformedManifestRecordedAsError() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let pkg = lib.appendingPathComponent("bad.shot")
        try Self.writePackage(
            at: pkg,
            expiresAt: now, // unused
            pinned: false,
            malformed: true
        )

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].0.lastPathComponent == "bad.shot")
        #expect(FileManager.default.fileExists(atPath: pkg.path))
    }

    @Test("Missing manifest goes to errors and the package is NOT deleted")
    func missingManifestRecordedAsError() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let pkg = lib.appendingPathComponent("no-manifest.shot")
        try Self.writePackage(
            at: pkg,
            expiresAt: now,
            pinned: false,
            missingManifest: true
        )

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.isEmpty)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].0.lastPathComponent == "no-manifest.shot")
        if case FusePolicyError.manifestMissing = result.errors[0].1 {
            // ok
        } else {
            Issue.record("expected manifestMissing, got \(result.errors[0].1)")
        }
        #expect(FileManager.default.fileExists(atPath: pkg.path))
    }

    @Test("Mixed library: counts aggregate correctly across every category")
    func mixedLibraryAggregates() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-3600)
        let fresh = now.addingTimeInterval(3600)

        // 1. Expired unpinned → should be deleted.
        let expiredPkg = lib.appendingPathComponent("expired.shot")
        try Self.writePackage(at: expiredPkg, expiresAt: expired, pinned: false)

        // 2. Expired pinned → should be skippedPinned, not deleted.
        let pinnedExpired = lib.appendingPathComponent("pinned-old.shot")
        try Self.writePackage(at: pinnedExpired, expiresAt: expired, pinned: true)

        // 3. Fresh unpinned → neither deleted nor bucketed.
        let fresh1 = lib.appendingPathComponent("fresh.shot")
        try Self.writePackage(at: fresh1, expiresAt: fresh, pinned: false)

        // 4. `.shot.tmp/` staging dir → skippedTmp.
        let staging = lib.appendingPathComponent("staging.shot.tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        // 5. Malformed `.shot/` → error.
        let malformed = lib.appendingPathComponent("bad.shot")
        try Self.writePackage(at: malformed, expiresAt: expired, pinned: false, malformed: true)

        // 6. Stray non-`.shot/` files/dirs → ignored completely.
        try Data("hi".utf8).write(to: lib.appendingPathComponent("stray.txt"))
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("random-dir"),
            withIntermediateDirectories: false
        )

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.map(\.lastPathComponent) == ["expired.shot"])
        #expect(result.skippedPinned.map(\.lastPathComponent) == ["pinned-old.shot"])
        #expect(result.skippedTmp.map(\.lastPathComponent) == ["staging.shot.tmp"])
        #expect(result.errors.count == 1)
        #expect(result.errors[0].0.lastPathComponent == "bad.shot")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: expiredPkg.path))
        #expect(fm.fileExists(atPath: pinnedExpired.path))
        #expect(fm.fileExists(atPath: fresh1.path))
        #expect(fm.fileExists(atPath: staging.path))
        #expect(fm.fileExists(atPath: malformed.path))
    }

    @Test("Unknown manifest fields (e.g. sensitivity) do not affect parsing")
    func schemaToleranceIgnoresUnknownFields() throws {
        let lib = try Self.makeTmpLibrary()
        defer { Self.cleanup(lib) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-1)

        let pkg = lib.appendingPathComponent("future-schema.shot")
        // Manifest written directly so we can inject an unknown field that
        // the parser must ignore without error.
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: false)
        let obj: [String: Any] = [
            "id": UUID().uuidString,
            "expires_at": Self.iso(expired),
            "pinned": false,
            "sensitivity": ["none"],
            "some_future_field": ["nested": 42],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: pkg.appendingPathComponent("manifest.json"))

        let policy = FusePolicy()
        let result = try policy.collect(libraryRoot: lib, now: now)

        #expect(result.deleted.map(\.lastPathComponent) == ["future-schema.shot"])
        #expect(result.errors.isEmpty)
    }
}
