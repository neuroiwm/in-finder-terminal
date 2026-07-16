import AppKit

/// ペイン上端の境界バー。上下ドラッグで高さ比率を変える(仕様4.5)
final class DividerView: NSView {
    static let height: CGFloat = 6
    var onDragBegan: (() -> Void)?
    /// 画面座標での累積Y移動量(上が正)
    var onDrag: ((CGFloat) -> Void)?
    private var dragStartY: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    /// 非キー状態のペインへの初回クリックを吸わせない
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation.y - dragStartY)
    }
}
