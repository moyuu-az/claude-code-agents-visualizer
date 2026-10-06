// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeAgentsVisualizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentsVisualizer", targets: ["AgentsVisualizer"]),
    ],
    targets: [
        // Pure data layer: reads Claude Code / Claude Desktop state from disk. No UI, fully unit-tested.
        .target(name: "AgentsVisualizerCore"),
        .executableTarget(name: "AgentsVisualizer", dependencies: ["AgentsVisualizerCore"]),
        .testTarget(name: "AgentsVisualizerCoreTests", dependencies: ["AgentsVisualizerCore"]),
    ]
)
