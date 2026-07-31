import AppKit

final class AppCoordinator: FinderWindowTrackerDelegate {
    private let tracker = FinderWindowTracker()
    private let resolver = PathResolver()
    private let preferences: Preferences
    private var panes: [CGWindowID: PaneController] = [:]
    private var detachedPanes: [PaneController] = []
    private var cdDebouncers: [CGWindowID: Debouncer] = [:]
    /// isBrowser判定の確定結果キャッシュ(false=情報ウィンドウ等、再試行しない)
    private var browserKnown: [CGWindowID: Bool] = [:]
    private var browserRetryCounts: [CGWindowID: Int] = [:]
    /// ⌥⌘Tでユーザーが個別に隠したペイン(タブ単位トグル)
    private var userHidden: Set<CGWindowID> = []
    /// 直近のオンスクリーンウィンドウ順(前面→背面)。最前面Finderウィンドウの特定に使う
    private var lastOrderedIDs: [CGWindowID] = []
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

    /// ⌥⌘T: 最前面のFinderウィンドウ(タブ)のペインだけをトグルする
    func toggleFrontmostPane() {
        guard let id = lastOrderedIDs.first(where: { panes[$0] != nil }) else { return }
        if userHidden.contains(id) {
            userHidden.remove(id)
        } else {
            userHidden.insert(id)
        }
        DebugLog.log("toggle frontmost pane id=\(id) hidden=\(userHidden.contains(id))")
        reevaluateAllVisibility()
    }

    // MARK: - セッション一覧(メニューバー)

    struct SessionMenuEntry {
        let title: String
        let activate: () -> Void
        /// アンカー中のセッションのみ非nil: 追従を再開する
        let releaseAnchor: (() -> Void)?
    }

    func sessionMenuEntries() -> [SessionMenuEntry] {
        var entries: [SessionMenuEntry] = []
        for (id, pane) in panes.sorted(by: { $0.key < $1.key }) {
            // アンカー中はシェルの実cwd(作業フォルダ)を表示する方が実態に合う
            let displayPath = pane.session.isAnchored
                ? (pane.session.debugShellCwd() ?? pane.currentPath)
                : pane.currentPath
            let path = (displayPath as NSString?)?.abbreviatingWithTildeInPath ?? "?"
            let cmd = pane.session.foregroundCommandName.map { " — \($0) 実行中" } ?? ""
            let anchor = pane.session.isAnchored ? " ⚓" : ""
            let hidden = userHidden.contains(id) ? "(非表示)" : ""
            let release: (() -> Void)? = pane.session.isAnchored ? { [weak pane] in
                guard let pane else { return }
                pane.session.releaseAnchor()
                // 解除したら現在のFinderフォルダへ即追従
                if let current = pane.currentPath {
                    pane.session.syncDirectoryIfIdle(to: current)
                }
            } : nil
            entries.append(SessionMenuEntry(title: "\(path)\(cmd)\(anchor)\(hidden)",
                                            activate: { [weak self] in
                guard let self else { return }
                // 隠していたら再表示し、そのウィンドウ/タブを前面へ
                self.userHidden.remove(id)
                self.reevaluateAllVisibility()
                self.resolver.raiseFinderWindow(windowID: id)
            }, releaseAnchor: release))
        }
        for pane in detachedPanes {
            let path = (pane.currentPath as NSString?)?.abbreviatingWithTildeInPath ?? "?"
            let cmd = pane.session.foregroundCommandName.map { " — \($0) 実行中" } ?? ""
            entries.append(SessionMenuEntry(title: "\(path)\(cmd)(独立ウィンドウ)",
                                            activate: { [weak pane] in
                pane?.orderFrontDetached()
            }, releaseAnchor: nil))
        }
        return entries
    }

