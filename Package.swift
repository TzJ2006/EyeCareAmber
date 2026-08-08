// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Amber",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Amber",
            path: "Sources/Amber",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
