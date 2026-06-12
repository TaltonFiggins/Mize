import CoreGraphics
import Foundation

/// Minimal identity of an on-screen window, for pane↔window matching.
/// `WindowManager.WindowState` conforms; tests use a lightweight stub.
protocol WindowIdentity {
    var appName: String? { get }
    var title: String? { get }
    var cgWindowID: CGWindowID { get }
}

extension WindowIdentity {
    /// Key used by the editor to tie row controls back to windows across
    /// refreshes. App + title, not CGWindowID, so a row survives the window
    /// being closed and reopened mid-edit.
    var fingerprint: String { "\(appName ?? "?")|\(title ?? "")" }
}

/// One row of CGWindowListCopyWindowInfo, reduced to the fields z-ordering
/// needs. Array order is front-to-back, as Quartz returns it.
struct ZOrderEntry {
    let windowNumber: CGWindowID?
    let ownerName: String?
    let title: String?

    init(windowNumber: CGWindowID?, ownerName: String?, title: String?) {
        self.windowNumber = windowNumber
        self.ownerName = ownerName
        self.title = title
    }
}

extension Pane {

    /// Loose match: case-insensitive app-name substring, plus title substring
    /// when the pane has a non-empty `titleContains`.
    func looselyMatches(appName: String?, title: String?) -> Bool {
        guard let app = appName?.lowercased(),
              app.contains(appNameContains.lowercased()) else { return false }
        if let tc = titleContains, !tc.isEmpty {
            return title?.lowercased().contains(tc.lowercased()) ?? false
        }
        return true
    }

    /// Whether this pane refers to the given window.
    ///
    /// If the pane was saved with a CGWindowID, match ONLY by that ID —
    /// otherwise sibling windows of the same app (Ghostty terminals, Brave
    /// tabs) with similar titles all light up as "this pane," making it look
    /// like adding one window adds them all.
    ///
    /// Falls back to app+title only for untyped panes (old JSON / first run /
    /// panes whose stored title may have drifted from the current window
    /// title, e.g. Slack channel switches).
    func corresponds(to window: some WindowIdentity) -> Bool {
        if let id = cgWindowID, id != 0 {
            return id == window.cgWindowID
        }
        return looselyMatches(appName: window.appName, title: window.title)
    }

    /// Resolve this pane to the best of `windows` via three tiers:
    /// 1. Session-scoped CGWindowID (exact, immune to title changes)
    /// 2. App name + title substring (across-session, if title hasn't drifted)
    /// 3. App name only (last-resort fallback)
    func resolve<W: WindowIdentity>(in windows: [W]) -> W? {
        if let id = cgWindowID, id != 0,
           let match = windows.first(where: { $0.cgWindowID == id })
        {
            return match
        }
        let appNeedle = appNameContains.lowercased()
        if let tc = titleContains?.lowercased(), !tc.isEmpty {
            let strict = windows.first { w in
                guard let app = w.appName?.lowercased(), app.contains(appNeedle) else { return false }
                guard let title = w.title?.lowercased() else { return false }
                return title.contains(tc)
            }
            if let strict { return strict }
        }
        return windows.first { w in
            guard let app = w.appName?.lowercased() else { return false }
            return app.contains(appNeedle)
        }
    }

    /// Index of this pane's window in a front-to-back window list.
    /// `Int.max` when absent, so missing windows sort to the back.
    /// Prefers CGWindowID when set (immune to title changes from channel
    /// switching, etc.), but unlike `corresponds(to:)` falls through to the
    /// loose match when the ID isn't in the list — a stale ID shouldn't cost
    /// the pane its z-position.
    func zOrderIndex(in windowList: [ZOrderEntry]) -> Int {
        if let id = cgWindowID, id != 0,
           let idx = windowList.firstIndex(where: { $0.windowNumber == id })
        {
            return idx
        }
        if let idx = windowList.firstIndex(where: {
            looselyMatches(appName: $0.ownerName, title: $0.title ?? "")
        }) {
            return idx
        }
        return Int.max
    }

    /// Layout equality — app, title, frame. Deliberately ignores
    /// `cgWindowID`, which is session-scoped and opportunistically upgraded;
    /// an ID-only difference must not count as a scene change.
    func layoutEquals(_ other: Pane) -> Bool {
        appNameContains == other.appNameContains
            && titleContains == other.titleContains
            && frame == other.frame
    }

    static func layoutsEqual(_ a: [Pane], _ b: [Pane]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.layoutEquals($1) }
    }
}

/// Filtering rules for which snapshot windows the editor offers as
/// scene-pane candidates.
enum EditorCandidates {

    /// System UI owners that show up in the AX snapshot but make no sense as
    /// presentation panes.
    static let skipBundlePrefixes = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.finder",
        "com.apple.wallpaper", "com.apple.screencaptureui",
    ]

    /// Whether a snapshot window should be offered in the editor's window
    /// list. Skips system UI, Mize itself, minimized windows, untitled
    /// windows (palettes, hidden helpers), and tiny windows (tooltips,
    /// status popovers).
    static func isCandidate(
        bundleID: String?,
        title: String?,
        isMinimized: Bool,
        size: CGSize,
        ownBundleID: String?
    ) -> Bool {
        guard let bid = bundleID?.lowercased() else { return false }
        var skip = skipBundlePrefixes
        if let own = ownBundleID, !own.isEmpty { skip.append(own) }
        guard !skip.contains(where: { bid.hasPrefix($0.lowercased()) }) else { return false }
        guard !isMinimized else { return false }
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        return size.width >= 200 && size.height >= 200
    }
}