    @objc private func reevaluateAllVisibility() {
        let onScreenIDs = Self.onScreenWindowIDs()
        for (id, pane) in panes {
            let visible = preferences.panesVisible
                && axTrusted
                && !userHidden.contains(id)
                && !miniaturized.contains(id)
                && !fullscreen.contains(id)
                && onScreenIDs.contains(id)
            DebugLog.log("visibility id=\(id) visible=\(visible) prefs=\(preferences.panesVisible) ax=\(axTrusted) mini=\(miniaturized.contains(id)) fs=\(fullscreen.contains(id)) onScreen=\(onScreenIDs.contains(id))")
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
        DebugLog.log("appeared id=\(id)")
        lastFrames[id] = frameAX
        attemptPaneCreation(id: id)
    }

    /// isBrowser判定がタイムアウト(nil)のときは1秒後に再試行する(最大5回)。
    /// 起動直後のAppleEventsはコールドスタートで2秒を超えることがある(実測)ため、
    /// タイムアウトを「ブラウザウィンドウではない」と誤判定しない。
    private func attemptPaneCreation(id: CGWindowID) {
        guard panes[id] == nil, lastFrames[id] != nil,
              browserKnown[id] != false else { return }
        resolver.isBrowserWindow(windowID: id) { [weak self] isBrowser in
            guard let self, self.panes[id] == nil, self.lastFrames[id] != nil else { return }
            DebugLog.log("isBrowser id=\(id) → \(isBrowser.map { "\($0)" } ?? "unknown")")
            switch isBrowser {
            case .some(true):
                self.browserKnown[id] = true
                self.browserRetryCounts[id] = nil
                self.createPane(id: id)
            case .some(false):
                self.browserKnown[id] = false
            case .none:
                let attempts = (self.browserRetryCounts[id] ?? 0) + 1
                self.browserRetryCounts[id] = attempts
                guard attempts <= 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.attemptPaneCreation(id: id)
                }
            }
        }
    }

    private func createPane(id: CGWindowID) {
        resolver.resolveFolderPath(windowID: id) { [weak self] path in
            guard let self, self.panes[id] == nil else { return }
            DebugLog.log("path id=\(id) → \(path ?? "(nil)")")
                let initialPath = path ?? FileManager.default
                    .homeDirectoryForCurrentUser.path
                guard let frame = self.lastFrames[id],
                      let pane = PaneController(windowID: id,
                                                finderFrameAX: frame,
                                                initialPath: initialPath,
                                                ratio: self.preferences.paneHeightRatio,
                                                opacity: self.preferences.paneOpacity)
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
                // 注: かつてはbusy→idle遷移でFinderの現在フォルダへ再同期していたが、
                // claude --resume がcwd単位でセッションを探すため廃止した(終了後もその場に留まる)
                pane.session.onExit = { [weak self, weak pane] in
                    // 仕様5.2: シェル終了 → ペインを畳む(再起動UIはv1では省略し、ペインを破棄)
                    guard let self, let pane else { return }
                    self.removePane(id: pane.windowID)
                }
                self.panes[id] = pane
                self.reevaluateAllVisibility()
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
        DebugLog.log("focused id=\(id) hasPane=\(panes[id] != nil)")
        panes[id]?.orderAboveFinder()
    }

    func trackerWindowDestroyed(id: CGWindowID) {
        DebugLog.log("destroyed id=\(id) hasPane=\(panes[id] != nil)")
        guard let pane = panes[id] else {
            // ペイン生成前に閉じられた: 進行中の非同期生成を無効化する(仕様R3の孤児ペイン防止)
            lastFrames[id] = nil
            cdDebouncers[id] = nil
            browserKnown[id] = nil
            browserRetryCounts[id] = nil
            miniaturized.remove(id)
            fullscreen.remove(id)
            userHidden.remove(id)
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

    func trackerOnScreenWindowsChanged() {
        // タブ切替(AX通知なし)で表裏が入れ替わったペインの表示/非表示を追従させる
        reevaluateAllVisibility()
    }

    func trackerWindowOrderTick(orderedIDs: [CGWindowID]) {
        lastOrderedIDs = orderedIDs
        // アンカー状態の更新(仕様4.6: 長時間コマンド終了でそのフォルダに固定)
        for (_, pane) in panes {
            pane.session.tickAnchorState()
        }
        // Finderウィンドウのクリック前面化はAXイベントを発火しないため、
        // ペインより前に出てしまったFinderウィンドウを検知してz順序を回復する
        for (id, pane) in panes {
            guard let finderIdx = orderedIDs.firstIndex(of: id),
                  let paneIdx = orderedIDs.firstIndex(of: pane.panelWindowNumber),
                  finderIdx < paneIdx else { continue }
            DebugLog.log("zorder fix id=\(id)")
            pane.orderAboveFinder()
        }
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
        browserKnown[id] = nil
        browserRetryCounts[id] = nil
        miniaturized.remove(id)
        fullscreen.remove(id)
        userHidden.remove(id)
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
