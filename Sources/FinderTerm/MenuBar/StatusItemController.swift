import AppKit
import ServiceManagement

/// セッション一覧メニュー項目のactivateクロージャを保持する
private final class SessionMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private let preferences: Preferences
    private let frontToggleItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private var sessionItems: [NSMenuItem] = []

    init(coordinator: AppCoordinator, preferences: Preferences) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.coordinator = coordinator
        self.preferences = preferences
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "terminal",
                                           accessibilityDescription: "FinderTerm")
        let menu = NSMenu()

        frontToggleItem.title = "このウィンドウのペインをトグル"
        frontToggleItem.keyEquivalent = "t"
        frontToggleItem.keyEquivalentModifierMask = [.option, .command]
        frontToggleItem.target = self
        frontToggleItem.action = #selector(toggleFrontPane)
        menu.addItem(frontToggleItem)

        toggleItem.title = "全ペインを表示(全体スイッチ)"
        toggleItem.target = self
        toggleItem.action = #selector(togglePanes)
        menu.addItem(toggleItem)

        let heightMenu = NSMenu()
        for percent in [30, 40, 50] {
            let item = NSMenuItem(title: "\(percent)%",
                                  action: #selector(setHeight(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = percent
            heightMenu.addItem(item)
        }
        let heightItem = NSMenuItem(title: "ペインの高さ", action: nil, keyEquivalent: "")
        heightItem.submenu = heightMenu
        menu.addItem(heightItem)

        loginItem.title = "ログイン時に起動"
        loginItem.target = self
        loginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(loginItem)

        menu.addItem(.separator())
        permissionItem.title = "権限を確認..."
        permissionItem.target = self
        permissionItem.action = #selector(openAccessibilitySettings)
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "FinderTermを終了",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self

        coordinator.onPermissionStateChanged = { [weak self] trusted in
            self?.permissionItem.isHidden = trusted
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: trusted ? "terminal" : "exclamationmark.triangle",
                accessibilityDescription: "FinderTerm")
        }
    }

    @objc private func togglePanes() {
        coordinator.togglePanesVisible()
    }

    @objc private func toggleFrontPane() {
        coordinator.toggleFrontmostPane()
    }

    @objc private func activateSession(_ sender: NSMenuItem) {
        (sender.representedObject as? SessionMenuAction)?.run()
    }

    @objc private func setHeight(_ sender: NSMenuItem) {
        preferences.paneHeightRatio = CGFloat(sender.tag) / 100.0
    }

    @objc private func toggleLaunchAtLogin() {
        // .appバンドルとして起動しているときのみ有効(swift run中は失敗してよい)
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("FinderTerm: ログイン時起動の切替に失敗: \(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.state = preferences.panesVisible ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // セッション一覧をメニュー先頭に再構築
        sessionItems.forEach { menu.removeItem($0) }
        sessionItems = []
        let entries = coordinator.sessionMenuEntries()
        guard !entries.isEmpty else { return }

        var index = 0
        let header = NSMenuItem(title: "セッション", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.insertItem(header, at: index)
        sessionItems.append(header)
        index += 1

        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.indentationLevel = 1
            if let release = entry.releaseAnchor {
                // アンカー中はサブメニューで「前面へ」と「追従を再開」を出し分ける
                let sub = NSMenu()
                let show = NSMenuItem(title: "このウィンドウを前面へ",
                                      action: #selector(activateSession(_:)), keyEquivalent: "")
                show.target = self
                show.representedObject = SessionMenuAction(entry.activate)
                sub.addItem(show)
                let resume = NSMenuItem(title: "追従を再開(アンカー解除)",
                                        action: #selector(activateSession(_:)), keyEquivalent: "")
                resume.target = self
                resume.representedObject = SessionMenuAction(release)
                sub.addItem(resume)
                item.submenu = sub
            } else {
                item.action = #selector(activateSession(_:))
                item.target = self
                item.representedObject = SessionMenuAction(entry.activate)
            }
            menu.insertItem(item, at: index)
            sessionItems.append(item)
            index += 1
        }

        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: index)
        sessionItems.append(separator)
    }
}
