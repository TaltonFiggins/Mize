import AppKit
@testable import MizeCore

@MainActor
func runSceneTests() {
    TestHarness.suite("Scene / Pane / CurtainText copy helpers")

    let pane = Pane(appNameContains: "Notes", titleContains: "My notes",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600), cgWindowID: 42)
    let text = CurtainText(content: "Hello", position: CGPoint(x: 10, y: 20),
                           font: .systemFont(ofSize: 48, weight: .bold),
                           color: .white, alignment: .center)
    let scene = Scene(title: "Demo", panes: [pane], backgroundColor: .red, texts: [text])

    test("Scene.with() with no arguments is an identity copy") {
        let copy = scene.with()
        assertEqual(copy.title, scene.title)
        assertEqual(copy.panes.count, 1)
        assertTrue(copy.panes[0].layoutEquals(pane))
        assertEqual(copy.backgroundColor, scene.backgroundColor)
        assertEqual(copy.texts.count, 1)
    }

    test("Scene.with replaces only the given fields") {
        let retitled = scene.with(title: "Renamed")
        assertEqual(retitled.title, "Renamed")
        assertEqual(retitled.panes.count, 1, "panes preserved")
        assertEqual(retitled.backgroundColor, NSColor.red, "color preserved")

        let recolored = scene.with(backgroundColor: .blue)
        assertEqual(recolored.title, "Demo")
        assertEqual(recolored.backgroundColor, NSColor.blue)
    }

    test("Scene.with(texts: []) clears texts — empty is not 'keep'") {
        let cleared = scene.with(texts: [])
        assertEqual(cleared.texts.count, 0)
        let noPanes = scene.with(panes: [])
        assertEqual(noPanes.panes.count, 0)
    }

    test("Pane.with(frame:cgWindowID:) keeps identity fields") {
        let moved = pane.with(frame: CGRect(x: 5, y: 5, width: 100, height: 100), cgWindowID: 99)
        assertEqual(moved.appNameContains, "Notes")
        assertEqual(moved.titleContains, "My notes")
        assertEqual(moved.frame, CGRect(x: 5, y: 5, width: 100, height: 100))
        assertEqual(moved.cgWindowID, 99)
        let cleared = pane.with(frame: pane.frame, cgWindowID: nil)
        assertNil(cleared.cgWindowID, "explicit nil clears the session ID")
    }

    test("CurtainText.moved(to:) changes only the position") {
        let moved = text.moved(to: CGPoint(x: 300, y: 400))
        assertEqual(moved.position, CGPoint(x: 300, y: 400))
        assertEqual(moved.content, "Hello")
        assertEqual(moved.font.pointSize, 48)
        assertEqual(moved.color, NSColor.white)
        assertEqual(moved.alignment, .center)
    }
}
