import CoreGraphics
import Foundation

/// The named window layouts offered in the editor's per-window popup.
/// Order matters: it's the popup's item order, and `matching` prefers
/// earlier cases on (theoretical) ties.
enum LayoutPreset: CaseIterable {
    case full
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf

    var label: String {
        switch self {
        case .full:       return "Full"
        case .leftHalf:   return "Left Half"
        case .rightHalf:  return "Right Half"
        case .topHalf:    return "Top Half"
        case .bottomHalf: return "Bottom Half"
        }
    }

    /// The preset's frame within the given canvas (AX coords, top-left origin
    /// — so "Top Half" keeps the canvas's minY).
    func frame(in canvas: CGRect) -> CGRect {
        switch self {
        case .full:
            return canvas
        case .leftHalf:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        case .rightHalf:
            return CGRect(x: canvas.midX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        case .topHalf:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
        case .bottomHalf:
            return CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
        }
    }

    /// The preset whose frame matches `frame` within `tolerance` points on
    /// every edge, or nil if the frame is custom. Tolerance absorbs apps that
    /// clamp AX resizes by a few points (terminal cell rounding, min sizes).
    static func matching(_ frame: CGRect, in canvas: CGRect, tolerance: CGFloat = 8) -> LayoutPreset? {
        allCases.first { preset in
            let expected = preset.frame(in: canvas)
            return abs(expected.minX - frame.minX) < tolerance
                && abs(expected.minY - frame.minY) < tolerance
                && abs(expected.width - frame.width) < tolerance
                && abs(expected.height - frame.height) < tolerance
        }
    }
}

/// Conversions between absolute pane frames (AX coords) and the
/// canvas-relative percentages shown in the editor's X/Y/W/H fields.
enum CanvasGeometry {

    struct Pct: Equatable {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var h: CGFloat
    }

    /// Pane frame (AX coords, screen-absolute) → percentages of the canvas.
    /// A degenerate canvas yields the full-canvas identity (0, 0, 100, 100).
    static func pct(of frame: CGRect, in canvas: CGRect) -> Pct {
        guard canvas.width > 0, canvas.height > 0 else { return Pct(x: 0, y: 0, w: 100, h: 100) }
        return Pct(
            x: (frame.minX - canvas.minX) / canvas.width * 100,
            y: (frame.minY - canvas.minY) / canvas.height * 100,
            w: frame.width / canvas.width * 100,
            h: frame.height / canvas.height * 100
        )
    }

    /// Inverse of `pct(of:in:)`. Negative/over-100 values are permitted so
    /// users can intentionally push windows past the canvas if needed.
    static func frame(from pct: Pct, in canvas: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX + pct.x / 100 * canvas.width,
            y: canvas.minY + pct.y / 100 * canvas.height,
            width: pct.w / 100 * canvas.width,
            height: pct.h / 100 * canvas.height
        )
    }

    /// Intersect a pane frame with the canvas. Out-of-canvas frames (e.g.,
    /// custom % values pushed past 100, or old JSON saved before the chrome
    /// covers existed) collapse to the canvas itself rather than vanishing.
    static func clamp(_ frame: CGRect, to canvas: CGRect) -> CGRect {
        let i = frame.intersection(canvas)
        return (i.isNull || i.width < 1 || i.height < 1) ? canvas : i
    }

    /// One decimal place is enough granularity for window sizing — keeps the
    /// field compact and avoids floating-point noise from round-trips.
    static func formatPct(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
