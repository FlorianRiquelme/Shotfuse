import Foundation
import Testing
@testable import Core

@Suite("ShotPackageWriterTests")
struct ShotPackageWriterTests {

    /// Unique tmp dir per test, with cleanup registered by the caller via `defer`.
    private static func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotpkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static let sampleManifest = Data(#"{"version":1}"#.utf8)
    private static let sampleFiles: [String: Data] = [
        "master.png": Data([0x89, 0x50, 0x4E, 0x47]),     // PNG magic header
        "thumb.jpg": Data([0xFF, 0xD8, 0xFF]),             // JPEG magic header
        "ocr.json": Data(#"{"text":"hello"}"#.utf8),
        "context.json": Data(#"{"app":"Xcode"}"#.utf8),
    ]

    @Test("Happy path: writes foo.shot/ with all files + manifest, no .shot.tmp/ remains")
    func happyPath() throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("foo.shot")
        let tempURL = tmp.appendingPathComponent("foo.shot.tmp")

        var writer = ShotPackageWriter()
        try writer.write(to: finalURL, manifest: Self.sampleManifest, files: Self.sampleFiles)

        let fm = FileManager.default

        // Final exists as a directory.
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: finalURL.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Staging dir is gone.
        #expect(!fm.fileExists(atPath: tempURL.path))

        // Manifest present.
        let manifestURL = finalURL.appendingPathComponent("manifest.json")
        #expect(fm.fileExists(atPath: manifestURL.path))
        #expect(try Data(contentsOf: manifestURL) == Self.sampleManifest)

        // Every payload file landed with correct bytes.
        for (name, expected) in Self.sampleFiles {
            let fileURL = finalURL.appendingPathComponent(name)
            #expect(fm.fileExists(atPath: fileURL.path), "missing \(name)")
            #expect(try Data(contentsOf: fileURL) == expected, "payload mismatch for \(name)")
        }

        // fsync happened before rename completed.
        #expect(writer.didFsyncManifest)
    }

    @Test("Rejects a finalURL that doesn't end in .shot")
    func rejectsWrongExtension() throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let badURL = tmp.appendingPathComponent("foo.bundle")
        var writer = ShotPackageWriter()

        #expect(throws: ShotPackageWriterError.self) {
            try writer.write(to: badURL, manifest: Self.sampleManifest, files: [:])
        }
        #expect(!writer.didFsyncManifest)
    }

    @Test("Throws destinationExists when final package already exists; never overwrites")
    func refusesToOverwriteExistingPackage() throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let finalURL = tmp.appendingPathComponent("foo.shot")
        let fm = FileManager.default

        // Pre-create a bogus foo.shot/ with a sentinel file so we can prove
        // the writer didn't clobber it.
        try fm.createDirectory(at: finalURL, withIntermediateDirectories: false)
        let sentinel = finalURL.appendingPathComponent("sentinel.txt")
        try Data("pre-existing".utf8).write(to: sentinel)

        var writer = ShotPackageWriter()
        #expect(throws: ShotPackageWriterError.self) {
            try writer.write(to: finalURL, manifest: Self.sampleManifest, files: Self.sampleFiles)
        }

        // Sentinel untouched — the existing package was not overwritten.
        #expect(fm.fileExists(atPath: sentinel.path))
        #expect(try Data(contentsOf: sentinel) == Data("pre-existing".utf8))

        // No payload from our attempted write ended up inside the final package.
        #expect(!fm.fileExists(atPath: finalURL.appendingPathComponent("manifest.json").path))

        // fsync must not have run — we bailed before writing anything.
        #expect(!writer.didFsyncManifest)
    }

    @Test("Scanner returns only .shot/ dirs and ignores .shot.tmp/")
    func scannerIgnoresTemporaryPackages() throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let fm = FileManager.default
        let goodURL = tmp.appendingPathComponent("foo.shot")
        let tempURL = tmp.appendingPathComponent("bar.shot.tmp")
        let unrelatedURL = tmp.appendingPathComponent("notes.txt")

        try fm.createDirectory(at: goodURL, withIntermediateDirectories: false)
        try fm.createDirectory(at: tempURL, withIntermediateDirectories: false)
        try Data("hi".utf8).write(to: unrelatedURL)

        let scanner = PackageScanner()
        let found = try scanner.scan(tmp)
        let names = Set(found.map { $0.lastPathComponent })

        #expect(names == ["foo.shot"])
    }

    @Test("After destinationExists failure, scanner still sees only the pre-existing .shot/")
    func scannerHidesResidualStagingAfterFailedWrite() throws {
        let tmp = try Self.makeTmpDir()
        defer { Self.cleanup(tmp) }

        let fm = FileManager.default
        let finalURL = tmp.appendingPathComponent("foo.shot")
        try fm.createDirectory(at: finalURL, withIntermediateDirectories: false)

        var writer = ShotPackageWriter()
        #expect(throws: ShotPackageWriterError.self) {
            try writer.write(to: finalURL, manifest: Self.sampleManifest, files: Self.sampleFiles)
        }

        // Even if a rogue .shot.tmp/ were lingering from prior activity,
        // the scanner must only surface .shot/ packages.
        let scanner = PackageScanner()
        let found = try scanner.scan(tmp)
        #expect(found.map { $0.lastPathComponent } == ["foo.shot"])
    }

    @Test("isTemporaryPackage classifier")
    func isTemporaryPackageClassifier() {
        #expect(ShotPackageWriter.isTemporaryPackage(URL(fileURLWithPath: "/x/foo.shot.tmp")))
        #expect(!ShotPackageWriter.isTemporaryPackage(URL(fileURLWithPath: "/x/foo.shot")))
        #expect(!ShotPackageWriter.isTemporaryPackage(URL(fileURLWithPath: "/x/foo.txt")))
    }
}
