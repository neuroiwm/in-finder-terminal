import AppKit
import ApplicationServices

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tracker: FinderWindowTracker?
    private let debugDelegate = DebugTrackerDelegate()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            NSLog("FinderTerm: アクセシビリティ権限がありません(許可後に再起動してください)")
            return
        }
        let t = FinderWindowTracker()
        t.delegate = debugDelegate
        t.start()
        tracker = t
    }
}

/// Task 13でAppCoordinatorに置き換えるまでの暫定デバッグ出力
final class DebugTrackerDelegate: FinderWindowTrackerDelegate {
    private let resolver = PathResolver()

    private func logPath(_ id: CGWindowID) {
        resolver.isBrowserWindow(windowID: id) { isBrowser in
            NSLog("isBrowser %d = %d", id, isBrowser ? 1 : 0)
            guard isBrowser else { return }
            self.resolver.resolveFolderPath(windowID: id) { path in
                NSLog("path %d = %@", id, path ?? "(nil)")
            }
        }
    }

    func trackerWindowAppeared(id: CGWindowID, frameAX: CGRect) { NSLog("appeared %d", id); logPath(id) }
    func trackerWindowTitleChanged(id: CGWindowID) { NSLog("title %d", id); logPath(id) }
    func trackerWindowFrameChanged(id: CGWindowID, frameAX: CGRect) {}
    func trackerWindowMiniaturizedChanged(id: CGWindowID, miniaturized: Bool) {}
    func trackerWindowDestroyed(id: CGWindowID) { NSLog("destroyed %d", id) }
    func trackerWindowFocused(id: CGWindowID) {}
    func trackerWindowFullscreenChanged(id: CGWindowID, isFullscreen: Bool) {}
    func trackerFinderTerminated() { NSLog("finder terminated") }
}
