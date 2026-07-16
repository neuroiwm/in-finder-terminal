import Foundation

enum CdInjector {
    static func escapeSingleQuotes(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Ctrl-Uで入力行をクリアしてから、先頭スペース付きでcdを実行する。
    /// 先頭スペースは HIST_IGNORE_SPACE(zsh)/ignorespace(bash) 設定時に履歴を汚さないための保険。
    /// 改行はptyのEnter相当であるCR(0x0d)
    static func injectionBytes(for path: String) -> [UInt8] {
        let command = " cd '\(escapeSingleQuotes(path))'"
        return [0x15] + Array(command.utf8) + [0x0d]
    }
}
