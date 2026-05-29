import AppKit
import Foundation

/// Persists the user's scenes to a JSON file at
/// `~/Library/Application Support/Mize/scenes.json`. Watches the file with a
/// DispatchSource so external edits (in the user's text editor) hot-reload
/// the running app. Drag-resize captures inside Mize write back here so the
/// JSON is always the source of truth.
@MainActor
final class SceneStore {
    let url: URL
    private(set) var scenes: [Scene] = []

    private var watcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onReload: (([Scene]) -> Void)?
    private var ignoreNextWriteUntil: Date = .distantPast

    init(at url: URL) {
        self.url = url
    }

    /// Loads scenes from disk. Seeds the file with the provided demo scenes
    /// if it doesn't exist yet.
    func load(seedingWith demoScenes: @autoclosure () -> [Scene]) throws -> [Scene] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let seed = demoScenes()
            try writeToDisk(seed)
            scenes = seed
            return seed
        }
        let data = try Data(contentsOf: url)
        let json = try JSONDecoder().decode(JSONSceneFile.self, from: data)
        scenes = json.scenes.map { Scene(from: $0) }
        return scenes
    }

    /// Writes the given scenes to disk. Suppresses the watcher's next reload
    /// for ~1s so we don't bounce on our own writes.
    func save(_ newScenes: [Scene]) {
        scenes = newScenes
        ignoreNextWriteUntil = Date().addingTimeInterval(1.0)
        do {
            try writeToDisk(newScenes)
        } catch {
            NSLog("Mize: SceneStore save failed: %@", error.localizedDescription)
        }
    }

    func startWatching(_ onReload: @escaping ([Scene]) -> Void) {
        self.onReload = onReload
        installWatcher()
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Internals

    private func writeToDisk(_ scenes: [Scene]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = JSONSceneFile(scenes: scenes.map { JSONScene(from: $0) })
        let data = try encoder.encode(json)
        try data.write(to: url, options: .atomic)
    }

    private func installWatcher() {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            NSLog("Mize: SceneStore failed to open %@ for watching", url.path)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Atomic writes (rename + delete) invalidate our fd; re-establish.
            let needsReopen = source.data.contains(.delete) || source.data.contains(.rename)
            self.handleFileChange()
            if needsReopen {
                self.stopWatching()
                // Brief delay — the file may not be replaced yet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.installWatcher()
                }
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 { close(fileDescriptor) }
        }
        source.resume()
        watcher = source
    }

    private func handleFileChange() {
        if Date() < ignoreNextWriteUntil { return }
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONDecoder().decode(JSONSceneFile.self, from: data)
            scenes = json.scenes.map { Scene(from: $0) }
            NSLog("Mize: SceneStore reloaded %d scenes from disk", scenes.count)
            onReload?(scenes)
        } catch {
            NSLog("Mize: SceneStore reload failed: %@", error.localizedDescription)
        }
    }

    /// Directory that holds all named scene-set files.
    static var scenesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Mize/Scenes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The scene-set file to open by default. Looks up the last-used path
    /// from UserDefaults; falls back to a "Default.json" file. One-time
    /// migration: if an old single-file scenes.json exists, move it into
    /// the Scenes/ directory.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        // Migrate legacy single-file location → Scenes/Default.json
        let legacy = base.appendingPathComponent("Mize/scenes.json")
        let scenesDir = scenesDirectory
        let defaultFile = scenesDir.appendingPathComponent("Default.json")
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: defaultFile.path)
        {
            try? FileManager.default.moveItem(at: legacy, to: defaultFile)
        }

        // Last-used path takes precedence if the file still exists.
        if let lastPath = UserDefaults.standard.string(forKey: "MizeLastScenesPath"),
           FileManager.default.fileExists(atPath: lastPath)
        {
            return URL(fileURLWithPath: lastPath)
        }
        return defaultFile
    }

    /// Remember this URL as the last-used for next launch.
    func rememberAsLastUsed() {
        UserDefaults.standard.set(url.path, forKey: "MizeLastScenesPath")
    }
}

// MARK: - JSON transport types

private struct JSONSceneFile: Codable {
    let scenes: [JSONScene]
}

private struct JSONScene: Codable {
    let title: String
    let backgroundColor: String?
    let texts: [JSONText]?
    let panes: [JSONPane]?

    init(from scene: Scene) {
        title = scene.title
        backgroundColor = scene.backgroundColor.hexString
        texts = scene.texts.map { JSONText(from: $0) }
        panes = scene.panes.map { JSONPane(from: $0) }
    }
}

private struct JSONText: Codable {
    let content: String
    let x: Double
    let y: Double
    let fontSize: Double
    let color: String?
    let alignment: String?  // "topLeft" or "center"

    init(from text: CurtainText) {
        content = text.content
        x = text.position.x
        y = text.position.y
        fontSize = text.font.pointSize
        color = text.color.hexString
        alignment = text.alignment == .center ? "center" : "topLeft"
    }
}

private struct JSONPane: Codable {
    let appNameContains: String
    let titleContains: String?
    let frame: JSONRect

    init(from pane: Pane) {
        appNameContains = pane.appNameContains
        titleContains = pane.titleContains
        frame = JSONRect(from: pane.frame)
    }
}

private struct JSONRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(from rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: - Inflate runtime types from JSON

extension Scene {
    fileprivate init(from json: JSONScene) {
        let bg = json.backgroundColor.flatMap(NSColor.fromHex(_:)) ?? .black
        let texts = (json.texts ?? []).map { CurtainText(from: $0) }
        let panes = (json.panes ?? []).map { Pane(from: $0) }
        self.init(title: json.title, panes: panes, backgroundColor: bg, texts: texts)
    }
}

extension Pane {
    fileprivate init(from json: JSONPane) {
        self.init(
            appNameContains: json.appNameContains,
            titleContains: json.titleContains,
            frame: json.frame.cgRect
        )
    }
}

extension CurtainText {
    fileprivate init(from json: JSONText) {
        let color = json.color.flatMap(NSColor.fromHex(_:)) ?? .white
        let alignment: CurtainText.Alignment = (json.alignment == "center") ? .center : .topLeft
        self.init(
            content: json.content,
            position: CGPoint(x: json.x, y: json.y),
            font: .systemFont(ofSize: json.fontSize, weight: .bold),
            color: color,
            alignment: alignment
        )
    }
}

// MARK: - NSColor ↔ hex string

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
