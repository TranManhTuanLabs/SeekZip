// swift-tools-version: 5.10
import PackageDescription

// NOTE: SeekZipApp (SwiftUI GUI) is intentionally NOT a SwiftPM target
// here. Its @State macros need the SwiftUIMacros plugin that ships with
// full Xcode; with Command Line Tools only, `swift build` fails with
// "SwiftUIMacros.StateMacro could not be found". The GUI source stays in
// Sources/SeekZipApp/ and will be built by an Xcode project (M7).
// SwiftPM builds core + CLI + MCP + tests only.
let package = Package(
    name: "SeekZip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeekZipCore", targets: ["SeekZipCore"]),
        .executable(name: "seekzip", targets: ["SeekZipCLI"]),
        .executable(name: "seekzip-mcp", targets: ["SeekZipMCP"]),
    ],
    targets: [
        .target(name: "SeekZipCore"),
        .executableTarget(name: "SeekZipCLI", dependencies: ["SeekZipCore"]),
        .executableTarget(name: "SeekZipMCP", dependencies: ["SeekZipCore"]),
        .testTarget(name: "SeekZipCoreTests", dependencies: ["SeekZipCore"]),
    ]
)
