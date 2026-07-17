import Foundation

/// 診断ログ。`defaults write com.iwama.finderterm debugLogging -bool true` で有効化。
/// unified logはNSLogの動的内容を<private>に秘匿するため、ファイルに直接書く。
/// 出力先: ~/Library/Logs/FinderTerm.log
enum DebugLog {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLogging")

    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FinderTerm.log")
    private static let queue = DispatchQueue(label: "com.iwama.finderterm.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
