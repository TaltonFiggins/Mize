import Foundation
@testable import MizeCore

@MainActor
func runGeometryTests() {
    TestHarness.suite("CanvasGeometry + LayoutPreset")

    // A realistic canvas: notched-MBP screen with a 63pt top chrome cover.
    let canvas = CGRect(x: 0, y: 63, width: 1512, height: 919)

    test("LayoutPreset frames tile the canvas as labeled") {
        assertEqual(LayoutPreset.full.frame(in: canvas), canvas)
        assertEqual(LayoutPreset.leftHalf.frame(in: canvas),
                    CGRect(x: 0, y: 63, width: 756, height: 919))
        assertEqual(LayoutPreset.rightHalf.frame(in: canvas),
                    CGRect(x: 756, y: 63, width: 756, height: 919))
        assertEqual(LayoutPreset.topHalf.frame(in: canvas),
                    CGRect(x: 0, y: 63, width: 1512, height: 459.5))
        assertEqual(LayoutPreset.bottomHalf.frame(in: canvas),
                    CGRect(x: 0, y: 522.5, width: 1512, height: 459.5))
    }

    test("left + right halves cover the canvas exactly") {
        let union = LayoutPreset.leftHalf.frame(in: canvas)
            .union(LayoutPreset.rightHalf.frame(in: canvas))
        assertEqual(union, canvas)
    }

    test("matching recognizes each preset's exact frame") {
        for preset in LayoutPreset.allCases {
            assertEqual(LayoutPreset.matching(preset.frame(in: canvas), in: canvas), preset,
                        "preset \(preset.label)")
        }
    }

    test("matching tolerates app-clamped frames within 8pt") {
        let nearLeft = CGRect(x: 3, y: 65, width: 750, height: 914)
        assertEqual(LayoutPreset.matching(nearLeft, in: canvas), .leftHalf)
    }

    test("matching returns nil for a custom frame") {
        let custom = CGRect(x: 100, y: 100, width: 600, height: 500)
        assertNil(LayoutPreset.matching(custom, in: canvas))
        // 8pt off on one edge only — just past tolerance.
        let justPast = CGRect(x: 8, y: 63, width: 756, height: 919)
        assertNil(LayoutPreset.matching(justPast, in: canvas))
    }

    test("pct of the canvas itself is (0, 0, 100, 100)") {
        assertEqual(CanvasGeometry.pct(of: canvas, in: canvas),
                    CanvasGeometry.Pct(x: 0, y: 0, w: 100, h: 100))
    }

    test("pct ↔ frame roundtrip is lossless") {
        let frames = [
            CGRect(x: 100, y: 200, width: 600, height: 400),
            CGRect(x: -50, y: 63, width: 2000, height: 919),  // past canvas edges
            LayoutPreset.rightHalf.frame(in: canvas),
        ]
        for frame in frames {
            let back = CanvasGeometry.frame(from: CanvasGeometry.pct(of: frame, in: canvas), in: canvas)
            assertApprox(back, frame, "roundtrip of \(frame)")
        }
    }

    test("pct accounts for the canvas origin offset") {
        // A frame starting at the canvas's top-left is 0%, not 6.8%.
        let atOrigin = CGRect(x: 0, y: 63, width: 756, height: 459.5)
        let pct = CanvasGeometry.pct(of: atOrigin, in: canvas)
        assertApprox(pct.x, 0)
        assertApprox(pct.y, 0)
        assertApprox(pct.w, 50)
        assertApprox(pct.h, 50)
    }

    test("degenerate canvas yields the full-canvas identity") {
        let pct = CanvasGeometry.pct(of: CGRect(x: 1, y: 2, width: 3, height: 4), in: .zero)
        assertEqual(pct, CanvasGeometry.Pct(x: 0, y: 0, w: 100, h: 100))
    }

    test("frame(from:) permits negative and over-100 percentages") {
        let frame = CanvasGeometry.frame(
            from: CanvasGeometry.Pct(x: -10, y: 0, w: 120, h: 100), in: canvas)
        assertApprox(frame.minX, -151.2)
        assertApprox(frame.width, 1814.4)
    }

    test("clamp leaves in-canvas frames untouched") {
        let inside = CGRect(x: 100, y: 100, width: 500, height: 500)
        assertEqual(CanvasGeometry.clamp(inside, to: canvas), inside)
    }

    test("clamp trims frames that overflow the canvas") {
        let overflowing = CGRect(x: -100, y: 0, width: 2000, height: 2000)
        assertEqual(CanvasGeometry.clamp(overflowing, to: canvas), canvas)
        let pokingOut = CGRect(x: 1400, y: 500, width: 400, height: 300)
        assertEqual(CanvasGeometry.clamp(pokingOut, to: canvas),
                    CGRect(x: 1400, y: 500, width: 112, height: 300))
    }

    test("clamp collapses fully-outside and sliver frames to the canvas") {
        assertEqual(CanvasGeometry.clamp(CGRect(x: -32_000, y: -32_000, width: 100, height: 100), to: canvas),
                    canvas, "fully outside")
        // Intersection thinner than 1pt counts as vanished.
        assertEqual(CanvasGeometry.clamp(CGRect(x: 1511.5, y: 100, width: 400, height: 300), to: canvas),
                    canvas, "sub-1pt sliver")
    }

    test("formatPct renders one decimal place") {
        assertEqual(CanvasGeometry.formatPct(50), "50.0")
        assertEqual(CanvasGeometry.formatPct(33.3333), "33.3")
        assertEqual(CanvasGeometry.formatPct(0), "0.0")
    }
}
