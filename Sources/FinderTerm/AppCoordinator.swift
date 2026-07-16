import AppKit

final class AppCoordinator: FinderWindowTrackerDelegate {
    private let tracker = FinderWindowTracker()
    private let resolver = PathResolver()
    private let preferences: Preferences
    private var panes: [CGWindowID: PaneController] = [:]
    private var detachedPanes: [PaneController] = []
    private var cdDebouncers: [CGWindowID: Debouncer] = [:]
    private var lastFrames: [CGWindowID: CGRect] = [:]
    private var miniaturized: Set<CGWindowID> = []
    private var fullscreen: Set<CGWindowID> = []
    private var permissionTimer: Timer?
    private var axTrusted = false
    var onPermissionStateChanged: ((Bool) -> Void)?

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    // MARK: - 起動と権限(仕様5.2)

    func start() {
        tracker.delegate = self
        axTrusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if axTrusted {
            tracker.start()
        }
        onPermissionStateChanged?(axTrusted)
        // 30秒間隔で権限を再チェック(初回未許可→許可、実行中の剥奪の両方を拾う)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.recheckPermission()
        }
        // Space切替・画面構成変更・スリープ復帰で再同期(仕様4.2/5.1)
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(reevaluateAllVisibility),
                         name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(reevaluateAllVisibility),
                         name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reevaluateAllVisibility),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Finderがアクティブになったらz順序を回復
        wsnc.addObserver(self, selector: #selector(workspaceAppActivated(_:)),
                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func recheckPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != axTrusted else { return }
        axTrusted = trusted
        onPermissionStateChanged?(trusted)
        if trusted {
            tracker.start()
            reevaluateAllVisibility()
        } else {
            // 剥奪: ペインを隠す(セッションは維持)
            panes.values.forEach { $0.setVisible(false) }
        }
    }

    @objc private func workspaceAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.finder" else { return }
        panes.values.forEach { $0.orderAboveFinder() }
    }

    // MARK: - 表示状態

    func togglePanesVisible() {
        preferences.panesVisible.toggle()
        reevaluateAllVisibility()
    }

    @objc private func reevaluateAllVisibility() {
        let onScreenIDs = Self.onScreenWindowIDs()
        for (id, pane) in panes {
            let visible = preferences.panesVisible
                && axTrusted
                && !miniaturized.contains(id)
                && !fullscreen.contains(id)
                && onScreenIDs.contains(id)
            pane.setVisible(visible)
            if visible, let frame = lastFrames[id] {
                pane.syncFrame(finderFrameAX: frame, ratio: preferences.paneHeightRatio)
            }
        }
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    // MARK: - FinderWindowTrackerDelegate

    func trackerWindowAppeared(id: CGWindowID, frameAX: CGRect) {
        lastFrames[id] = frameAX
        resolver.isBrowserWindow(windowID: id) { [weak self] isBrowser in
            guard let self, isBrowser, self.panes[id] == nil else { return }
            self.resolver.resolveFolderPath(windowID: id) { path in
                let initialPath = path ?? FileManager.default
                    .homeDirectoryForCurrentUser.path
                guard let frame = self.lastFrames[id],
                      let pane = PaneController(windowID: id,
                                                finderFrameAX: frame,
                                                initialPath: initialPath,
                                                ratio: self.preferences.paneHeightRatio)
                else { return }
                pane.onRatioChanged = { [weak self] newRatio in
                    guard let self else { return }
                    self.preferences.paneHeightRatio = newRatio  // Preferencesがクランプする
                    for (pid, p) in self.panes {
                        if let f = self.lastFrames[pid] {
                            p.syncFrame(finderFrameAX: f, ratio: self.preferences.paneHeightRatio)
                        }
                    }
                }
                pane.session.onBecameIdle = { [weak pane] in
                    // 仕様4.4: claude等の終了後、Finderの現在フォルダへ一度だけ再同期
                    guard let pane, let path = pane.currentPath else { return }
                    pane.session.syncDirectoryIfIdle(to: path)
                }
                pane.session.onExit = { [weak self, weak pane] in
                    // 仕様5.2: シェル終了 → ペインを畳む(再起動UIはv1では省略し、ペインを破棄)
                    guard let self, let pane else { return }
                    self.removePane(id: pane.windowID)
                }
                self.panes[id] = pane
                self.reevaluateAllVisibility()
            }
        }
    }

    func trackerWindowFrameChanged(id: CGWindowID, frameAX: CGRect) {
        lastFrames[id] = frameAX
        panes[id]?.syncFrame(finderFrameAX: frameAX, ratio: preferences.paneHeightRatio)
    }

    func trackerWindowTitleChanged(id: CGWindowID) {
        guard let pane = panes[id] else { return }
        let debouncer = cdDebouncers[id] ?? Debouncer(delay: 0.3)
        cdDebouncers[id] = debouncer
        debouncer.call { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.resolver.resolveFolderPath(windowID: id) { path in
                guard let path else { return }  // パスなし画面: 最後の有効パス保持(仕様4.3)
                pane.currentPath = path
                pane.session.syncDirectoryIfIdle(to: path)
            }
        }
    }

    func trackerWindowMiniaturizedChanged(id: CGWindowID, miniaturized isMini: Bool) {
        if isMini { miniaturized.insert(id) } else { miniaturized.remove(id) }
        reevaluateAllVisibility()
    }

    func trackerWindowFullscreenChanged(id: CGWindowID, isFullscreen: Bool) {
        guard fullscreen.contains(id) != isFullscreen else { return }
        if isFullscreen { fullscreen.insert(id) } else { fullscreen.remove(id) }
        reevaluateAllVisibility()
    }

    func trackerWindowFocused(id: CGWindowID) {
        panes[id]?.orderAboveFinder()
    }

    func trackerWindowDestroyed(id: CGWindowID) {
        guard let pane = panes[id] else {
            // ペイン生成前に閉じられた: 進行中の非同期生成を無効化する(仕様R3の孤児ペイン防止)
            lastFrames[id] = nil
            cdDebouncers[id] = nil
            miniaturized.remove(id)
            fullscreen.remove(id)
            return
        }
        if pane.session.isIdle || pane.session.isTerminated {
            removePane(id: id)
        } else {
            // 仕様5.1: 実行中プロセスあり → 確認
            confirmClose(pane: pane)
        }
    }

    func trackerFinderTerminated() {
        // trackerが全ウィンドウにtrackerWindowDestroyedを発行済み(仕様5.1: 閉扱い)
    }

    // MARK: - ライフサイクル(仕様5.1)

    private func confirmClose(pane: PaneController) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "実行中のプロセスがあります。終了しますか?"
        alert.informativeText = "「セッションを残す」を選ぶと、独立したウィンドウとして残ります。"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "セッションを残す")
        if alert.runModal() == .alertFirstButtonReturn {
            removePane(id: pane.windowID)
        } else {
            detach(pane: pane)
        }
    }

    private func detach(pane: PaneController) {
        panes[pane.windowID] = nil
        cdDebouncers[pane.windowID] = nil
        lastFrames[pane.windowID] = nil
        detachedPanes.append(pane)
        pane.detachToFloating()
        // 仕様5.1: 独立ウィンドウは普通のターミナルとして使う(凍結されたcurrentPathへの自動cdはもう不要)
        pane.session.onBecameIdle = nil
        pane.session.onExit = { [weak self, weak pane] in
            // detach後にシェルが自然終了した場合もフローティングウィンドウを片付ける
            guard let self, let pane else { return }
            pane.closeAndTerminate()
            self.detachedPanes.removeAll { $0 === pane }
        }
        pane.onDetachedWindowClosed = { [weak self, weak pane] in
            guard let self, let pane else { return }
            if pane.session.isIdle || pane.session.isTerminated {
                pane.closeAndTerminate()
                self.detachedPanes.removeAll { $0 === pane }
            } else {
                self.confirmDetachedClose(pane: pane)
            }
        }
    }

    private func confirmDetachedClose(pane: PaneController) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "実行中のプロセスがあります。終了しますか?"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            pane.closeAndTerminate()
            detachedPanes.removeAll { $0 === pane }
        }
    }

    private func removePane(id: CGWindowID) {
        panes[id]?.closeAndTerminate()
        panes[id] = nil
        cdDebouncers[id] = nil
        lastFrames[id] = nil
        miniaturized.remove(id)
        fullscreen.remove(id)
    }

    /// 仕様5.1: アプリ終了時の一括確認。trueなら終了してよい
    func confirmQuitTerminatingSessions() -> Bool {
        let busyCount = (panes.values + detachedPanes)
            .filter { !$0.session.isIdle && !$0.session.isTerminated }
            .count
        guard busyCount > 0 else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "実行中のセッションが\(busyCount)件あります。すべて終了しますか?"
        alert.addButton(withTitle: "すべて終了")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    deinit {
        permissionTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}
