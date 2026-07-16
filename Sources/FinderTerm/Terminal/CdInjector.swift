import Foundation

enum CdInjector {
    static func escapeSingleQuotes(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Ctrl-Uで入力行をクリアしてから、履歴に残りにくいよう先頭スペース付きでcdを実行する。
    /// 改行はptyのEnter相当であるCR(0x0d)
    static func injectionBytes(for path: String) -> [UInt8] {
        let command = " cd '\(escapeSingleQuotes(path))'"
        return [0x15] + Array(command.utf8) + [0x0d]
    }
}
