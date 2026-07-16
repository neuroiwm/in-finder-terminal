import AppKit
import SwiftTerm

final class TerminalSession: NSObject {
    let terminalView: TerminalView
    private let pty: PtyProcess
    private let inspector: ShellInspecting
    private(set) var isTerminated = false
    var onExit: (() -> Void)?
    var onBecameIdle: (() -> Void)?
    private var idleTimer: Timer?
    private var wasBusy = false

    init?(initialDirectory: String, frame: CGRect) {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        guard let pty = PtyProcess(shellPath: shellPath,
                                   arguments: [],
                                   loginShell: true,
                                   environment: env,
                                   initialDirectory: initialDirectory) else { return nil }
        self.pty = pty
        self.inspector = PtyShellInspector(masterFD: pty.masterFD, shellPid: pty.pid)
        self.terminalView = TerminalView(frame: frame)
        super.init()

        terminalView.terminalDelegate = self
        pty.onData = { [weak self] slice in
            self?.terminalView.feed(byteArray: slice)
        }
        pty.onExit = { [weak self] _ in
            guard let self else { return }
            self.isTerminated = true
            self.idleTimer?.invalidate()
            self.onExit?()
        }
        let t = terminalView.getTerminal()
        pty.resize(cols: UInt16(t.cols), rows: UInt16(t.rows))
        startIdlePolling()
    }

    var isIdle: Bool {
        guard !isTerminated, let fg = inspector.foregroundProcessGroup() else { return false }
        return fg == inspector.shellProcessGroup()
    }

    /// 仕様4.4: アイドル時のみ、Ctrl-U+cd注入でディレクトリを同期する
    func syncDirectoryIfIdle(to path: String) {
        guard !isTerminated,
              SyncDecider.shouldInjectCd(target: path, inspector: inspector) else { return }
        pty.write(CdInjector.injectionBytes(for: path))
    }

    func terminate() {
        idleTimer?.invalidate()
        idleTimer = nil
        isTerminated = true
        pty.terminate()
    }

    /// テスト・デバッグ用: シェルの実cwd
    func debugShellCwd() -> String? {
        inspector.shellWorkingDirectory()
    }

    /// 仕様4.4: busy→idle遷移(claude終了など)を1秒ポーリングで検知して通知する
    private func startIdlePolling() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isTerminated else { return }
            let busy = !self.isIdle
            if self.wasBusy && !busy { self.onBecameIdle?() }
            self.wasBusy = busy
        }
    }
}

extension TerminalSession: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pty.write(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        pty.resize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
