// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShotfuseSpikeB",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ShotfuseSpikeApp"),
        .executableTarget(name: "SpikeTool"),
    ]
)
