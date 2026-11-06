// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SeekZip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeekZipCore", targets: ["SeekZipCore"]),
        .executable(name: "seekzip", targets: ["SeekZipCLI"]),
        .executable(name: "seekzip-mcp", targets: ["SeekZipMCP"]),
        .executable(name: "SeekZipApp", targets: ["SeekZipApp"]),
    ],
    targets: [
        .target(name: "SeekZipCore"),
        .executableTarget(name: "SeekZipCLI", dependencies: ["SeekZipCore"]),
        .executableTarget(name: "SeekZipMCP", dependencies: ["SeekZipCore"]),
        .executableTarget(name: "SeekZipApp", dependencies: ["SeekZipCore"]),
        .testTarget(name: "SeekZipCoreTests", dependencies: ["SeekZipCore"]),
    ]
)
