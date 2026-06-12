import AppKit
import Foundation

/// One window within a scene's layout. Identified primarily by a
/// session-scoped CGWindowID; falls back to (app name, title) substring
/// matching when the ID isn't known (e.g., panes loaded from JSON before
/// this field existed, or across launches since IDs aren't stable).
struct Pane {
    let appNameContains: String
    let titleContains: String?
    let frame: CGRect  // AX upper-left coords
    let cgWindowID: CGWindowID?  // session-scoped; nil = use name/title fallback

    init(appNameContains: String, titleContains: String?, frame: CGRect, cgWindowID: CGWindowID? = nil) {
        self.appNameContains = appNameContains
        self.titleContains = titleContains
        self.frame = frame
        self.cgWindowID = cgWindowID
    }

    /// Copy with an updated frame and (possibly upgraded) window ID.
    func with(frame: CGRect, cgWindowID: CGWindowID?) -> Pane {
        Pane(
            appNameContains: appNameContains,
            titleContains: titleContains,
            frame: frame,
            cgWindowID: cgWindowID
        )
    }
}

/// A piece of text rendered on the curtain.
struct CurtainText {
    let content: String
    /// Position in the curtain's view coords (AppKit, lower-left origin).
    let position: CGPoint
    let font: NSFont
    let color: NSColor
    /// Optional alignment to interpret `position` as the alignment anchor.
    /// `.center` means `position` is the center of the rendered text.
    let alignment: Alignment

    enum Alignment { case topLeft, center }

    /// Copy at a new position (everything else preserved). Used by text drag.
    func moved(to position: CGPoint) -> CurtainText {
        CurtainText(
            content: content,
            position: position,
            font: font,
            color: color,
            alignment: alignment
        )
    }

    static func title(_ content: String, screen: NSScreen, color: NSColor = .white) -> CurtainText {
        CurtainText(
            content: content,
            position: CGPoint(x: screen.frame.midX, y: screen.frame.midY),
            font: .systemFont(ofSize: 72, weight: .bold),
            color: color,
            alignment: .center
        )
    }

    static func at(_ content: String, screen: NSScreen, anchor: TextAnchor, color: NSColor = .white, fontSize: CGFloat = 72) -> CurtainText {
        let f = screen.frame
        let m: CGFloat = 80  // margin from edges
        let p: CGPoint
        switch anchor {
        case .topLeft:      p = CGPoint(x: m,        y: f.maxY - m)
        case .topCenter:    p = CGPoint(x: f.midX,   y: f.maxY - m)
        case .topRight:     p = CGPoint(x: f.maxX - m, y: f.maxY - m)
        case .middleLeft:   p = CGPoint(x: m,        y: f.midY)
        case .center:       p = CGPoint(x: f.midX,   y: f.midY)
        case .middleRight:  p = CGPoint(x: f.maxX - m, y: f.midY)
        case .bottomLeft:   p = CGPoint(x: m,        y: f.minY + m)
        case .bottomCenter: p = CGPoint(x: f.midX,   y: f.minY + m)
        case .bottomRight:  p = CGPoint(x: f.maxX - m, y: f.minY + m)
        }
        return CurtainText(
            content: content,
            position: p,
            font: .systemFont(ofSize: fontSize, weight: .bold),
            color: color,
            alignment: .center
        )
    }
}

enum TextAnchor: String, CaseIterable {
    case topLeft, topCenter, topRight
    case middleLeft, center, middleRight
    case bottomLeft, bottomCenter, bottomRight

    var label: String {
        switch self {
        case .topLeft:      return "Top Left"
        case .topCenter:    return "Top Center"
        case .topRight:     return "Top Right"
        case .middleLeft:   return "Middle Left"
        case .center:       return "Center"
        case .middleRight:  return "Middle Right"
        case .bottomLeft:   return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight:  return "Bottom Right"
        }
    }
}

/// A named arrangement of panes + curtain styling. Mize cycles via arrow keys.
struct Scene {
    let title: String
    let panes: [Pane]
    let backgroundColor: NSColor
    let texts: [CurtainText]

    init(
        title: String,
        panes: [Pane] = [],
        backgroundColor: NSColor = .black,
        texts: [CurtainText] = []
    ) {
        self.title = title
        self.panes = panes
        self.backgroundColor = backgroundColor
        self.texts = texts
    }

    /// Copy with selected fields replaced; nil keeps the current value.
    func with(
        title: String? = nil,
        panes: [Pane]? = nil,
        backgroundColor: NSColor? = nil,
        texts: [CurtainText]? = nil
    ) -> Scene {
        Scene(
            title: title ?? self.title,
            panes: panes ?? self.panes,
            backgroundColor: backgroundColor ?? self.backgroundColor,
            texts: texts ?? self.texts
        )
    }
}
