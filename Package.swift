// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeOMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeOMeter",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClaudeOMeterReport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeOMeterTests",
            dependencies: ["ClaudeOMeter"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
