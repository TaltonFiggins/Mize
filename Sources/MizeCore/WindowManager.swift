import AppKit
import ApplicationServices

/// Private API exposed by ApplicationServices, used by every macOS window
/// manager (yabai, AeroSpace, Rectangle, etc.) to bridge AX elements ↔
/// CGWindowID. Stable since at least 10.10. Necessary because the public AX
/// API doesn't expose CGWindowID directly, but Quartz Window Services
/// (CGWindowListCopyWindowInfo) speaks CGWindowID and we use it to detect
/// cross-app z-order.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Manages real app windows on the current Space via the Accessibility API.
/// All operations run on the main actor since AX is a UI subsystem.
@MainActor
final class WindowManager {

    /// State of a single window captured at snapshot time. Restored on exit.
    struct WindowState: WindowIdentity {
        let cgWindowID: CGWindowID
        let axElement: AXUIElement
        let pid: pid_t
        let bundleID: String?
        let appName: String?
        let title: String?
        let originalPosition: CGPoint
        let originalSize: CGSize
        let wasMinimized: Bool
    }

    private(set) var snapshot: [WindowState] = []

    /// Original frames for windows the user opened AFTER snapshot time.
    /// We record them the first time we move/hide them so restoreSnapshot()
    /// can return them to their pre-Mize position on exit. Keyed by
    /// AXUIElement (compared with CFEqual; `===` doesn't work on CF types).
    private var extraOriginals: [(axElement: AXUIElement, position: CGPoint, size: CGSize)] = []

    // MARK: - Snapshot

    /// Walk every regular running app, enumerate its AX windows, and record
    /// each window's current position/size/minimized state for restoration.
    func snapshotCurrentWindows() {
        snapshot.removeAll()

        let myPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            if pid == myPID { continue }  // skip ourselves

            let appElement = AXUIElementCreateApplication(pid)
            guard let axWindows = Self.getWindows(of: appElement) else { continue }

            for axWindow in axWindows {
                guard let pos = Self.getPosition(of: axWindow),
                      let size = Self.getSize(of: axWindow) else { continue }
                let minimized = Self.isMinimized(axWindow)
                let title = Self.getTitle(of: axWindow)
                let cgWindowID = Self.getCGWindowID(of: axWindow) ?? 0

                snapshot.append(WindowState(
                    cgWindowID: cgWindowID,
                    axElement: axWindow,
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName,
                    title: title,
                    originalPosition: pos,
                    originalSize: size,
                    wasMinimized: minimized
                ))
            }
        }

        // Stable sort so cross-session "first match" lookups (when a pane's
        // CGWindowID is gone and only app-name matching survives) return the
        // same window each launch. Sort by app then title.
        snapshot.sort { lhs, rhs in
            let l = lhs.appName ?? ""
            let r = rhs.appName ?? ""
            if l != r { return l < r }
            return (lhs.title ?? "") < (rhs.title ?? "")
        }

