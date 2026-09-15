// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionSearch",
    // @Observable（Observation 框架）需要 macOS 14
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSessionSearch",
            path: "Sources"
        )
    ]
)
