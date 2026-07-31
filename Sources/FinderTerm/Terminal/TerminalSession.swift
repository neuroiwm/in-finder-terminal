import AppKit
import SwiftTerm

/// 非キー状態のペインへの初回クリックを吸わせない
final class FirstMouseTerminalView: TerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class TerminalSession: NSObject {
    let terminalView: TerminalView
    private let pty: PtyProcess
    private let inspector: ShellInspecting
    private(set) var isTerminated = false
    var onExit: (() -> Void)?

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
        self.terminalView = FirstMouseTerminalView(frame: frame)
        super.init()

        terminalView.terminalDelegate = self
        pty.onData = { [weak self] slice in
            self?.terminalView.feed(byteArray: slice)
        }
        pty.onExit = { [weak self] _ in
            guard let self else { return }
            self.isTerminated = true
            self.onExit?()
        }
        let t = terminalView.getTerminal()
        pty.resize(cols: UInt16(t.cols), rows: UInt16(t.rows))
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
        isTerminated = true
        pty.terminate()
    }

    /// テスト・デバッグ用: シェルの実cwd
    func debugShellCwd() -> String? {
        inspector.shellWorkingDirectory()
    }

    /// フォアグラウンドで実行中のコマンド名(アイドル時・取得失敗時はnil)。セッション一覧表示用
    var foregroundCommandName: String? {
        guard !isTerminated else { return nil }
        let fg = tcgetpgrp(pty.masterFD)
        guard fg > 0, fg != inspector.shellProcessGroup() else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(fg, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
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
