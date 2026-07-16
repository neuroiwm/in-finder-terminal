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
        let c = AppCoordinator()
        statusItemController = StatusItemController(coordinator: c, preferences: .shared)
        c.start()
        coordinator = c
        hotkeyManager.onHotkey = { [weak c] in c?.togglePanesVisible() }
        hotkeyManager.register()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (coordinator?.confirmQuitTerminatingSessions() ?? true) ? .terminateNow : .terminateCancel
    }
}
