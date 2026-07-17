import AppKit
import ApplicationServices

// 私用API(仕様4.1で承認済み): AXウィンドウ→CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

protocol FinderWindowTrackerDelegate: AnyObject {
    func trackerWindowAppeared(id: CGWindowID, frameAX: CGRect)
    func trackerWindowFrameChanged(id: CGWindowID, frameAX: CGRect)
    func trackerWindowTitleChanged(id: CGWindowID)
    func trackerWindowMiniaturizedChanged(id: CGWindowID, miniaturized: Bool)
    func trackerWindowDestroyed(id: CGWindowID)
    func trackerWindowFocused(id: CGWindowID)
    func trackerWindowFullscreenChanged(id: CGWindowID, isFullscreen: Bool)
    func trackerFinderTerminated()
    /// オンスクリーンのFinderウィンドウ集合が変化した(タブ切替はAX通知を発火しないためポーリングで検知)
    func trackerOnScreenWindowsChanged()
}

final class FinderWindowTracker {
    weak var delegate: FinderWindowTrackerDelegate?

    /// AX通知名。SDK定数のSwiftインポート型(String/CFString)の揺れを避けるためリテラルで持つ
    private enum AXNote {
        static let created = "AXWindowCreated"
        static let focusedChanged = "AXFocusedWindowChanged"
        static let destroyed = "AXUIElementDestroyed"
        static let moved = "AXWindowMoved"
        static let resized = "AXWindowResized"
        static let miniaturized = "AXWindowMiniaturized"
        static let deminiaturized = "AXWindowDeminiaturized"
        static let titleChanged = "AXTitleChanged"
        static let standardWindowSubrole = "AXStandardWindow"
    }

    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var windows: [CGWindowID: AXUIElement] = [:]
    private var dragTimer: Timer?
    private var draggingWindowID: CGWindowID?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingReattach: DispatchWorkItem?
    private var finderPid: pid_t = 0
    private var visibilityTimer: Timer?
    private var lastOnScreenIDs: Set<CGWindowID> = []

    // MARK: - 起動/停止

