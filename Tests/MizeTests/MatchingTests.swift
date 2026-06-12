import CoreGraphics
import Foundation
@testable import MizeCore

/// Lightweight stand-in for WindowManager.WindowState in matching tests.
private struct StubWindow: WindowIdentity {
    let appName: String?
    let title: String?
    let cgWindowID: CGWindowID
}

@MainActor
func runMatchingTests() {
    TestHarness.suite("Pane ↔ window matching")

    let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    test("ID-bound pane corresponds only to the window with that ID") {
        let pane = Pane(appNameContains: "Ghostty", titleContains: "dev", frame: frame, cgWindowID: 42)
        let target = StubWindow(appName: "Ghostty", title: "dev — zsh", cgWindowID: 42)
        let sibling = StubWindow(appName: "Ghostty", title: "dev — vim", cgWindowID: 43)
        assertTrue(pane.corresponds(to: target))
        assertFalse(pane.corresponds(to: sibling),
                    "sibling with matching app+title must NOT match an ID-bound pane")
    }

    test("untyped pane falls back to loose app+title matching") {
        let pane = Pane(appNameContains: "brave", titleContains: "github", frame: frame)
        assertTrue(pane.corresponds(to: StubWindow(appName: "Brave Browser", title: "GitHub — PR #5", cgWindowID: 7)),
                   "app and title substrings are case-insensitive")
        assertFalse(pane.corresponds(to: StubWindow(appName: "Brave Browser", title: "Hacker News", cgWindowID: 8)))
        assertFalse(pane.corresponds(to: StubWindow(appName: "Safari", title: "GitHub", cgWindowID: 9)))
    }

    test("untyped pane with no titleContains matches on app alone") {
        let pane = Pane(appNameContains: "Notes", titleContains: nil, frame: frame)
        assertTrue(pane.corresponds(to: StubWindow(appName: "Notes", title: "Anything", cgWindowID: 1)))
        let emptyTitle = Pane(appNameContains: "Notes", titleContains: "", frame: frame)
        assertTrue(emptyTitle.corresponds(to: StubWindow(appName: "Notes", title: nil, cgWindowID: 2)),
                   "empty titleContains behaves like nil")
    }

    test("resolve prefers CGWindowID over a better title match") {
        let pane = Pane(appNameContains: "Ghostty", titleContains: "Setup", frame: frame, cgWindowID: 42)
        let byTitle = StubWindow(appName: "Ghostty", title: "Setup", cgWindowID: 1)
        let byID = StubWindow(appName: "Ghostty", title: "totally different now", cgWindowID: 42)
        assertEqual(pane.resolve(in: [byTitle, byID])?.cgWindowID, 42)
    }

    test("resolve falls back ID → app+title → app-only") {
        // Stale ID (window closed): tier 2 finds the title match.
        let stale = Pane(appNameContains: "Ghostty", titleContains: "Setup", frame: frame, cgWindowID: 9999)
        let titled = StubWindow(appName: "Ghostty", title: "Setup — zsh", cgWindowID: 1)
        let other = StubWindow(appName: "Ghostty", title: "scratch", cgWindowID: 2)
        assertEqual(stale.resolve(in: [other, titled])?.cgWindowID, 1)

        // Title drifted too: tier 3 takes the first app-name match.
        let drifted = Pane(appNameContains: "Ghostty", titleContains: "gone", frame: frame, cgWindowID: 9999)
        assertEqual(drifted.resolve(in: [other, titled])?.cgWindowID, 2)

        // No window of that app at all.
        let missing = Pane(appNameContains: "Xcode", titleContains: nil, frame: frame)
        assertNil(missing.resolve(in: [other, titled]))
    }

    test("zOrderIndex finds by ID, falls back loose, Int.max when absent") {
        let list = [
            ZOrderEntry(windowNumber: 10, ownerName: "Brave Browser", title: "GitHub"),
            ZOrderEntry(windowNumber: 20, ownerName: "Notes", title: "My notes"),
            ZOrderEntry(windowNumber: nil, ownerName: "Ghostty", title: nil),
        ]
        let byID = Pane(appNameContains: "Notes", titleContains: nil, frame: frame, cgWindowID: 20)
        assertEqual(byID.zOrderIndex(in: list), 1)

        // Stale ID falls through to the loose match (unlike corresponds).
        let staleID = Pane(appNameContains: "Brave", titleContains: "github", frame: frame, cgWindowID: 9999)
        assertEqual(staleID.zOrderIndex(in: list), 0)

        // Pane wants a title but the entry has none → no match on that entry.
        let titleOnUntitled = Pane(appNameContains: "Ghostty", titleContains: "Setup", frame: frame)
        assertEqual(titleOnUntitled.zOrderIndex(in: list), Int.max)

        let absent = Pane(appNameContains: "Xcode", titleContains: nil, frame: frame)
        assertEqual(absent.zOrderIndex(in: list), Int.max)
    }

    test("sorting by descending zOrderIndex puts the frontmost pane last") {
        let list = [
            ZOrderEntry(windowNumber: 1, ownerName: "Front App", title: "front"),
            ZOrderEntry(windowNumber: 2, ownerName: "Back App", title: "back"),
        ]
        let front = Pane(appNameContains: "Front App", titleContains: nil, frame: frame)
        let back = Pane(appNameContains: "Back App", titleContains: nil, frame: frame)
        let missing = Pane(appNameContains: "Hidden App", titleContains: nil, frame: frame)
        let sorted = [front, missing, back].sorted {
            $0.zOrderIndex(in: list) > $1.zOrderIndex(in: list)
        }
        assertEqual(sorted.map(\.appNameContains), ["Hidden App", "Back App", "Front App"],
                    "panes[last] must be the frontmost window")
    }

    test("layoutEquals ignores cgWindowID, layoutsEqual checks count") {
        let a = Pane(appNameContains: "Notes", titleContains: "x", frame: frame, cgWindowID: 1)
        let b = Pane(appNameContains: "Notes", titleContains: "x", frame: frame, cgWindowID: 2)
        assertTrue(a.layoutEquals(b), "an ID-only difference must not count as a scene change")
        let c = Pane(appNameContains: "Notes", titleContains: "x",
                     frame: CGRect(x: 1, y: 0, width: 800, height: 600))
        assertFalse(a.layoutEquals(c))
        assertTrue(Pane.layoutsEqual([a], [b]))
        assertFalse(Pane.layoutsEqual([a], [a, b]))
        assertTrue(Pane.layoutsEqual([], []))
    }

    test("fingerprint is app|title with ? for a missing app name") {
        assertEqual(StubWindow(appName: "Notes", title: "My notes", cgWindowID: 1).fingerprint,
                    "Notes|My notes")
        assertEqual(StubWindow(appName: nil, title: nil, cgWindowID: 1).fingerprint, "?|")
    }

    TestHarness.suite("EditorCandidates")

    let okSize = CGSize(width: 800, height: 600)

    test("accepts a normal app window") {
        assertTrue(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "GitHub", isMinimized: false,
            size: okSize, ownBundleID: "dev.mize.app"))
    }

    test("skips system UI, Mize itself, and nil bundle IDs") {
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.apple.dock", title: "Dock", isMinimized: false,
            size: okSize, ownBundleID: nil))
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.apple.finder", title: "Desktop", isMinimized: false,
            size: okSize, ownBundleID: nil))
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "dev.mize.app", title: "Mize Editor", isMinimized: false,
            size: okSize, ownBundleID: "dev.mize.app"))
        assertFalse(EditorCandidates.isCandidate(
            bundleID: nil, title: "Mystery", isMinimized: false,
            size: okSize, ownBundleID: nil))
    }

    test("nil ownBundleID must not skip every window") {
        // Regression: the old filter appended `Bundle.main.bundleIdentifier ?? ""`
        // to the skip list, and hasPrefix("") matches EVERY bundle ID — so when
        // run outside an .app bundle the editor offered no windows at all.
        assertTrue(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "GitHub", isMinimized: false,
            size: okSize, ownBundleID: nil))
    }

    test("skips minimized, untitled, and tiny windows") {
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "GitHub", isMinimized: true,
            size: okSize, ownBundleID: nil), "minimized")
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "  ", isMinimized: false,
            size: okSize, ownBundleID: nil), "whitespace title")
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: nil, isMinimized: false,
            size: okSize, ownBundleID: nil), "nil title")
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "Popover", isMinimized: false,
            size: CGSize(width: 199, height: 600), ownBundleID: nil), "too narrow")
        assertFalse(EditorCandidates.isCandidate(
            bundleID: "com.brave.Browser", title: "Popover", isMinimized: false,
            size: CGSize(width: 600, height: 199), ownBundleID: nil), "too short")
    }
}
