import AppKit

final class PaneController: NSObject, NSWindowDelegate {
    let windowID: CGWindowID
    let session: TerminalSession
    var currentPath: String?
    private(set) var isDetached = false
    /// z順序監視用: ペインパネルのウィンドウ番号
    var panelWindowNumber: CGWindowID { CGWindowID(panel.windowNumber) }
    var onRatioChanged: ((CGFloat) -> Void)?
    var onDetachedWindowClosed: (() -> Void)?

    private let panel: PaneWindow
    private let divider = DividerView()
    private var lastFinderFrameAX: CGRect
    private var dragBaseHeight: CGFloat = 0

    init?(windowID: CGWindowID, finderFrameAX: CGRect, initialPath: String, ratio: CGFloat,
          opacity: CGFloat = 1.0) {
        guard let session = TerminalSession(
            initialDirectory: initialPath,
            frame: CGRect(x: 0, y: 0, width: finderFrameAX.width,
                          height: finderFrameAX.height * ratio)) else { return nil }
        self.windowID = windowID
        self.session = session
        self.currentPath = initialPath
        self.lastFinderFrameAX = finderFrameAX

        let paneAX = FrameMath.paneFrameAX(finderFrame: finderFrameAX, ratio: ratio)
        let cocoa = FrameMath.axToCocoa(paneAX, primaryScreenHeight: Self.primaryScreenHeight())
        self.panel = PaneWindow(contentRect: cocoa)
        super.init()

        // 背景を半透明にしてFinderの中身を透かす(1.0で従来どおり不透明)
        session.terminalView.nativeBackgroundColor =
            NSColor.textBackgroundColor.withAlphaComponent(opacity)

        panel.delegate = self
        layoutContent()
        divider.onDragBegan = { [weak self] in
            guard let self, !self.isDetached else { return }
            self.dragBaseHeight = self.panel.frame.height
        }
        divider.onDrag = { [weak self] deltaY in
            guard let self, !self.isDetached, self.lastFinderFrameAX.height > 0 else { return }
            let newRatio = (self.dragBaseHeight + deltaY) / self.lastFinderFrameAX.height
            self.onRatioChanged?(newRatio)
        }
    }

    private func layoutContent() {
        let content = NSView()
        content.addSubview(divider)
        content.addSubview(session.terminalView)
        divider.translatesAutoresizingMaskIntoConstraints = false
        session.terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: DividerView.height),
            session.terminalView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            session.terminalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            session.terminalView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            session.terminalView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    // MARK: - 吸着(仕様4.2)

    func syncFrame(finderFrameAX: CGRect, ratio: CGFloat) {
        guard !isDetached else { return }
        lastFinderFrameAX = finderFrameAX
        let paneAX = FrameMath.paneFrameAX(finderFrame: finderFrameAX, ratio: ratio)
        let cocoa = FrameMath.axToCocoa(paneAX, primaryScreenHeight: Self.primaryScreenHeight())
        panel.setFrame(cocoa, display: true)
        orderAboveFinder()
    }

    func setVisible(_ visible: Bool) {
        guard !isDetached else { return }
        if visible {
            panel.orderFront(nil)
            orderAboveFinder()
        } else {
            panel.orderOut(nil)
        }
    }

    func orderAboveFinder() {
        guard !isDetached, panel.isVisible else { return }
        panel.order(.above, relativeTo: Int(windowID))
    }

    // MARK: - ライフサイクル(仕様5.1)

    /// 「セッションを残す」: 吸着を解除して通常のタイトルバー付きウィンドウにする
    func detachToFloating() {
        isDetached = true
        divider.isHidden = true
        let contentRect = panel.contentRect(forFrameRect: panel.frame)
        panel.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        panel.setFrame(panel.frameRect(forContentRect: contentRect), display: true)
        panel.title = "FinderTerm — \(currentPath ?? "session")"
        panel.hasShadow = true
        panel.level = .normal
        panel.orderFront(nil)
    }

    func closeAndTerminate() {
        session.terminate()
        panel.delegate = nil
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 独立ウィンドウ化後の⌘W/closeボタン。busy確認はAppCoordinator側で行う
        onDetachedWindowClosed?()
        return false
    }

    private static func primaryScreenHeight() -> CGFloat {
        // AX座標の原点は「主画面(スクリーン配列の(0,0)を含む画面)」の左上
        NSScreen.screens.first?.frame.height ?? 0
    }
}