    func start() {
        // 権限の再取得等でstart()が複数回呼ばれても監視やObserverが多重登録されないようにする。
        // ただしウィンドウ/ペインは生きたままの再接続なので、trackerWindowDestroyedは発火させない。
        resetPendingWork()
        teardownObserver(notifyDestroyed: false)
        attachToFinder()
        // Finderの再起動を監視(仕様5.1)
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.finder" else { return }
                self?.teardownObserver(notifyDestroyed: true)
                self?.delegate?.trackerFinderTerminated()
        })
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.finder" else { return }
                // AX木が構築されるまで少し待って再接続
                self?.pendingReattach?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.attachToFinder() }
                self?.pendingReattach = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        })
    }

    func stop() {
        resetPendingWork()
        teardownObserver(notifyDestroyed: true)
    }

    deinit {
        stop()
    }

    /// pendingReattachのキャンセルとworkspace通知の解除(start()/stop()共通の前段)
    private func resetPendingWork() {
        pendingReattach?.cancel()
        pendingReattach = nil
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens = []
    }

    private func attachToFinder() {
        guard let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder").first else { return }
        let pid = finder.processIdentifier
        finderPid = pid
        let app = AXUIElementCreateApplication(pid)
        appElement = app

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FinderWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, app, AXNote.created as CFString, refcon)
        AXObserverAddNotification(obs, app, AXNote.focusedChanged as CFString, refcon)

        // 既存ウィンドウの列挙
        reenumerateWindows()
        startVisibilityPolling()
    }

    /// AXウィンドウ一覧を再列挙し、未知のウィンドウ(表になったタブ等)を登録する。
    /// 注意: バックグラウンドのタブはAXウィンドウ一覧に現れない(実測)。
    private func reenumerateWindows() {
        guard let app = appElement else { return }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement] {
            list.forEach { register(windowElement: $0) }
        }
    }

    // MARK: - オンスクリーン集合のポーリング(タブ切替対策)

    /// タブ切り替えは既存タブ間ではAX通知を一切発火しない(実測)ため、
    /// オンスクリーンウィンドウ集合の変化を0.5秒間隔のポーリングで検知する。
    private func startVisibilityPolling() {
        visibilityTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollOnScreenChanges()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    private func stopVisibilityPolling() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        lastOnScreenIDs = []
    }

    private func pollOnScreenChanges() {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return }
        var ids: Set<CGWindowID> = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid == finderPid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            ids.insert(num)
        }
        guard ids != lastOnScreenIDs else { return }
        let appeared = ids.subtracting(lastOnScreenIDs)
        lastOnScreenIDs = ids
        DebugLog.log("onScreen changed: now=\(ids.sorted()) appeared=\(appeared.sorted())")
        if !appeared.isEmpty {
            // 表になったタブはこの時点でAX一覧に現れるので登録できる
            reenumerateWindows()
        }
        delegate?.trackerOnScreenWindowsChanged()
    }

    /// notifyDestroyed: Finder終了等でウィンドウが実際に消えた場合はtrue(delegateにdestroyedを通知)。
    /// 権限再許可等でウィンドウ/ペインが生きたまま再接続する場合はfalse(windowsは必ずクリアするが通知はしない)。
    private func teardownObserver(notifyDestroyed: Bool) {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        appElement = nil
        let ids = Array(windows.keys)
        windows.removeAll()
        stopDragPolling()
        stopVisibilityPolling()
        if notifyDestroyed {
            ids.forEach { delegate?.trackerWindowDestroyed(id: $0) }
        }
    }

    // MARK: - ウィンドウ登録

    private func register(windowElement: AXUIElement) {
        // 通常のウィンドウのみ(仕様4.1: ダイアログ・シート除外)
        guard stringAttribute(windowElement, kAXSubroleAttribute as String) == AXNote.standardWindowSubrole,
              let id = windowID(of: windowElement),
              windows[id] == nil,
              let frame = frameAX(of: windowElement) else {
            DebugLog.log("register skip id=\(windowID(of: windowElement).map(String.init) ?? "?") subrole=\(stringAttribute(windowElement, kAXSubroleAttribute as String) ?? "nil")")
            return
        }
        DebugLog.log("register ok id=\(id) frame=\(frame)")

        windows[id] = windowElement
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let obs = observer else { return }
        for name in [AXNote.destroyed, AXNote.moved, AXNote.resized,
                     AXNote.miniaturized, AXNote.deminiaturized, AXNote.titleChanged] {
            AXObserverAddNotification(obs, windowElement, name as CFString, refcon)
        }
        delegate?.trackerWindowAppeared(id: id, frameAX: frame)
    }

    // MARK: - 通知処理

    private func handle(notification: String, element: AXUIElement) {
        DebugLog.log("AX \(notification) id=\(windowID(of: element).map(String.init) ?? "?") subrole=\(stringAttribute(element, kAXSubroleAttribute as String) ?? "?") known=\(windowID(of: element).map { windows[$0] != nil } ?? false)")
        switch notification {
        case AXNote.created:
            register(windowElement: element)
        case AXNote.focusedChanged:
            if let id = windowID(of: element) {
                if windows[id] != nil {
                    delegate?.trackerWindowFocused(id: id)
                } else {
                    DebugLog.log("focusedChanged for UNKNOWN id=\(id) → register試行")
                    register(windowElement: element)
                }
            }
        case AXNote.destroyed:
            // 破棄済み要素からはIDが取れないことがあるので、保持している要素と突き合わせる
            if let (id, _) = windows.first(where: { CFEqual($0.value, element) }) {
                windows[id] = nil
                if draggingWindowID == id { stopDragPolling() }
                delegate?.trackerWindowDestroyed(id: id)
            }
        case AXNote.moved, AXNote.resized:
            guard let id = windowID(of: element), windows[id] != nil,
                  let frame = frameAX(of: element) else { return }
            delegate?.trackerWindowFrameChanged(id: id, frameAX: frame)
            notifyFullscreen(id: id, element: element)
            // 仕様4.2: ドラッグ中は60Hzで補間
            if NSEvent.pressedMouseButtons & 1 != 0 { startDragPolling(id: id, element: element) }
        case AXNote.miniaturized:
            if let id = windowID(of: element) {
                delegate?.trackerWindowMiniaturizedChanged(id: id, miniaturized: true)
            }
        case AXNote.deminiaturized:
            if let id = windowID(of: element) {
                delegate?.trackerWindowMiniaturizedChanged(id: id, miniaturized: false)
            }
        case AXNote.titleChanged:
            if let id = windowID(of: element), windows[id] != nil {
                delegate?.trackerWindowTitleChanged(id: id)
            }
        default:
            break
        }
    }

    // MARK: - ドラッグ補間(仕様4.2)

    private func startDragPolling(id: CGWindowID, element: AXUIElement) {
        guard draggingWindowID != id else { return }
        stopDragPolling()
        draggingWindowID = id
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.stopDragPolling()
                return
            }
            if let frame = self.frameAX(of: element) {
                self.delegate?.trackerWindowFrameChanged(id: id, frameAX: frame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragPolling() {
        dragTimer?.invalidate()
        dragTimer = nil
        draggingWindowID = nil
    }

    // MARK: - AX属性ヘルパー

    private func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private func frameAX(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        guard let posRef = posValue, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = sizeValue, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let posAXValue = unsafeDowncast(posRef, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeRef, to: AXValue.self)
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAXValue, .cgPoint, &pos),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func notifyFullscreen(id: CGWindowID, element: AXUIElement) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success,
           let isFS = value as? Bool {
            delegate?.trackerWindowFullscreenChanged(id: id, isFullscreen: isFS)
        }
    }
}
