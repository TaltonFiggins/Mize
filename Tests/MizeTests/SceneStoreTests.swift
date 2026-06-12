import AppKit
@testable import MizeCore

@MainActor
func runSceneStoreTests() {
    TestHarness.suite("SceneStore")

    func makeTempStore() -> SceneStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MizeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SceneStore(at: dir.appendingPathComponent("scenes.json"))
    }

    test("load() creates the file with seed scenes when it doesn't exist") {
        let store = makeTempStore()
        let seed = [Scene(title: "Seeded", backgroundColor: .red)]
        let loaded = try store.load(seedingWith: seed)
        assertEqual(loaded.count, 1)
        assertEqual(loaded[0].title, "Seeded")
        assertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    test("load() reads existing file instead of re-seeding") {
        let store = makeTempStore()
        _ = try store.load(seedingWith: [Scene(title: "Original")])
        let loaded = try store.load(seedingWith: [Scene(title: "Replacement")])
        assertEqual(loaded[0].title, "Original")
    }

    test("save → load preserves Scene, Pane, and CurtainText fields") {
        let store = makeTempStore()
        let scene = Scene(
            title: "Demo",
            panes: [
                Pane(
                    appNameContains: "Notes",
                    titleContains: "My notes",
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                    cgWindowID: 12345
                ),
            ],
            backgroundColor: NSColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1),
            texts: [
                CurtainText(
                    content: "Hello",
                    position: CGPoint(x: 100, y: 200),
                    font: .systemFont(ofSize: 48, weight: .bold),
                    color: .white,
                    alignment: .center
                )
            ]
        )
        store.save([scene])
        let loaded = try store.load(seedingWith: [])
        assertEqual(loaded.count, 1)
        let r = loaded[0]
        assertEqual(r.title, "Demo")
        assertEqual(r.panes.count, 1)
        assertEqual(r.panes[0].appNameContains, "Notes")
        assertEqual(r.panes[0].titleContains, "My notes")
        assertEqual(r.panes[0].frame, CGRect(x: 10, y: 20, width: 800, height: 600))
        assertNil(r.panes[0].cgWindowID,
                  "cgWindowID is session-scoped and must not persist across save+load")
        assertEqual(r.texts.count, 1)
        assertEqual(r.texts[0].content, "Hello")
        assertEqual(r.texts[0].position, CGPoint(x: 100, y: 200))
        assertEqual(r.texts[0].alignment, .center)
        assertEqual(r.texts[0].font.pointSize, 48)
    }

    test("Color hex roundtrip preserves RGB within 1/255") {
        let colors: [NSColor] = [
            NSColor(red: 0, green: 0, blue: 0, alpha: 1),
            NSColor(red: 1, green: 1, blue: 1, alpha: 1),
            NSColor(red: 0.05, green: 0.10, blue: 0.30, alpha: 1),
            NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        ]
        for original in colors {
            let hex = original.hexString
            guard let parsed = NSColor.fromHex(hex) else {
                assertTrue(false, "fromHex returned nil for \(hex)"); continue
            }
            let o = original.usingColorSpace(.sRGB)!
            let p = parsed.usingColorSpace(.sRGB)!
            assertTrue(abs(o.redComponent - p.redComponent) < 0.01, "red mismatch for \(hex)")
            assertTrue(abs(o.greenComponent - p.greenComponent) < 0.01, "green mismatch for \(hex)")
            assertTrue(abs(o.blueComponent - p.blueComponent) < 0.01, "blue mismatch for \(hex)")
        }
    }

    test("fromHex accepts both #ff0000 and ff0000") {
        assertNotNil(NSColor.fromHex("#ff0000"))
        assertNotNil(NSColor.fromHex("ff0000"))
    }

    test("fromHex rejects invalid formats") {
        assertNil(NSColor.fromHex(""))
        assertNil(NSColor.fromHex("xyz"))
        assertNil(NSColor.fromHex("#ff00"))
        assertNil(NSColor.fromHex("#ff00000"))
    }

    test("load() handles minimal JSON with only required fields") {
        let store = makeTempStore()
        let minimal = """
        {
          "scenes": [ { "title": "Minimal" } ]
        }
        """
        try minimal.write(to: store.url, atomically: true, encoding: .utf8)
        let loaded = try store.load(seedingWith: [])
        assertEqual(loaded.count, 1)
        assertEqual(loaded[0].title, "Minimal")
        assertEqual(loaded[0].panes.count, 0)
        assertEqual(loaded[0].texts.count, 0)
    }

    test("load() handles empty scenes array") {
        let store = makeTempStore()
        try #"{"scenes":[]}"#.write(to: store.url, atomically: true, encoding: .utf8)
        let loaded = try store.load(seedingWith: [])
        assertEqual(loaded.count, 0)
    }

    test("load() throws on malformed JSON rather than wiping the file") {
        let store = makeTempStore()
        try "not json {".write(to: store.url, atomically: true, encoding: .utf8)
        do {
            _ = try store.load(seedingWith: [Scene(title: "Seed")])
            assertTrue(false, "expected load() to throw")
        } catch {
            // Expected. The malformed file must survive for the user to fix.
            let raw = try String(contentsOf: store.url, encoding: .utf8)
            assertEqual(raw, "not json {")
        }
    }

    test("Saved JSON is pretty-printed") {
        let store = makeTempStore()
        store.save([Scene(title: "Test")])
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        assertTrue(raw.contains("\n"), "saved JSON should be pretty-printed")
    }

    test("rememberAsLastUsed writes the current URL to UserDefaults") {
        let store = makeTempStore()
        store.rememberAsLastUsed()
        assertEqual(UserDefaults.standard.string(forKey: "MizeLastScenesPath"), store.url.path)
    }
}
