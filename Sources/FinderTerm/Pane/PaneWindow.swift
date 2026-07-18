import AppKit

/// 枠なし・非アクティブ化パネル。クリックでキーになるがアプリをアクティブ化しない
/// (Finderのタイトルバーがアクティブ表示のまま入力できる)
final class PaneWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // 背景はTerminalViewが描く(paneOpacity対応のため、ウィンドウ自体は透明)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
