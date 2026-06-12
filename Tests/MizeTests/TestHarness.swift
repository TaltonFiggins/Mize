import Foundation

/// Shared state for the roll-your-own test runner (see main.swift for why
/// XCTest isn't used). Failures no longer abort the run — every test
/// executes, failures are reported per-assertion, and `finish()` exits
/// non-zero if anything failed.
@MainActor
enum TestHarness {
    private(set) static var ran = 0
    private(set) static var failed = 0
    private static var notes: [String] = []

    static func suite(_ name: String) {
        print("\n— \(name)")
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        ran += 1
        notes = []
        do {
            try body()
        } catch {
            record("threw: \(error)", file: #file, line: #line)
        }
        if notes.isEmpty {
            print("✓ \(name)")
        } else {
            failed += 1
            print("✗ \(name)")
            for note in notes { print("    \(note)") }
        }
    }

    static func record(_ msg: String, file: StaticString, line: UInt) {
        notes.append("[\(file):\(line)] \(msg)")
    }

    static func finish() -> Never {
        if failed > 0 {
            print("\n\(ran - failed) passed, \(failed) FAILED")
            exit(1)
        }
        print("\n✓ All \(ran) tests passed")
        exit(0)
    }
}

// MARK: - Free-function shims used by the test suites

@MainActor func test(_ name: String, _ body: () throws -> Void) {
    TestHarness.test(name, body)
}

@MainActor func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "",
                                          file: StaticString = #file, line: UInt = #line) {
    if a != b { TestHarness.record("\(msg) — expected \(b), got \(a)", file: file, line: line) }
}

@MainActor func assertTrue(_ cond: Bool, _ msg: String = "",
                           file: StaticString = #file, line: UInt = #line) {
    if !cond { TestHarness.record(msg.isEmpty ? "assertTrue failed" : msg, file: file, line: line) }
}

@MainActor func assertFalse(_ cond: Bool, _ msg: String = "",
                            file: StaticString = #file, line: UInt = #line) {
    if cond { TestHarness.record(msg.isEmpty ? "assertFalse failed" : msg, file: file, line: line) }
}

@MainActor func assertNil<T>(_ value: T?, _ msg: String = "",
                             file: StaticString = #file, line: UInt = #line) {
    if value != nil {
        TestHarness.record("\(msg) — expected nil, got \(String(describing: value!))", file: file, line: line)
    }
}

@MainActor func assertNotNil<T>(_ value: T?, _ msg: String = "",
                                file: StaticString = #file, line: UInt = #line) {
    if value == nil { TestHarness.record("\(msg) — expected non-nil", file: file, line: line) }
}

@MainActor func assertApprox(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001, _ msg: String = "",
                             file: StaticString = #file, line: UInt = #line) {
    if abs(a - b) > tolerance {
        TestHarness.record("\(msg) — expected \(b) ± \(tolerance), got \(a)", file: file, line: line)
    }
}

@MainActor func assertApprox(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.001, _ msg: String = "",
                             file: StaticString = #file, line: UInt = #line) {
    if abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
        || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance {
        TestHarness.record("\(msg) — expected \(b) ± \(tolerance), got \(a)", file: file, line: line)
    }
}
