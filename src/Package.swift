// swift-tools-version: 6.0
import PackageDescription

// Split into a thin executable plus a library so the interesting logic
// (command execution, template substitution, shell quoting) is reachable
// from a test target. A test target cannot reliably link an executable
// target's `main.swift` on macOS.
let package = Package(
    name: "Machook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Machook",
            targets: ["Machook"]
        )
    ],
    dependencies: [
        // Auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),

        // Local HTTP server that fronts the endpoints
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),

        // Official MCP Swift SDK — every endpoint is also exposed as a tool
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "Machook",
            dependencies: ["MachookCore"],
            path: "Sources/Machook",
            exclude: [
                "Resources/README.md"
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .target(
            name: "MachookCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MachookCore"
        ),
        .testTarget(
            name: "MachookCoreTests",
            dependencies: ["MachookCore"],
            path: "Tests/MachookCoreTests"
        )
    ]
)
