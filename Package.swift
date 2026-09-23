// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MusicIsland", path: "Sources/MusicIsland")
    ]
)
