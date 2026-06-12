import AppKit
import Foundation

// Standalone test runner. Swift Testing and XCTest both require a full Xcode
// install — they aren't shipped with Command Line Tools — so we roll a tiny
// runner instead. Run with `swift run MizeTests`; exits non-zero if any test
// fails. Suites live in sibling files; shared asserts in TestHarness.swift.

@main
@MainActor
struct TestRunner {
    static func main() {
        print("Mize test suite")
        runGeometryTests()
        runMatchingTests()
        runSceneTests()
        runSceneStoreTests()
        TestHarness.finish()
    }
}
