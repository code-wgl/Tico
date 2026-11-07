// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tic",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1"))
    ],
    targets: [
        .executableTarget(
            name: "Tic",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TicTests",
            dependencies: [
                "Tic",
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
