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

    /// 仕様4.4: アイドル時のみ、Ctrl-U+cd注入でディレクトリを同期する(アンカー中は追従しない)
    func syncDirectoryIfIdle(to path: String) {
        guard !isTerminated, !isAnchored,
              SyncDecider.shouldInjectCd(target: path, inspector: inspector) else { return }
        pty.write(CdInjector.injectionBytes(for: path))
    }

    // MARK: - アンカー(仕様4.6)

    /// アンカー閾値: これ以上走ったフォアグラウンドコマンドの終了でアンカーする(テストで短縮可)
    var anchorThreshold: TimeInterval = 30

    /// アンカー中 = 長時間コマンド(claude等)が終了したフォルダに固定され、自動cdを停止している。
    /// claude --resume がcwd単位でセッションを探すため、作業したフォルダから勝手に動かないようにする
    private(set) var isAnchored = false
    private var anchoredCwd: String?
    private var busySince: Date?

    /// 0.5秒ごとに呼ばれる: busy時間を計測し、長時間コマンドの終了でアンカー。
    /// アンカー中にユーザーが手動でcdしたら(cwdがアンカー時点から変わったら)追従を再開する
    func tickAnchorState() {
        guard !isTerminated else { return }
        if !isIdle {
            if busySince == nil { busySince = Date() }
            return
        }
        if let since = busySince {
            busySince = nil
            let duration = Date().timeIntervalSince(since)
            if duration >= anchorThreshold {
                isAnchored = true
                anchoredCwd = inspector.shellWorkingDirectory()
                DebugLog.log("anchored after \(Int(duration))s cmd, cwd=\(anchoredCwd ?? "?")")
            }
        }
        if isAnchored, let anchored = anchoredCwd,
           let cwd = inspector.shellWorkingDirectory(), cwd != anchored {
            DebugLog.log("anchor released by manual cd: \(anchored) → \(cwd)")
            releaseAnchor()
        }
    }

    /// アンカー解除(手動cd検知またはメニューの「追従を再開」)
    func releaseAnchor() {
        isAnchored = false
        anchoredCwd = nil
    }

    func terminate() {
        isTerminated = true
        pty.terminate()
    }

    /// テスト・デバッグ用: シェルの実cwd
    func debugShellCwd() -> String? {
        inspector.shellWorkingDirectory()
    }

    /// テスト用: ptyへ生の入力を書き込む(キー入力相当)
    func sendInput(_ text: String) {
        pty.write(Array(text.utf8))
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
