import AppKit
import ApplicationServices

public enum PresentationApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Mize-owned windows
    private var mainCurtain: NSWindow?     // .normal - 1, covers wallpaper
    private var topChromeCover: NSWindow?  // very high level, covers menu bar
    private var botChromeCover: NSWindow?  // very high level, covers dock
    // Each Mize window gets its own CurtainView so backgroundColor changes
    // reliably trigger a redraw (NSWindow.backgroundColor caches in ways that
    // skip redraws on borderless opaque windows).
    private var mainCurtainView: CurtainView?
    private var topCurtainView: CurtainView?
    private var botCurtainView: CurtainView?
    private var editorPanel: EditorPanel?

    // Input
    private var keyMonitorLocal: Any?
    private var keyMonitorGlobal: Any?
    private var mouseMoveMonitorLocal: Any?
    private var mouseMoveMonitorGlobal: Any?
    private var cursorHideTimer: Timer?
    /// CGDisplayHideCursor / ShowCursor stack per-process — every hide
    /// needs a matching show. Gate behind this so back-to-back idles
    /// don't leave the show count negative.
    private var isCursorHidden = false
    /// Idle delay before the cursor hides itself. 2s is short enough to feel
    /// snappy during a talk but long enough that small adjustments don't
    /// flicker the cursor.
    private let cursorIdleDelay: TimeInterval = 2.0

    // State
    private let windowManager = WindowManager()
    private var sceneStore = SceneStore(at: SceneStore.defaultURL)
    private var scenes: [Scene] = []
    private var currentScene = 0
    /// PIDs of apps that were visible (not hidden) at session start. On exit
    /// we unhide all of them so we don't leak user state.
    private var originalVisibleApps: Set<pid_t> = []
    private var isInEditMode = false
    private var isTransitioning = false
    // Chrome cover heights computed once at startup so scene-canvas math stays
    // consistent with where the chrome bars actually are.
    private var topGap: CGFloat = 0
    private var botGap: CGFloat = 0

    /// AX-coord canvas: the area between the top + bottom chrome covers.
    /// All pane frames are clamped to this so windows never render under
    /// the bars.
    private var canvas: CGRect {
        guard let screen = NSScreen.main else { return .zero }
        return CGRect(
            x: 0,
            y: topGap,
            width: screen.frame.width,
            height: screen.frame.height - topGap - botGap
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            fputs("No main screen — exiting.\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let ax = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        if !ax {
            NSLog("Mize: enable Accessibility in System Settings → Privacy & Security → Accessibility, then relaunch.")
            NSApp.terminate(nil)
            return
        }

        installMizeWindows(on: screen)
        installKeyMonitors()
        installCursorAutoHide()

        // Suppress system chrome whenever Mize is active. (Chrome covers above
        // handle the case when a target app is active and chrome wants to bleed
        // through.)
        NSApp.presentationOptions = [
            .hideMenuBar,
            .hideDock,
            .disableHideApplication,
            .disableAppleMenu,
        ]
        NSApp.activate(ignoringOtherApps: true)

        windowManager.snapshotCurrentWindows()

        // Capture which apps were visible at startup so we can unhide them
        // (and only them) on exit.
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != myPID else { continue }
            if !app.isHidden {
                originalVisibleApps.insert(app.processIdentifier)
            }
        }

        loadAndWatchCurrentStore(seedScene: { makeDemoScenes(screen: screen) })

        activateScene(at: currentScene)

        NSLog("Mize presenting on %@ — ←/→ paginate, ⌘, edit config, ESC exit.", screen.localizedName)
    }

    // MARK: - Mize windows

    private func installMizeWindows(on screen: NSScreen) {
        // Top must cover menu bar + notch. Use safeAreaInsets.top when
        // available (macOS 13+) since it accounts for the camera notch on
        // MacBook Pro displays; otherwise fall back to visibleFrame-derived
        // inset with a small padding to catch any styling overhang.
        let frame = screen.frame
        let visible = screen.visibleFrame
        let actualTopGap = frame.maxY - visible.maxY
        let actualBotGap = visible.minY - frame.minY
        let botGapLocal = actualBotGap > 0 ? actualBotGap : 0
        // System metrics under-report what's actually needed visually on
        // notched MBPs (NSStatusBar.thickness=22, safeAreaInsets.top=32,
        // visibleFrame inset=33 — all leave a visible bar). 63pt has been
        // empirically confirmed to cover the menu bar fully on this display.
        // Compromise default; we'll make this user-adjustable next iteration.
        let topGapLocal: CGFloat = max(actualTopGap, 63)
        self.topGap = topGapLocal
        self.botGap = botGapLocal
        let topGap = topGapLocal
        let botGap = botGapLocal

        // Chrome covers need to be above the system menu bar. macOS 14+
        // renders the menu bar above .mainMenu/.statusBar window levels, so
        // we use one notch below CGShieldingWindowLevel (the level used for
        // login window and screen saver) — high enough to cover everything
        // except those system-reserved layers.
        let chromeCoverLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)

        // NSWindow uses lower-left origin in screen coords. Top chrome covers
        // the menu bar strip (top of screen); bot chrome covers the dock strip.
        let topFrame = NSRect(x: 0, y: frame.maxY - topGap, width: frame.width, height: topGap)
        let botFrame = NSRect(x: 0, y: 0, width: frame.width, height: botGap)

        mainCurtain = makeMizeWindow(
            on: screen,
            frame: frame,
            level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1),
            label: "mainCurtain"
        )
        topChromeCover = makeMizeWindow(on: screen, frame: topFrame, level: chromeCoverLevel, label: "topChromeCover")
        botChromeCover = makeMizeWindow(on: screen, frame: botFrame, level: chromeCoverLevel, label: "botChromeCover")

        mainCurtainView = installCurtainView(in: mainCurtain, size: frame.size)
        topCurtainView = installCurtainView(in: topChromeCover, size: topFrame.size)
        botCurtainView = installCurtainView(in: botChromeCover, size: botFrame.size)

        // Wire main curtain text-drag persistence into the scene store.
        mainCurtainView?.onTextMoved = { [weak self] index, newPosition in
            guard let self, self.currentScene < self.scenes.count else { return }
            var texts = self.scenes[self.currentScene].texts
            guard index < texts.count else { return }
            texts[index] = texts[index].moved(to: newPosition)
            self.scenes[self.currentScene] = self.scenes[self.currentScene].with(texts: texts)
            self.sceneStore.save(self.scenes)
        }
    }

    private func installCurtainView(in window: NSWindow?, size: CGSize) -> CurtainView? {
        guard let window else { return nil }
        let view = CurtainView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return view
    }

    private func makeMizeWindow(on screen: NSScreen, frame: NSRect, level: NSWindow.Level, label: String) -> NSWindow {
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.level = level
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true  // clicks pass through to whatever's below
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.setFrame(frame, display: true)
        w.orderFrontRegardless()
        return w
    }

    // MARK: - Input

    private func installKeyMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let char = event.charactersIgnoringModifiers
            if cmd, char == "," { self.openConfigInEditor(); return }
            if cmd, char == "e" { self.toggleEditor(); return }
            if cmd, char == "o" { self.openScenesFile(); return }
            if cmd, shift, char?.lowercased() == "s" { self.saveScenesAs(); return }
            switch event.keyCode {
            case 53: self.shutdown()                     // ESC
            case 121: self.advanceScene()                // PageDown
            case 116: self.retreatScene()                // PageUp
            case 124 where cmd: self.advanceScene()      // Cmd+→
            case 123 where cmd: self.retreatScene()      // Cmd+←
            default: break
            }
        }
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let fr = NSApp.keyWindow?.firstResponder
            let isEditingText = (fr is NSTextView) || (fr is NSText)
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let char = event.charactersIgnoringModifiers
            // If a text input has focus, only intercept the editor toggle
            // (Cmd+E) — everything else (typing, Cmd+arrow text nav, Cmd+S)
            // belongs to the text field.
            if isEditingText {
                if cmd, char == "e" {
                    self?.toggleEditor()
                    return nil
                }
                return event
            }
            handler(event)
            if cmd && (char == "," || char == "e" || char == "o") { return nil }
            if cmd && shift && char?.lowercased() == "s" { return nil }
            switch event.keyCode {
            case 53, 121, 116: return nil                          // ESC / PgDn / PgUp
            case 124 where cmd, 123 where cmd: return nil          // Cmd+arrow
            default: return event                                  // plain arrows pass through
            }
        }
    }

    private func openConfigInEditor() {
        NSWorkspace.shared.open(sceneStore.url)
    }

    // MARK: - Cursor auto-hide

    /// Wire up global + local mouse-moved (and dragged) monitors so the
    /// cursor hides itself after `cursorIdleDelay` seconds of stillness.
    /// Both monitors are needed: global fires for events going to other
    /// apps (e.g., the foregrounded target app); local fires for events
    /// hitting Mize's own windows (curtain in edit mode, editor panel).
    private func installCursorAutoHide() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        mouseMoveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.noteCursorMovement()
        }
        mouseMoveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.noteCursorMovement()
            return event
        }
        // Schedule the initial hide so a fresh launch with no mouse motion
        // still hides the cursor.
        noteCursorMovement()
    }

    private func noteCursorMovement() {
        // Real mouse motion → unhide immediately.
        if isCursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            isCursorHidden = false
        }
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: cursorIdleDelay, repeats: false) { [weak self] _ in
            // Timer fires on the main run loop, so we're already on the
            // main thread — assumeIsolated lets us call the MainActor
            // method synchronously without a Task hop.
            MainActor.assumeIsolated {
                self?.hideCursorIfStill()
            }
        }
    }

    private func hideCursorIfStill() {
        // Don't hide while the editor panel is up — the user needs the
        // cursor visible to pick fields, open the color well, etc.
        if editorPanel?.isVisible == true { return }
        if isCursorHidden { return }
        // CGDisplayHideCursor works regardless of whether Mize is the
        // foreground app — NSCursor.setHiddenUntilMouseMoves silently
        // no-ops while a target app (Brave, etc.) holds focus, which is
        // exactly the case we care about during a presentation.
        CGDisplayHideCursor(CGMainDisplayID())
        isCursorHidden = true
    }

    private func showCursorIfHidden() {
        if isCursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            isCursorHidden = false
        }
    }

    // MARK: - Scene-set file management

    /// Load + watch the current scene store (loads from disk, seeding if
    /// missing). Used both at startup and after the user opens a different
    /// scene file.
    private func loadAndWatchCurrentStore(seedScene: () -> [Scene]) {
        do {
            scenes = try sceneStore.load(seedingWith: seedScene())
        } catch {
            NSLog("Mize: failed to load %@: %@ — falling back to demo",
                  sceneStore.url.path, error.localizedDescription)
            scenes = seedScene()
        }
        sceneStore.rememberAsLastUsed()
        sceneStore.startWatching { [weak self] reloaded in
            guard let self else { return }
            self.scenes = reloaded
            if self.currentScene >= reloaded.count {
                self.currentScene = max(0, reloaded.count - 1)
            }
            self.activateScene(at: self.currentScene)
        }
    }

    /// Cmd+O — pick a different scene-set file via NSOpenPanel.
    private func openScenesFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = SceneStore.scenesDirectory
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a Mize scene set"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchToSceneFile(at: url)
    }

    /// Cmd+Shift+S — save the current scenes to a new file via NSSavePanel.
    /// Switches Mize to that new file for subsequent edits.
    private func saveScenesAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = SceneStore.scenesDirectory
        panel.nameFieldStringValue = "MyScenes"
        panel.message = "Save scene set as"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newStore = SceneStore(at: url)
        newStore.save(scenes)
        switchToSceneFile(at: url)
    }

    /// Stop watching the current store, switch to a new file, load + start
    /// watching it, and activate scene 0.
    private func switchToSceneFile(at url: URL) {
        sceneStore.stopWatching()
        sceneStore = SceneStore(at: url)
        currentScene = 0
        loadAndWatchCurrentStore(seedScene: { [scenes] in scenes })
        activateScene(at: currentScene)
    }

    // MARK: - In-app editor

    private func toggleEditor() {
        if editorPanel == nil {
            installEditorPanel()
        }
        guard let panel = editorPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            setEditMode(false)
        } else {
            refreshEditor()
            panel.center()
            // Cmd+E almost always fires while a target app is foreground —
            // it's caught by the GLOBAL key monitor, not the local one.
            // Without activating Mize first, makeKeyAndOrderFront leaves the
            // panel behind the target app and looks like nothing happened.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            setEditMode(true)
        }
    }

    /// In edit mode the main curtain rises ABOVE target windows so the user
    /// can drag text. Stays fully opaque — pane changes are still applied
    /// underneath; user can exit edit mode (Cmd+E) to see the result.
    private func setEditMode(_ editing: Bool) {
        isInEditMode = editing
        if editing {
            mainCurtain?.level = .floating
            mainCurtain?.ignoresMouseEvents = false
            mainCurtainView?.isInteractive = true
        } else {
            mainCurtain?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            mainCurtain?.ignoresMouseEvents = true
            mainCurtainView?.isInteractive = false
            // Close the system color picker if it was left open from the
            // editor's color well — it would otherwise float over the scene.
            NSColorPanel.shared.orderOut(nil)
        }
        mainCurtain?.alphaValue = 1
    }

    private func installEditorPanel() {
        let panel = EditorPanel()
        panel.delegate = self  // for windowWillClose → exit edit mode
        if let screen = NSScreen.main {
            panel.configure(canvas: canvas, screenFrame: screen.frame)
        }
        panel.onSceneEdited = { [weak self] updated, panesChanged in
            guard let self, self.currentScene < self.scenes.count else { return }
            if panesChanged {
                // Editor explicitly changed the pane set — apply as-is.
                self.scenes[self.currentScene] = updated
                self.activateScene(at: self.currentScene)
            } else {
                // Style/text change only — preserve any drag-resize the user
                // did since the last scene transition by capturing current
                // window frames into the scene before applying styling.
                self.captureCurrentSceneFrames()
                let merged = updated.with(panes: self.scenes[self.currentScene].panes)
                self.scenes[self.currentScene] = merged
                self.applyStyling(merged)  // no re-activation — windows stay put
            }
            self.sceneStore.save(self.scenes)
        }
        panel.onAddScene = { [weak self] in
            guard let self else { return }
            let newScene = Scene(
                title: "New scene",
                panes: [],
                backgroundColor: .black,
                texts: []
            )
            self.scenes.insert(newScene, at: self.currentScene + 1)
            self.currentScene += 1
            self.activateScene(at: self.currentScene)
            self.sceneStore.save(self.scenes)
        }
        panel.onDeleteScene = { [weak self] in
            guard let self, self.scenes.count > 1 else { return }
            self.scenes.remove(at: self.currentScene)
            if self.currentScene >= self.scenes.count {
                self.currentScene = self.scenes.count - 1
            }
            self.activateScene(at: self.currentScene)
            self.sceneStore.save(self.scenes)
        }
        panel.onNextScene = { [weak self] in self?.advanceScene() }
        panel.onPreviousScene = { [weak self] in self?.retreatScene() }
        panel.onSceneSetSwitch = { [weak self] url in
            self?.switchToSceneFile(at: url)
        }
        panel.onSceneSetNew = { [weak self] name in
            guard let self else { return }
            let url = SceneStore.scenesDirectory.appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: url.path) {
                self.showAlert(text: "A scene set named \"\(name)\" already exists.")
                return
            }
            let store = SceneStore(at: url)
            store.save([Scene(title: "New scene")])
            self.switchToSceneFile(at: url)
        }
        panel.onSceneSetRename = { [weak self] newName in
            guard let self else { return }
            let oldURL = self.sceneStore.url
            let newURL = SceneStore.scenesDirectory.appendingPathComponent("\(newName).json")
            if FileManager.default.fileExists(atPath: newURL.path) {
                self.showAlert(text: "A scene set named \"\(newName)\" already exists.")
                return
            }
            do {
                self.sceneStore.stopWatching()
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                self.switchToSceneFile(at: newURL)
            } catch {
                self.showAlert(text: "Couldn't rename: \(error.localizedDescription)")
            }
        }
        editorPanel = panel
    }

    private func showAlert(text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func refreshEditor() {
        guard let panel = editorPanel, currentScene < scenes.count else { return }
        let available = (try? FileManager.default
            .contentsOfDirectory(at: SceneStore.scenesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            ?? []
        panel.showScene(
            scenes[currentScene],
            atIndex: currentScene,
            of: scenes.count,
            availableWindows: windowManager.snapshot,
            availableSceneSets: available,
            currentSceneSetURL: sceneStore.url
        )
    }

    // MARK: - Scenes

    private func makeDemoScenes(screen: NSScreen) -> [Scene] {
        // AX-coords canvas — bounded by the same top/bottom gaps the chrome
        // covers use so targets don't render under our chrome.
        let frame = screen.frame
        let canvasY = topGap
        let canvasH = frame.height - topGap - botGap
        let canvasW = frame.width
        let halfW = canvasW / 2

        let leftHalf  = CGRect(x: 0,     y: canvasY, width: halfW, height: canvasH)
        let rightHalf = CGRect(x: halfW, y: canvasY, width: halfW, height: canvasH)
        let full      = CGRect(x: 0,     y: canvasY, width: canvasW, height: canvasH)

        // Demo colors so you can see the per-scene curtain styling immediately
        // when transitioning between scenes (visible in any gaps, plus on the
        // title slide).
        let navy   = NSColor(red: 0.05, green: 0.10, blue: 0.30, alpha: 1)
        let forest = NSColor(red: 0.05, green: 0.20, blue: 0.10, alpha: 1)
        let plum   = NSColor(red: 0.15, green: 0.05, blue: 0.20, alpha: 1)

        return [
            Scene(
                title: "Title slide",
                panes: [],  // no app windows — curtain fully visible
                backgroundColor: navy,
                texts: [CurtainText.title("Mize", screen: screen)]
            ),
            Scene(
                title: "Notes + Discord",
                panes: [
                    Pane(appNameContains: "Notes", titleContains: nil, frame: leftHalf),
                    Pane(appNameContains: "Discord", titleContains: nil, frame: rightHalf),
                ],
                backgroundColor: forest,
                texts: []  // covered by targets anyway
            ),
            Scene(
                title: "Brave full",
                panes: [Pane(appNameContains: "Brave", titleContains: nil, frame: full)],
                backgroundColor: plum,
                texts: []
            ),
            Scene(
                title: "Ghostty + Notion",
                panes: [
                    Pane(appNameContains: "Ghostty", titleContains: "Setup", frame: leftHalf),
                    Pane(appNameContains: "Notion", titleContains: nil, frame: rightHalf),
                ],
                backgroundColor: navy,
                texts: []
            ),
        ]
    }

    private func advanceScene() {
        guard !scenes.isEmpty, !isTransitioning else { return }
        captureCurrentSceneFrames()
        let next = (currentScene + 1) % scenes.count
        if isInEditMode {
            currentScene = next
            activateScene(at: next)
        } else {
            transitionTo(sceneIndex: next)
        }
    }

    private func retreatScene() {
        guard !scenes.isEmpty, !isTransitioning else { return }
        captureCurrentSceneFrames()
        let prev = (currentScene - 1 + scenes.count) % scenes.count
        if isInEditMode {
            currentScene = prev
            activateScene(at: prev)
        } else {
            transitionTo(sceneIndex: prev)
        }
    }

    /// Tint the whole screen to black and back. ALL three curtain windows
    /// (main + top chrome + bot chrome) animate their layer.backgroundColor
    /// in sync, so the screen uniformly darkens without any transparency.
    /// Main curtain stays at alpha=1 throughout; the only animation is color.
    private func transitionTo(sceneIndex: Int) {
        guard let curtain = mainCurtain,
              let mainView = mainCurtainView,
              let topView = topCurtainView,
              let botView = botCurtainView
        else {
            currentScene = sceneIndex
            activateScene(at: sceneIndex)
            return
        }
        isTransitioning = true

        let newScene = scenes[sceneIndex]

        // Raise main curtain above targets so it occludes the old layout once
        // it's black. Chrome bars are already above .floating so they're fine.
        curtain.level = .floating
        curtain.alphaValue = 1

        // Phase 1: animate all three layers from current color → black.
        // Hide text immediately (no fade for that).
        mainView.texts = []
        animateBackgroundColors([mainView, topView, botView], to: .black, duration: 0.25) { [weak self] in
            guard let self else { return }
            // Apply scene under black cover. applyStyling resets curtain
            // colors to the new scene's color, so re-force black afterward.
            self.currentScene = sceneIndex
            self.activateScene(at: sceneIndex)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mainView.backgroundColor = .black
            topView.backgroundColor = .black
            botView.backgroundColor = .black
            mainView.texts = []
            CATransaction.commit()

            // Phase 2: animate from black → new scene color.
            self.animateBackgroundColors([mainView, topView, botView], to: newScene.backgroundColor, duration: 0.25) { [weak self] in
                guard let self else { return }
                mainView.texts = newScene.texts
                if !self.isInEditMode {
                    curtain.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
                }
                curtain.alphaValue = 1
                self.isTransitioning = false
            }
        }
    }

    private func animateBackgroundColors(_ views: [CurtainView], to color: NSColor, duration: CFTimeInterval, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(completion)
        for view in views {
            // Explicit assignment under CATransaction triggers the implicit
            // animation that NSView's layer-backed backgroundColor exposes.
            view.layer?.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    /// Read each target window's current AX frame AND z-order, updating the
    /// scene's pane list so drag/resize AND manual reordering (e.g. clicking
    /// Notes to bring it forward) persist for the rest of the session.
    private func captureCurrentSceneFrames() {
        guard currentScene < scenes.count else { return }
        let scene = scenes[currentScene]

        // Frame capture. Also opportunistically upgrade panes that don't yet
        // have a CGWindowID (loaded from old JSON or first-time match) so
        // future lookups are stable across title changes.
        var updated: [Pane] = []
        for pane in scene.panes {
            guard let match = pane.resolve(in: windowManager.snapshot),
                  let pos = WindowManager.currentPosition(of: match.axElement),
                  let size = WindowManager.currentSize(of: match.axElement)
            else {
                updated.append(pane)
                continue
            }
            let actual = CGRect(origin: pos, size: size)
            let resolvedID = pane.cgWindowID ?? (match.cgWindowID == 0 ? nil : match.cgWindowID)
            let frameChanged = actual != pane.frame
            let idAdded = (pane.cgWindowID == nil && resolvedID != nil)
            if frameChanged || idAdded {
                updated.append(pane.with(frame: actual, cgWindowID: resolvedID))
            } else {
                updated.append(pane)
            }
        }

        // Z-order capture. CGWindowListCopyWindowInfo returns windows
        // front-to-back. We want panes[last] to be most frontmost (since
        // activateScene activates apps in pane order, last = on top).
        let windowList = Self.currentZOrder()
        let reordered = updated.sorted { lhs, rhs in
            lhs.zOrderIndex(in: windowList) > rhs.zOrderIndex(in: windowList)
        }

        let framesChanged = zip(scene.panes, updated).contains { $0.0.frame != $0.1.frame }
        let orderChanged = !Pane.layoutsEqual(scene.panes, reordered)
        if framesChanged || orderChanged {
            scenes[currentScene] = scene.with(panes: reordered)
            sceneStore.save(scenes)
        }
    }

    /// Snapshot the on-screen window list, front-to-back, as plain values
    /// the pure z-order matching can consume.
    private static func currentZOrder() -> [ZOrderEntry] {
        let raw = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return raw.map { win in
            ZOrderEntry(
                windowNumber: (win[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
                ownerName: win[kCGWindowOwnerName as String] as? String,
                title: win[kCGWindowName as String] as? String
            )
        }
    }

    private func activateScene(at index: Int) {
        let scene = scenes[index]
        NSLog("Mize: → scene %d/%d: %@", index + 1, scenes.count, scene.title)

        applyStyling(scene)
        refreshEditor()

        // Resolve panes → snapshot windows. We don't touch the windows yet;
        // the actual minimize/setFrame/raise has to happen AFTER the
        // hide-then-unhide cycle below, otherwise the hide pass can reset
        // minimization state on some apps and a sibling window slips back
        // into view.
        var targetPIDs: Set<pid_t> = []
        var targetMatches: [(WindowManager.WindowState, Pane)] = []
        var targetAXElements: [AXUIElement] = []
        for pane in scene.panes {
            guard let match = pane.resolve(in: windowManager.snapshot) else {
                NSLog("Mize:   pane '%@' — no matching window", pane.appNameContains)
                continue
            }
            targetPIDs.insert(match.pid)
            targetMatches.append((match, pane))
            targetAXElements.append(match.axElement)
            NSLog("Mize:   target: app=%@ title=%@ cgWindowID=%d pane.titleContains=%@",
                  match.appName ?? "?",
                  match.title ?? "?",
                  Int(match.cgWindowID),
                  pane.titleContains ?? "<nil>")
        }

        // Use NSApp's "Hide Others" (Cmd+Opt+H equivalent) instead of per-app
        // NSRunningApplication.hide() — the latter is refused by most apps on
        // macOS 14+, but Hide Others works at the system level.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.hideOtherApplications(self)

        // Unhide each target app so its windows reappear before we manipulate them.
        for (match, _) in targetMatches {
            NSRunningApplication(processIdentifier: match.pid)?.unhide()
        }

        // Hide every NON-target window of each target app so only the
        // pane-targeted window is visible when the app comes forward.
        //
        // Use a LIVE enumeration of the target apps' windows, not the
        // startup snapshot — otherwise windows the user opened after
        // launching Mize (new browser windows, new Ghostty terminals)
        // won't be hidden because they aren't in the snapshot.
        //
        // Match by AXUIElement identity (CFEqual) AND by CGWindowID,
        // since fresh AX queries can hand back new wrappers and we want
        // to recognize the same underlying window either way.
        //
        // Belt + suspenders: AX setMinimized AND move off-screen. Some
        // apps (Ghostty) silently refuse setMinimized via AX, so the move
        // is what actually hides them. -32000 is well outside any plausible
        // display bounds without overflowing signed-int coord ranges some
        // apps clamp to. captureExtraIfNew lets restoreSnapshot put the
        // new (post-snapshot) windows back to where the user had them.
        var targetCGWindowIDs: Set<CGWindowID> = []
        for (state, _) in targetMatches where state.cgWindowID != 0 {
            targetCGWindowIDs.insert(state.cgWindowID)
        }
        let offscreen = CGPoint(x: -32_000, y: -32_000)
        let liveWins = windowManager.liveWindows(for: targetPIDs)
        NSLog("Mize:   liveWindows count=%d for targetPIDs=%@",
              liveWins.count,
              targetPIDs.map(String.init).joined(separator: ","))
        for w in liveWins {
            let isTargetByAX = targetAXElements.contains { CFEqual($0, w.axElement) }
            let isTargetByID = w.cgWindowID != 0 && targetCGWindowIDs.contains(w.cgWindowID)
            if isTargetByAX || isTargetByID {
                NSLog("Mize:     KEEP pid=%d cgWindowID=%d (byAX=%@ byID=%@)",
                      Int(w.pid), Int(w.cgWindowID),
                      isTargetByAX ? "Y" : "N",
                      isTargetByID ? "Y" : "N")
                continue
            }
            windowManager.captureExtraIfNew(w.axElement)
            let minErr = windowManager.setMinimized(w.axElement, true, label: "non-target")
            let mvErr = windowManager.move(w.axElement, to: offscreen, label: "non-target")
            // Read back position to detect silent clamping by the app.
            let actual = WindowManager.currentPosition(of: w.axElement) ?? .zero
            NSLog("Mize:     HIDE pid=%d cgWindowID=%d minErr=%d mvErr=%d actualPos=(%.0f,%.0f)",
                  Int(w.pid), Int(w.cgWindowID),
                  minErr.rawValue, mvErr.rawValue,
                  actual.x, actual.y)
        }

        // Position + raise each target window. setMinimized(false) first in
        // case a previous scene minimized this window as a non-target.
        for (match, pane) in targetMatches {
            windowManager.setMinimized(match.axElement, false, label: pane.appNameContains)
            let frame = CanvasGeometry.clamp(pane.frame, to: canvas)
            windowManager.setFrame(match.axElement, to: frame, label: pane.appNameContains)
            windowManager.raise(match.axElement, label: pane.appNameContains)
        }

        // Activate only the LAST pane's app. Multiple activates in quick
        // succession get partially denied by macOS's focus-stealing
        // protections; one activate reliably wins. Important: NO
        // .activateAllWindows — that unminimizes siblings and undoes the
        // per-window isolation above.
        if let last = targetMatches.last,
           let app = NSRunningApplication(processIdentifier: last.0.pid) {
            if #available(macOS 14.0, *) {
                _ = app.activate(from: NSRunningApplication.current, options: [])
            } else {
                _ = app.activate(options: [])
            }
        }
    }

    /// Apply the scene's backdrop color + text to all three Mize windows.
    /// Setting CurtainView.backgroundColor forces a redraw; setting
    /// NSWindow.backgroundColor alone does not.
    private func applyStyling(_ scene: Scene) {
        mainCurtainView?.backgroundColor = scene.backgroundColor
        mainCurtainView?.texts = scene.texts
        topCurtainView?.backgroundColor = scene.backgroundColor
        botCurtainView?.backgroundColor = scene.backgroundColor
    }

    // MARK: - Shutdown

    private func shutdown() {
        // Restore the cursor first — otherwise an ESC while the cursor is
        // hidden leaves it invisible until something else touches CGDisplay.
        showCursorIfHidden()

        let appsToUnhide = originalVisibleApps
        originalVisibleApps.removeAll()
        for pid in appsToUnhide {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }

        // Wait for unhide to take effect before AX-restoring positions.
        // Without this delay, AX setFrame on a still-hidden window silently
        // no-ops, leaving apps at their scene positions on exit.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.windowManager.restoreSnapshot()
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitorLocal { NSEvent.removeMonitor(m); keyMonitorLocal = nil }
        if let m = keyMonitorGlobal { NSEvent.removeMonitor(m); keyMonitorGlobal = nil }
        if let m = mouseMoveMonitorLocal { NSEvent.removeMonitor(m); mouseMoveMonitorLocal = nil }
        if let m = mouseMoveMonitorGlobal { NSEvent.removeMonitor(m); mouseMoveMonitorGlobal = nil }
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
        // Belt-and-suspenders in case shutdown() wasn't the exit path.
        showCursorIfHidden()
        sceneStore.stopWatching()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // If user clicks the editor panel's close button, exit edit mode so
        // the curtain returns to its normal level and target windows reappear.
        if (notification.object as AnyObject) === editorPanel {
            setEditMode(false)
        }
    }
}
