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
    func trackerWindowAppeared(id: CGWindowID, frameAX: CGRect) { NSLog("appeared %d %@", id, "\(frameAX)") }
    func trackerWindowFrameChanged(id: CGWindowID, frameAX: CGRect) { NSLog("frame %d %@", id, "\(frameAX)") }
    func trackerWindowTitleChanged(id: CGWindowID) { NSLog("title %d", id) }
    func trackerWindowMiniaturizedChanged(id: CGWindowID, miniaturized: Bool) { NSLog("mini %d %d", id, miniaturized ? 1 : 0) }
    func trackerWindowDestroyed(id: CGWindowID) { NSLog("destroyed %d", id) }
    func trackerWindowFocused(id: CGWindowID) { NSLog("focused %d", id) }
    func trackerWindowFullscreenChanged(id: CGWindowID, isFullscreen: Bool) { NSLog("fullscreen %d %d", id, isFullscreen ? 1 : 0) }
    func trackerFinderTerminated() { NSLog("finder terminated") }
}
