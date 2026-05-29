import AppKit

/// Floating panel for in-app scene authoring.
@MainActor
final class EditorPanel: NSPanel {

    // Callbacks
    /// Called when the user changes color/title/text/size. The bool indicates
    /// whether the change includes pane edits (false = preserve current panes,
    /// useful because the user may have dragged windows since last save).
    var onSceneEdited: ((Scene, _ panesChanged: Bool) -> Void)?
    var onAddScene: (() -> Void)?
    var onDeleteScene: (() -> Void)?
    var onNextScene: (() -> Void)?
    var onPreviousScene: (() -> Void)?
    /// Scene-set (named file) management callbacks.
    var onSceneSetSwitch: ((URL) -> Void)?
    var onSceneSetNew: ((String) -> Void)?
    var onSceneSetRename: ((String) -> Void)?

    // Controls
    private let sceneSetPopup = NSPopUpButton()
    private let indexLabel = NSTextField(labelWithString: "Scene 1 / 1")
    private let titleField = NSTextField()
    private let colorWell = NSColorWell()
    private let textView: NSTextView = {
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12)
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        return tv
    }()
    private let textScrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.borderType = .bezelBorder
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private let textAnchorPopup = NSPopUpButton()
    private let textSizeSlider: NSSlider = {
        let s = NSSlider()
        s.minValue = 20
        s.maxValue = 200
        s.doubleValue = 72
        return s
    }()
    private let textSizeLabel = NSTextField(labelWithString: "72pt")
    private let windowsStack = NSStackView()
    private let windowsScroll = NSScrollView()

    private var textSize: CGFloat { CGFloat(textSizeSlider.doubleValue) }
    private var textContent: String { textView.string }

    // State
    private var currentScene: Scene?
    private var availableWindows: [WindowManager.WindowState] = []
    private var screenFrame: CGRect = .zero
    private var canvas: CGRect = .zero  // AX-coords canvas (where target windows go)
    private var isRefreshing = false
    private var availableSceneSets: [URL] = []
    private var currentSceneSetURL: URL?

    // Per-row controls keyed by the window's app+title fingerprint so we
    // can re-find them on refresh.
    private var rowControls: [(checkbox: NSButton, popup: NSPopUpButton, fingerprint: String)] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            // Removed .nonactivatingPanel so NSColorWell can get focus
            // to open the system color picker.
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Mize Editor"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        minSize = NSSize(width: 340, height: 400)

        setupUI()
        wireUp()
    }

    // MARK: - Public

    func configure(canvas: CGRect, screenFrame: CGRect) {
        self.canvas = canvas
        self.screenFrame = screenFrame
    }

    func showScene(
        _ scene: Scene,
        atIndex index: Int,
        of total: Int,
        availableWindows: [WindowManager.WindowState],
        availableSceneSets: [URL],
        currentSceneSetURL: URL?
    ) {
        currentScene = scene
        self.availableWindows = availableWindows
        self.availableSceneSets = availableSceneSets
        self.currentSceneSetURL = currentSceneSetURL
        isRefreshing = true
        defer { isRefreshing = false }
        indexLabel.stringValue = "Scene \(index + 1) / \(total)"
        titleField.stringValue = scene.title
        colorWell.color = scene.backgroundColor
        textView.string = scene.texts.first?.content ?? ""
        let size = scene.texts.first?.font.pointSize ?? 72
        textSizeSlider.doubleValue = Double(size)
        textSizeLabel.stringValue = "\(Int(size))pt"
        rebuildSceneSetPopup()
        rebuildWindowList()
    }

    private func rebuildSceneSetPopup() {
        sceneSetPopup.removeAllItems()
        for url in availableSceneSets {
            let name = url.deletingPathExtension().lastPathComponent
            sceneSetPopup.addItem(withTitle: name)
            sceneSetPopup.lastItem?.representedObject = url
        }
        if let current = currentSceneSetURL,
           let idx = availableSceneSets.firstIndex(of: current) {
            sceneSetPopup.selectItem(at: idx)
        }
    }

    // MARK: - UI

    private func setupUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false

        // Scene-set picker row: dropdown of named sets + new + rename
        sceneSetPopup.target = self
        sceneSetPopup.action = #selector(sceneSetPopupChanged)
        let newSetBtn = button("+", #selector(newSceneSetClicked))
        newSetBtn.toolTip = "New scene set"
        let renameSetBtn = button("Rename", #selector(renameSceneSetClicked))
        renameSetBtn.toolTip = "Rename the current scene set"
        let setRow = NSStackView(views: [sceneSetPopup, newSetBtn, renameSetBtn])
        setRow.orientation = .horizontal
        setRow.spacing = 6
        sceneSetPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newSetBtn.setContentHuggingPriority(.required, for: .horizontal)
        renameSetBtn.setContentHuggingPriority(.required, for: .horizontal)
        root.addArrangedSubview(field("Scene set", setRow))

        // Separator
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(divider)

        indexLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        indexLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(indexLabel)

        root.addArrangedSubview(field("Title", titleField))
        root.addArrangedSubview(field("Background", colorWell, fillWidth: false))

        // Multi-line text input. NSTextView inside NSScrollView so it scrolls
        // if the user enters more lines than fit.
        textScrollView.documentView = textView
        textScrollView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        root.addArrangedSubview(field("Text", textScrollView))

        // Anchor dropdown
        for anchor in TextAnchor.allCases {
            textAnchorPopup.addItem(withTitle: anchor.label)
            textAnchorPopup.lastItem?.representedObject = anchor.rawValue
        }
        textAnchorPopup.selectItem(at: 4)  // center default
        root.addArrangedSubview(field("Text position", textAnchorPopup, fillWidth: false))

        // Text size slider
        textSizeLabel.font = .systemFont(ofSize: 11)
        textSizeLabel.textColor = .secondaryLabelColor
        textSizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let sizeRow = NSStackView(views: [textSizeSlider, textSizeLabel])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8
        sizeRow.alignment = .centerY
        root.addArrangedSubview(field("Text size", sizeRow))

        // Windows section
        let windowsHeader = NSTextField(labelWithString: "Windows in scene")
        windowsHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        windowsHeader.textColor = .secondaryLabelColor
        root.addArrangedSubview(windowsHeader)

        windowsStack.orientation = .vertical
        windowsStack.spacing = 4
        windowsStack.alignment = .leading
        windowsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSClipView()
        clip.documentView = windowsStack
        windowsScroll.contentView = clip
        windowsScroll.hasVerticalScroller = true
        windowsScroll.borderType = .lineBorder
        windowsScroll.translatesAutoresizingMaskIntoConstraints = false
        windowsScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        root.addArrangedSubview(windowsScroll)

        // Nav + CRUD
        let nav = NSStackView(views: [
            button("← Prev", #selector(prevClicked)),
            button("Next →", #selector(nextClicked)),
        ])
        nav.orientation = .horizontal
        nav.spacing = 8
        nav.distribution = .fillEqually
        root.addArrangedSubview(nav)

        let del = button("Delete", #selector(deleteClicked))
        del.bezelColor = .systemRed
        let crud = NSStackView(views: [
            button("+ Add Scene", #selector(addClicked)),
            del,
        ])
        crud.orientation = .horizontal
        crud.spacing = 8
        crud.distribution = .fillEqually
        root.addArrangedSubview(crud)

        let savedFooter = NSTextField(labelWithString: "Auto-saves to ~/Library/Application Support/Mize/Scenes/")
        savedFooter.font = .systemFont(ofSize: 10)
        savedFooter.textColor = .tertiaryLabelColor
        savedFooter.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(savedFooter)

        // Width constraints for stack items
        let panelInner: CGFloat = 332
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: panelInner).isActive = true
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    private func field(_ label: String, _ control: NSView, fillWidth: Bool = true) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 96).isActive = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = fillWidth ? .fill : .fillProportionally
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func wireUp() {
        titleField.target = self
        titleField.action = #selector(titleChanged)
        titleField.delegate = self
        textView.delegate = self
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        textAnchorPopup.target = self
        textAnchorPopup.action = #selector(anchorChanged)
        textSizeSlider.target = self
        textSizeSlider.action = #selector(textSizeChanged)
    }

    // MARK: - Window list

    private static let layoutOptions: [(label: String, frame: (CGRect) -> CGRect)] = [
        ("Full",        { $0 }),
        ("Left Half",   { CGRect(x: $0.minX, y: $0.minY, width: $0.width / 2, height: $0.height) }),
        ("Right Half",  { CGRect(x: $0.midX, y: $0.minY, width: $0.width / 2, height: $0.height) }),
        ("Top Half",    { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height / 2) }),
        ("Bottom Half", { CGRect(x: $0.minX, y: $0.midY, width: $0.width, height: $0.height / 2) }),
    ]

    private func rebuildWindowList() {
        for v in windowsStack.arrangedSubviews { v.removeFromSuperview() }
        rowControls.removeAll()

        // Same filter as the rest of the app's candidate picking
        let skipPrefixes = [
            "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
            "com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.finder",
            "com.apple.wallpaper", "com.apple.screencaptureui",
            Bundle.main.bundleIdentifier ?? "",
        ]
        let candidates = availableWindows.filter { w in
            guard let bid = w.bundleID, !skipPrefixes.contains(where: { bid.lowercased().hasPrefix($0.lowercased()) }) else { return false }
            guard !w.wasMinimized else { return false }
            guard let t = w.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
            return w.originalSize.width >= 200 && w.originalSize.height >= 200
        }

        guard !candidates.isEmpty else {
            let empty = NSTextField(labelWithString: "(no windows available)")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            windowsStack.addArrangedSubview(empty)
            return
        }

        for w in candidates {
            let fingerprint = "\(w.appName ?? "?")|\(w.title ?? "")"

            // Prefer CGWindowID match; fall back to app-only loose match for
            // panes whose stored title may not match the current window title
            // (e.g., Slack channel switches, browser tab changes).
            let currentPane = currentScene?.panes.first { pane in
                if let id = pane.cgWindowID, id == w.cgWindowID { return true }
                guard let app = w.appName?.lowercased() else { return false }
                guard app.contains(pane.appNameContains.lowercased()) else { return false }
                if let tc = pane.titleContains, !tc.isEmpty {
                    return (w.title?.lowercased().contains(tc.lowercased())) ?? false
                }
                return true
            }

            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(windowToggled(_:)))
            cb.state = currentPane != nil ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(fingerprint)

            // Show the pane's stored ("last seen") title if this window is
            // already in the scene, so the user can recognize windows by the
            // title they had when added — not whatever the window happens to
            // show right now.
            let displayedTitle = currentPane?.titleContains ?? w.title ?? ""
            let label = NSTextField(labelWithString: "\(w.appName ?? "?") — \(displayedTitle)")
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 11)

            let popup = NSPopUpButton()
            for option in Self.layoutOptions { popup.addItem(withTitle: option.label) }
            popup.action = #selector(windowLayoutChanged(_:))
            popup.target = self
            popup.identifier = NSUserInterfaceItemIdentifier(fingerprint)
            popup.isEnabled = (cb.state == .on)
            // Try to match current pane's frame to a preset
            if let pane = currentPane {
                popup.selectItem(at: Self.matchLayoutIndex(pane.frame, canvas: canvas))
            }

            let row = NSStackView(views: [cb, label, popup])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.distribution = .fill
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.required, for: .horizontal)

            windowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 310).isActive = true

            rowControls.append((checkbox: cb, popup: popup, fingerprint: fingerprint))
        }
    }

    private static func matchLayoutIndex(_ frame: CGRect, canvas: CGRect) -> Int {
        let tolerance: CGFloat = 8
        for (i, option) in layoutOptions.enumerated() {
            let expected = option.frame(canvas)
            if abs(expected.minX - frame.minX) < tolerance
                && abs(expected.minY - frame.minY) < tolerance
                && abs(expected.width - frame.width) < tolerance
                && abs(expected.height - frame.height) < tolerance
            {
                return i
            }
        }
        return 0  // default to Full
    }

    @objc private func windowToggled(_ sender: NSButton) {
        // Enable/disable matching popup
        for row in rowControls where row.checkbox === sender {
            row.popup.isEnabled = (sender.state == .on)
        }
        emitPanes()
    }

    @objc private func windowLayoutChanged(_ sender: NSPopUpButton) {
        emitPanes()
    }

    private func emitPanes() {
        guard !isRefreshing, let scene = currentScene else { return }

        // Start from the EXISTING panes — only apply changes for rows that
        // are visible in the editor (i.e., apps currently running). Panes
        // for apps that aren't currently visible stay untouched.
        var panes = scene.panes

        for row in rowControls {
            guard let w = availableWindows.first(where: {
                "\($0.appName ?? "?")|\($0.title ?? "")" == row.fingerprint
            }) else { continue }

            // Does this window correspond to an existing pane?
            let existingIdx = panes.firstIndex { pane in
                if let id = pane.cgWindowID, id == w.cgWindowID { return true }
                guard let app = w.appName?.lowercased() else { return false }
                guard app.contains(pane.appNameContains.lowercased()) else { return false }
                if let tc = pane.titleContains, !tc.isEmpty {
                    return (w.title?.lowercased().contains(tc.lowercased())) ?? false
                }
                return true
            }

            if row.checkbox.state == .on {
                let layoutIdx = row.popup.indexOfSelectedItem
                let frame = Self.layoutOptions[layoutIdx].frame(canvas)
                let newPane = Pane(
                    appNameContains: w.appName ?? "",
                    titleContains: w.title,
                    frame: frame,
                    cgWindowID: w.cgWindowID == 0 ? nil : w.cgWindowID
                )
                if let idx = existingIdx {
                    panes[idx] = newPane
                } else {
                    panes.append(newPane)
                }
            } else if let idx = existingIdx {
                panes.remove(at: idx)
            }
        }

        let updated = Scene(
            title: scene.title,
            panes: panes,
            backgroundColor: scene.backgroundColor,
            texts: scene.texts
        )
        currentScene = updated
        onSceneEdited?(updated, true)
    }

    // MARK: - Actions

    @objc private func titleChanged() { emitPreservingText() }
    @objc private func textChanged() { emitPreservingText() }
    @objc private func colorChanged() { emitPreservingText() }
    @objc private func textSizeChanged() {
        textSizeLabel.stringValue = "\(Int(textSizeSlider.doubleValue))pt"
        emitPreservingText()
    }
    @objc private func anchorChanged() { emitResettingPosition() }
    @objc private func prevClicked() { onPreviousScene?() }
    @objc private func nextClicked() { onNextScene?() }
    @objc private func addClicked() { onAddScene?() }
    @objc private func deleteClicked() { onDeleteScene?() }

    @objc private func sceneSetPopupChanged() {
        guard !isRefreshing,
              let url = sceneSetPopup.selectedItem?.representedObject as? URL,
              url != currentSceneSetURL
        else { return }
        onSceneSetSwitch?(url)
    }

    @objc private func newSceneSetClicked() {
        guard let name = promptForName(title: "New scene set",
                                       message: "Name for the new scene set:",
                                       default: "Untitled") else { return }
        onSceneSetNew?(name)
    }

    @objc private func renameSceneSetClicked() {
        let current = currentSceneSetURL?.deletingPathExtension().lastPathComponent ?? ""
        guard let name = promptForName(title: "Rename scene set",
                                       message: "New name for \"\(current)\":",
                                       default: current),
              name != current
        else { return }
        onSceneSetRename?(name)
    }

    /// Modal NSAlert with a text field. Returns the trimmed, sanitized name
    /// or nil if the user cancelled or entered an empty/illegal name.
    private func promptForName(title: String, message: String, default defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        input.stringValue = defaultValue
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        // Strip path separators and trim whitespace.
        let cleaned = input.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Re-emit the scene preserving the existing text's position (e.g. from a
    /// prior drag). Used when changing color, title, content, or size.
    private func emitPreservingText() {
        guard !isRefreshing, let scene = currentScene else { return }
        let content = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let texts: [CurtainText]
        if content.isEmpty {
            texts = []
        } else if let existing = scene.texts.first {
            // Preserve position + alignment; update content, font size, color.
            texts = [CurtainText(
                content: content,
                position: existing.position,
                font: .systemFont(ofSize: textSize, weight: .bold),
                color: existing.color,
                alignment: existing.alignment
            )]
        } else if let screen = NSScreen.main {
            // No existing text — initialize from current anchor selection.
            let anchorRaw = textAnchorPopup.selectedItem?.representedObject as? String ?? "center"
            let anchor = TextAnchor(rawValue: anchorRaw) ?? .center
            texts = [CurtainText.at(content, screen: screen, anchor: anchor, fontSize: textSize)]
        } else {
            texts = []
        }
        let updated = Scene(
            title: titleField.stringValue.isEmpty ? scene.title : titleField.stringValue,
            panes: scene.panes,
            backgroundColor: colorWell.color,
            texts: texts
        )
        currentScene = updated
        onSceneEdited?(updated, false)  // panes unchanged — preserve drag state
    }

    /// Re-emit with the text snapped back to the chosen anchor position.
    /// Used only when the user explicitly changes the anchor dropdown.
    private func emitResettingPosition() {
        guard !isRefreshing, let scene = currentScene, let screen = NSScreen.main else { return }
        let content = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let texts: [CurtainText]
        if content.isEmpty {
            texts = []
        } else {
            let anchorRaw = textAnchorPopup.selectedItem?.representedObject as? String ?? "center"
            let anchor = TextAnchor(rawValue: anchorRaw) ?? .center
            texts = [CurtainText.at(content, screen: screen, anchor: anchor, fontSize: textSize)]
        }
        let updated = Scene(
            title: titleField.stringValue.isEmpty ? scene.title : titleField.stringValue,
            panes: scene.panes,
            backgroundColor: colorWell.color,
            texts: texts
        )
        currentScene = updated
        onSceneEdited?(updated, false)  // panes unchanged
    }
}

extension EditorPanel: NSTextFieldDelegate, NSTextViewDelegate {
    // Continuous title field edits
    func controlTextDidChange(_ obj: Notification) {
        emitPreservingText()
    }
    // Continuous multi-line text view edits
    func textDidChange(_ notification: Notification) {
        emitPreservingText()
    }
}
