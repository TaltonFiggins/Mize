import AppKit

/// The content view of Mize's main curtain. Paints the scene's background
/// color and renders any text elements. Re-rendered via setNeedsDisplay
/// whenever the active scene changes.
final class CurtainView: NSView {
    /// Backed by the view's layer so it's GPU-composited and can be animated
    /// via CATransaction (without going through alpha/transparency).
    var backgroundColor: NSColor = .black {
        didSet { applyBackgroundColor() }
    }
    var texts: [CurtainText] = [] {
        didSet { needsDisplay = true }
    }

    /// When true, the view accepts mouse events for dragging text. The owning
    /// AppDelegate enables this only while the editor panel is open.
    var isInteractive: Bool = false

    /// Called when the user releases a drag — passes the text index and its
    /// new position. AppDelegate persists this back into the scene.
    var onTextMoved: ((Int, CGPoint) -> Void)?

    private var draggingIndex: Int?
    private var dragOffset: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isOpaque: Bool { true }
    override var wantsDefaultClipping: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }

    private func applyBackgroundColor() {
        // Default: instant color change, no implicit animation. The transition
        // code wraps explicit changes in a CATransaction for the animated case.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = backgroundColor.cgColor
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Layer fills the background. We only draw text on top.
        for text in texts {
            let origin = drawOrigin(for: text)
            attributedString(for: text).draw(at: origin)
        }
    }

    // MARK: - Mouse handling (text drag)

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let local = convert(event.locationInWindow, from: nil)
        for (i, text) in texts.enumerated().reversed() {  // top-most first
            if boundingRect(for: text).contains(local) {
                draggingIndex = i
                dragOffset = CGPoint(
                    x: local.x - text.position.x,
                    y: local.y - text.position.y
                )
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive, let idx = draggingIndex, idx < texts.count else { return }
        let local = convert(event.locationInWindow, from: nil)
        let newPos = CGPoint(x: local.x - dragOffset.x, y: local.y - dragOffset.y)
        let old = texts[idx]
        texts[idx] = CurtainText(
            content: old.content,
            position: newPos,
            font: old.font,
            color: old.color,
            alignment: old.alignment
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive, let idx = draggingIndex, idx < texts.count else {
            draggingIndex = nil
            return
        }
        onTextMoved?(idx, texts[idx].position)
        draggingIndex = nil
    }

    // MARK: - Layout helpers

    private func attributedString(for text: CurtainText) -> NSAttributedString {
        // For centered text, also center per-line within the block (otherwise
        // multi-line text is left-aligned inside a centered bounding box).
        let para = NSMutableParagraphStyle()
        para.alignment = text.alignment == .center ? .center : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: text.font,
            .foregroundColor: text.color,
            .paragraphStyle: para,
        ]
        return NSAttributedString(string: text.content, attributes: attrs)
    }

    private func drawOrigin(for text: CurtainText) -> CGPoint {
        let size = attributedString(for: text).size()
        switch text.alignment {
        case .topLeft:
            return text.position
        case .center:
            return CGPoint(
                x: text.position.x - size.width / 2,
                y: text.position.y - size.height / 2
            )
        }
    }

    private func boundingRect(for text: CurtainText) -> CGRect {
        let size = attributedString(for: text).size()
        let origin = drawOrigin(for: text)
        return CGRect(origin: origin, size: size)
    }
}
