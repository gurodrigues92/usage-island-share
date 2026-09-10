// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageIsland", targets: ["UsageIsland"])
    ],
    targets: [
        .executableTarget(
            name: "UsageIsland",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "UsageIslandTests",
            dependencies: ["UsageIsland"]
        )
    ]
)