        NSLog("Mize: snapshotted %d windows", snapshot.count)
    }

    /// Restore every window to its snapshotted state. Only changes attributes
    /// that actually differ from current state — avoids spurious side effects
    /// (focus shifts, un-minimize cascades) from no-op AX writes.
    func restoreSnapshot() {
        for state in snapshot {
            let nowMinimized = Self.isMinimized(state.axElement)
            if nowMinimized != state.wasMinimized {
                setMinimized(state.axElement, state.wasMinimized, label: state.title ?? "?")
            }
            // Skip position/size if window is (and should remain) minimized —
            // moving a minimized window has no visible effect but triggers AX work.
            if state.wasMinimized { continue }

            let curPos = Self.getPosition(of: state.axElement) ?? .zero
            let curSize = Self.getSize(of: state.axElement) ?? .zero
            if curPos != state.originalPosition {
                move(state.axElement, to: state.originalPosition, label: state.title ?? "?")
            }
            if curSize != state.originalSize {
                resize(state.axElement, to: state.originalSize, label: state.title ?? "?")
            }
        }
        // Also restore windows opened AFTER the startup snapshot. We captured
        // their original position the first time we moved them off-screen;
        // without this they'd be left at (-32000, -32000) on exit.
        for extra in extraOriginals {
            // Unminimize first if we minimized it.
            if Self.isMinimized(extra.axElement) {
                setMinimized(extra.axElement, false, label: "(extra)")
            }
            let curPos = Self.getPosition(of: extra.axElement) ?? .zero
            let curSize = Self.getSize(of: extra.axElement) ?? .zero
            if curPos != extra.position {
                move(extra.axElement, to: extra.position, label: "(extra)")
            }
            if curSize != extra.size {
                resize(extra.axElement, to: extra.size, label: "(extra)")
            }
        }
        NSLog("Mize: restored %d windows (+%d extras)", snapshot.count, extraOriginals.count)
    }

    /// Live AX enumeration of every window currently owned by the given PIDs.
    /// Unlike `snapshot`, this catches windows opened after Mize startup —
    /// essential for hiding non-pane windows in `activateScene`.
    func liveWindows(for pids: Set<pid_t>) -> [(pid: pid_t, axElement: AXUIElement, cgWindowID: CGWindowID)] {
        var result: [(pid_t, AXUIElement, CGWindowID)] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            guard let windows = Self.getWindows(of: app) else { continue }
            for w in windows {
                let id = Self.getCGWindowID(of: w) ?? 0
                result.append((pid, w, id))
            }
        }
        return result
    }

    /// Record an AX element's current frame so `restoreSnapshot()` can put it
    /// back later, IF it isn't already covered by the startup snapshot.
    /// Idempotent — repeated calls with the same element are no-ops.
    func captureExtraIfNew(_ axElement: AXUIElement) {
        if snapshot.contains(where: { CFEqual($0.axElement, axElement) }) { return }
        if extraOriginals.contains(where: { CFEqual($0.axElement, axElement) }) { return }
        guard let pos = Self.getPosition(of: axElement),
              let size = Self.getSize(of: axElement) else { return }
        extraOriginals.append((axElement, pos, size))
    }

    // MARK: - Operations

    @discardableResult
    func move(_ axWindow: AXUIElement, to position: CGPoint, label: String = "") -> AXError {
        var p = position
        guard let posRef = AXValueCreate(.cgPoint, &p) else { return .failure }
        let err = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posRef)
        if err != .success {
            NSLog("Mize: move(%@) failed: %d", label, err.rawValue)
        }
        return err
    }

    @discardableResult
    func resize(_ axWindow: AXUIElement, to size: CGSize, label: String = "") -> AXError {
        var s = size
        guard let sizeRef = AXValueCreate(.cgSize, &s) else { return .failure }
        let err = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeRef)
        if err != .success {
            NSLog("Mize: resize(%@) failed: %d", label, err.rawValue)
        }
        return err
    }

    func setFrame(_ axWindow: AXUIElement, to rect: CGRect, label: String = "") {
        move(axWindow, to: rect.origin, label: label)
        resize(axWindow, to: rect.size, label: label)
    }

    func raise(_ axWindow: AXUIElement, label: String = "") {
        let err = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        if err != .success {
            NSLog("Mize: raise(%@) failed: %d", label, err.rawValue)
        }
    }

    @discardableResult
    func setMinimized(_ axWindow: AXUIElement, _ minimized: Bool, label: String = "") -> AXError {
        let err = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            minimized as CFBoolean
        )
        if err != .success {
            NSLog("Mize: setMinimized(%@, %@) failed: %d", label, minimized ? "true" : "false", err.rawValue)
        }
        return err
    }

    // MARK: - AX helpers

    private static func getWindows(of app: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    /// Public position read — used by callers to verify moves took effect.
    static func currentPosition(of window: AXUIElement) -> CGPoint? {
        return getPosition(of: window)
    }

    /// Public size read.
    static func currentSize(of window: AXUIElement) -> CGSize? {
        return getSize(of: window)
    }

    private static func getPosition(of window: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &p)
        return p
    }

    private static func getSize(of window: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var s = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &s)
        return s
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let val = ref else { return false }
        // CFBoolean doesn't reliably bridge to Bool via `as?` — go through NSNumber.
        return (val as? NSNumber)?.boolValue ?? false
    }

    private static func getTitle(of window: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func getCGWindowID(of window: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success else { return nil }
        return windowID == 0 ? nil : windowID
    }
}
