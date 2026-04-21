import AppKit
import Foundation

// Shotfuse Spike B — UTI + Spotlight + QuickLook harness.
//
// Subcommands:
//   bundle <stub-binary-path> <output-dir>   assembles ShotfuseSpikeApp.app
//                                            with UTI-declaring Info.plist
//   sample <output-dir>                      writes sample.shot/ with a unique
//                                            OCR marker string (printed on exit)

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(64) }

switch args[1] {
case "bundle":
    guard args.count == 4 else { usage(); exit(64) }
    try makeBundle(stubBinary: URL(fileURLWithPath: args[2]),
                   outputDir: URL(fileURLWithPath: args[3]))
case "sample":
    guard args.count == 3 else { usage(); exit(64) }
    try makeSample(outputDir: URL(fileURLWithPath: args[2]))
default:
    usage()
    exit(64)
}

func usage() {
    fputs("""
    usage:
      SpikeTool bundle <stub-binary-path> <output-dir>
      SpikeTool sample <output-dir>

    """, stderr)
}

// MARK: - Bundle assembly

func makeBundle(stubBinary: URL, outputDir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let appDir = outputDir.appendingPathComponent("ShotfuseSpikeApp.app", isDirectory: true)
    if fm.fileExists(atPath: appDir.path) { try fm.removeItem(at: appDir) }

    let contents = appDir.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

    try fm.copyItem(at: stubBinary, to: macOS.appendingPathComponent("ShotfuseSpikeApp"))

    try infoPlistData().write(to: contents.appendingPathComponent("Info.plist"))
    try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

    print("wrote bundle: \(appDir.path)")
}

func infoPlistData() throws -> Data {
    let plist: [String: Any] = [
        "CFBundleIdentifier": "dev.friquelme.shotfuse.spike.uti",
        "CFBundleName": "Shotfuse UTI Spike",
        "CFBundleExecutable": "ShotfuseSpikeApp",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleInfoDictionaryVersion": "6.0",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": true,
        "UTExportedTypeDeclarations": [
            [
                "UTTypeIdentifier": "dev.friquelme.shotfuse.shot",
                "UTTypeDescription": "Shotfuse Capture Package",
                "UTTypeConformsTo": ["com.apple.package", "public.composite-content"],
                "UTTypeTagSpecification": [
                    "public.filename-extension": ["shot"]
                ],
            ] as [String: Any],
        ],
    ]
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

// MARK: - Sample .shot generation

func makeSample(outputDir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let marker = "SHOTFUSE-SPIKE-OCR-\(UUID().uuidString)"
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let pkgName = "\(stamp)_dev.friquelme.shotfuse.spike.sample.shot"
    let pkg = outputDir.appendingPathComponent(pkgName, isDirectory: true)
    let tmp = outputDir.appendingPathComponent(pkgName + ".tmp", isDirectory: true)
    if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
    if fm.fileExists(atPath: pkg.path) { try fm.removeItem(at: pkg) }
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

    try writeManifest(to: tmp.appendingPathComponent("manifest.json"))
    try writeOCR(marker: marker, to: tmp.appendingPathComponent("ocr.json"))
    try writePNG(size: NSSize(width: 256, height: 256),
                 color: .systemOrange,
                 to: tmp.appendingPathComponent("master.png"))
    try writeJPG(size: NSSize(width: 64, height: 64),
                 color: .systemPurple,
                 to: tmp.appendingPathComponent("thumb.jpg"))

    try fm.moveItem(at: tmp, to: pkg)

    print("wrote sample package: \(pkg.path)")
    print("unique OCR marker:    \(marker)")
    print("")
    print("next:")
    print("  mdimport \"\(pkg.path)\"")
    print("  mdfind \"\(marker)\"")
    print("  qlmanage -p \"\(pkg.path)\"")
}

func writeManifest(to url: URL) throws {
    let manifest: [String: Any] = [
        "spec_version": 1,
        "id": UUID().uuidString,
        "created_at": ISO8601DateFormatter().string(from: Date()),
        "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)),
        "mode": "reference",
        "kind": "image",
        "master": ["path": "master.png", "width": 256, "height": 256, "dpi": 72] as [String: Any],
        "display": [
            "id": 0,
            "native_width": 256,
            "native_height": 256,
            "native_scale": 1.0,
            "localized_name": "Spike Display",
        ] as [String: Any],
        "pinned": false,
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func writeOCR(marker: String, to url: URL) throws {
    let ocr: [String: Any] = [
        "vision_version": "spike-b-0.0.0",
        "locale_hints": ["en-US"],
        "results": [
            [
                "text": marker,
                "bbox": [0, 0, 256, 32] as [Int],
                "confidence": 1.0,
                "lang": "en",
            ] as [String: Any],
            [
                "text": "Shotfuse Spike B — UTI + Spotlight test package",
                "bbox": [0, 32, 256, 32] as [Int],
                "confidence": 0.99,
                "lang": "en",
            ] as [String: Any],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: ocr, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func writePNG(size: NSSize, color: NSColor, to url: URL) throws {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor.white.setStroke()
    let path = NSBezierPath(rect: NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16))
    path.lineWidth = 4
    path.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SpikeTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

func writeJPG(size: NSSize, color: NSColor, to url: URL) throws {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
        throw NSError(domain: "SpikeTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "JPG encode failed"])
    }
    try data.write(to: url)
}
