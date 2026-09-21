// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipFarm",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ClipFarm",
            path: "Sources/ClipFarm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
