import AppKit
import ServiceManagement

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private let preferences: Preferences
    private let toggleItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let loginItem = NSMenuItem()

    init(coordinator: AppCoordinator, preferences: Preferences) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.coordinator = coordinator
        self.preferences = preferences
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "terminal",
                                           accessibilityDescription: "FinderTerm")
        let menu = NSMenu()

        toggleItem.title = "ペインを表示"
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.option, .command]
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
    }
}
