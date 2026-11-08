// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GateEngineWorld",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "swift", targets: ["swift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/STREGAsGate/GateEngine.git", exact: "0.2.1"),
    ],
    targets: [
        .target(
            name: "WorldData",
        ),
        .executableTarget(
            name: "swift",
            dependencies: [
                .product(name: "GateEngine", package: "GateEngine"),
                "WorldData",
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "swiftTests",
            dependencies: ["WorldData"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
