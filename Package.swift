// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mize",
    platforms: [.macOS(.v14)],
    targets: [
        // The actual scene/window/editor implementation, as a library so
        // it can be reused from both the app and the test runner.
        .target(name: "MizeCore"),
        // Thin executable wrapper — just calls into MizeCore.
        .executableTarget(name: "Mize", dependencies: ["MizeCore"]),
        // Test runner. Swift Testing / XCTest aren't shipped with Command
        // Line Tools alone (they require Xcode), so we roll our own runner
        // here as an executable. Run with `swift run MizeTests`. Exits
        // non-zero on any failure.
        .executableTarget(
            name: "MizeTests",
            dependencies: ["MizeCore"],
            path: "Tests/MizeTests"
        ),
    ]
)
