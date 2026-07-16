import Foundation

/// ptyとシェルの状態を調べる能力の抽象(実装はTask 8のPtyShellInspector)
protocol ShellInspecting {
    /// ptyのフォアグラウンドプロセスグループID。取得失敗時はnil
    func foregroundProcessGroup() -> pid_t?
    /// シェル自身のプロセスグループID
    func shellProcessGroup() -> pid_t
    /// シェルの現在の作業ディレクトリ。取得失敗時はnil
    func shellWorkingDirectory() -> String?
}

enum SyncDecider {
    /// 仕様4.4: シェルがフォアグラウンド(=アイドル)かつcwdが移動先と異なるときだけcdを注入する
    static func shouldInjectCd(target: String, inspector: ShellInspecting) -> Bool {
        guard let fg = inspector.foregroundProcessGroup(),
              fg == inspector.shellProcessGroup() else { return false }
        if let cwd = inspector.shellWorkingDirectory(),
           URL(fileURLWithPath: cwd).standardizedFileURL.path
               == URL(fileURLWithPath: target).standardizedFileURL.path {
            return false
        }
        return true
    }
}
