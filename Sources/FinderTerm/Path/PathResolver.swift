import Foundation
import ApplicationServices

final class PathResolver {
    private let queue = DispatchQueue(label: "com.iwama.finderterm.applescript")
    private let timeout: TimeInterval = 2.0

    /// true/false = Finderの確定回答、nil = タイムアウト等で不明(呼び出し側でリトライすること)。
    /// 起動直後の初回AppleEventsはコールドスタートで2秒を超えることがある(実測)。
    func isBrowserWindow(windowID: CGWindowID, completion: @escaping (Bool?) -> Void) {
        // Finderスクリプティングの「Finder window」クラスはファイルブラウザのみを指す
        let script = """
        tell application "Finder" to return (exists Finder window id \(windowID)) as text
        """
        run(script: script) { result in
            switch result {
            case "true": completion(true)
            case "false": completion(false)
            default: completion(nil)
            }
        }
    }

    func resolveFolderPath(windowID: CGWindowID, completion: @escaping (String?) -> Void) {
        // パスなし画面(最近の項目・AirDrop等)はalias強制変換がエラーになる → nil(仕様4.3)
        let script = """
        tell application "Finder"
            return POSIX path of (target of Finder window id \(windowID) as alias)
        end tell
        """
        run(script: script) { result in
            completion((result?.isEmpty == false) ? result : nil)
        }
    }

    /// 専用シリアルキューでNSAppleScriptを実行。2秒以内に返らなければnil(遅れて来た結果は捨てる)
    /// 注意: AppleScriptはキャンセル不能なため、Finderが長時間ハングすると後続リクエストは
    /// このシリアルキューに滞留する(各呼び出し側のタイムアウトは2秒で正しく発火する)。
    /// 呼び出し側(AppCoordinator)は300msデバウンスで発行頻度を抑えており、実用上問題にならない想定。
    private func run(script source: String, completion: @escaping (String?) -> Void) {
        final class Once { var done = false }
        let once = Once()
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !once.done else { return }
            once.done = true
            DebugLog.log("applescript TIMEOUT (\(self.timeout)s)")
            completion(nil)
        }
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?
                .executeAndReturnError(&error).stringValue
            if let error {
                NSLog("FinderTerm: AppleScript error: %@", error)
            }
            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(started)
                guard !once.done else {
                    DebugLog.log("applescript late result after \(String(format: "%.2f", elapsed))s (discarded)")
                    return
                }
                once.done = true
                completion(result)
            }
        }
    }
}
