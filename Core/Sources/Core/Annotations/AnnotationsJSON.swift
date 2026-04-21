import Foundation

// Persistence layer for `annotations.json` (SPEC §6.4). The sidecar lives
// inside the `.shot/` package alongside `master.png`, `manifest.json`, etc.
// Kept separate from the renderer so callers can mutate annotations without
// pulling in CoreGraphics drawing code.

/// Errors thrown by `AnnotationsJSON`.
public enum AnnotationsJSONError: Error, Sendable, Equatable {
    /// Supplied package URL does not have a `.shot` path extension.
    case invalidPackageURL
    /// Encoding / decoding failure; wrapped `message` is the localized reason.
    case codingFailure(String)
    /// Filesystem I/O failure.
    case ioFailure(String)
}

/// Reads / writes `annotations.json` inside a `.shot/` package directory.
///
/// This type is deliberately tiny — no actor isolation, no caching. Callers
/// that need concurrency control should wrap it.
public struct AnnotationsJSON {

    /// Canonical filename inside a `.shot/` package.
    public static let filename = "annotations.json"

    public init() {}

    /// Returns the URL of `annotations.json` inside the given `.shot/` dir.
    /// Throws `.invalidPackageURL` if the supplied URL doesn't end in `.shot`.
    public static func url(inPackage packageURL: URL) throws -> URL {
        guard packageURL.pathExtension == "shot" else {
            throw AnnotationsJSONError.invalidPackageURL
        }
        return packageURL.appendingPathComponent(Self.filename)
    }

    /// Encodes `doc` as pretty-printed, key-sorted JSON. Sorting + pretty-
    /// printing keeps the file human-diffable and — more importantly —
    /// byte-stable across runs so re-renders from `annotations.json` are
    /// reproducible (SPEC §5 I3 reads master + annotations.json).
    public func encode(_ doc: AnnotationsDocument) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try e.encode(doc)
        } catch {
            throw AnnotationsJSONError.codingFailure(error.localizedDescription)
        }
    }

    /// Decodes a document from raw JSON bytes.
    public func decode(_ data: Data) throws -> AnnotationsDocument {
        let d = JSONDecoder()
        do {
            return try d.decode(AnnotationsDocument.self, from: data)
        } catch {
            throw AnnotationsJSONError.codingFailure(error.localizedDescription)
        }
    }

    /// Writes `annotations.json` atomically inside the given `.shot/` package.
    /// Uses `Data.write(options: .atomic)` which is a separate-file-then-rename
    /// — callers that need package-level atomicity should compose with
    /// `ShotPackageWriter` during initial package creation.
    public func write(_ doc: AnnotationsDocument, intoPackage packageURL: URL) throws {
        let url = try Self.url(inPackage: packageURL)
        let bytes = try encode(doc)
        do {
            try bytes.write(to: url, options: [.atomic])
        } catch {
            throw AnnotationsJSONError.ioFailure(error.localizedDescription)
        }
    }

    /// Reads `annotations.json` from the given `.shot/` package. Returns an
    /// empty document if the file is missing — a legal state for a freshly-
    /// captured `.shot` that hasn't been annotated yet.
    public func read(fromPackage packageURL: URL) throws -> AnnotationsDocument {
        let url = try Self.url(inPackage: packageURL)
        if !FileManager.default.fileExists(atPath: url.path) {
            return AnnotationsDocument()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnnotationsJSONError.ioFailure(error.localizedDescription)
        }
        return try decode(data)
    }
}
