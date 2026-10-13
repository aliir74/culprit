// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Culprit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The attribution engine. Pinned to a revision: upstream has no tagged releases.
        .package(url: "https://github.com/mbrummerstedt/claude-top.git",
                 revision: "d088212"),
    ],
    targets: [
        .executableTarget(
            name: "Culprit",
            dependencies: [.product(name: "ClaudeTopKit", package: "claude-top")]
        ),
    ]
)
