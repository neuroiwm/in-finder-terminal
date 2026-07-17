import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItemController: StatusItemController?
    private let hotkeyManager = HotkeyManager()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let c = AppCoordinator()
        statusItemController = StatusItemController(coordinator: c, preferences: .shared)
        c.start()
        coordinator = c
        hotkeyManager.onHotkey = { [weak c] in
            DebugLog.log("hotkey ⌥⌘T fired")
            c?.togglePanesVisible()
        }
        hotkeyManager.register()
    }

    /// LSUIElementアプリはメニューバーを持たないが、⌘V等のキーイクイバレントは
    /// NSApp.mainMenu経由でディスパッチされるため、編集メニューをインストールしておく必要がある。
    private func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "カット", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (coordinator?.confirmQuitTerminatingSessions() ?? true) ? .terminateNow : .terminateCancel
    }
}
