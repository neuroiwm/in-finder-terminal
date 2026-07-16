import Foundation
import Darwin

/// forkpty() + execve()によるptyシェル起動。
/// masterFDとpidを公開し、アイドル判定(tcgetpgrp)とcwd取得(proc_pidinfo)を可能にする。
///
/// posix_spawn + POSIX_SPAWN_SETSID + ファイルアクションでslave ptyをfd 0に開く方式は、
/// 実機検証の結果、子シェルの制御端末(ctty)が設定されないことが判明した
/// (`ps` でTTYが`??`、zshの`$options[monitor]`が`off`)。ctty未設定だとシェルは
/// ジョブ制御(job control)を有効化できず、フォアグラウンドプロセスグループを
/// 一切変更しない(tcsetpgrpを呼ばない)ため、実行中のコマンドとアイドル状態の
/// プロンプトを`tcgetpgrp`で区別できなくなる。
/// forkpty()はSwiftTermのLocalProcessと同様、子プロセス内でsetsid() + TIOCSCTTYを
/// 正しい順序で実行し、ctty取得とジョブ制御を保証する。
final class PtyProcess {
    private static let TIOCSWINSZ: UInt = 0x8008_7467

    let masterFD: Int32
    let pid: pid_t
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let ioQueue = DispatchQueue(label: "com.iwama.finderterm.pty")
    private var terminated = false
    private var exitObserved = false
    private let stateLock = NSLock()

    init?(shellPath: String,
          arguments: [String],
          loginShell: Bool,
          environment: [String: String],
          initialDirectory: String) {
        // fork前にargv/envのCバッファを構築しておく。fork〜exec間はasync-signal-safeな
        // 呼び出し(chdir, execve, _exit)のみを行うため、strdup等のヒープ操作は
        // すべてここで済ませる。
        let baseName = (shellPath as NSString).lastPathComponent
        let argv0 = loginShell ? "-" + baseName : baseName
        let argv: [String] = [argv0] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        func freeCStrings() {
            cArgv.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
        }

        var master: Int32 = -1
        let childPid = forkpty(&master, nil, nil, nil)

        if childPid < 0 {
            freeCStrings()
            return nil
        }

        if childPid == 0 {
            // 子プロセス: forkpty()がsetsid() + TIOCSCTTYおよびfd 0/1/2の
            // dup2をすでに実行済み。ここではasync-signal-safeな呼び出しのみ行う。
            _ = chdir(initialDirectory)
            cArgv.withUnsafeMutableBufferPointer { argvBuf in
                cEnv.withUnsafeMutableBufferPointer { envBuf in
                    _ = execve(shellPath, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            // execve失敗時のみここに到達する。
            _exit(127)
        }

        // 親プロセス
        freeCStrings()
        self.masterFD = master
        self.pid = childPid
        startMonitoring()
    }

    private func startMonitoring() {
        let rs = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        rs.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let slice = buf[0..<n]
                DispatchQueue.main.async { self.onData?(slice) }
                return
            }
            if n < 0 && (errno == EINTR || errno == EAGAIN) {
                // 一時的な割り込み・再試行要求。ソースは再度発火するのでキャンセルしない。
                return
            }
            // n == 0 (EOF) またはその他の読み取りエラー。読み取りループを終了する。
            self.readSource?.cancel()
        }
        // fdのクローズはioQueue上でシリアライズされたキャンセルハンドラで行う。
        // これによりイベントハンドラがread()実行中でも、クローズはその完了後になる。
        rs.setCancelHandler { [masterFD] in
            close(masterFD)
        }
        rs.resume()
        readSource = rs

        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        es.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            self.markExitObserved()
            self.cleanup()
            self.onExit?(status)
        }
        es.resume()
        exitSource = es
    }

    private func markExitObserved() {
        stateLock.lock()
        exitObserved = true
        stateLock.unlock()
    }

    private func isTerminated() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminated
    }

    func write(_ bytes: [UInt8]) {
        guard !isTerminated() else { return }
        ioQueue.async { [masterFD] in
            _ = bytes.withUnsafeBufferPointer { ptr in
                Darwin.write(masterFD, ptr.baseAddress, ptr.count)
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard !isTerminated() else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, Self.TIOCSWINSZ, &size)
    }

    func terminate() {
        stateLock.lock()
        if terminated {
            stateLock.unlock()
            return
        }
        let needsReap = !exitObserved
        stateLock.unlock()

        kill(pid, SIGHUP)
        cleanup()

        // exitSourceのハンドラがまだ発火(=waitpid済み)していない場合、
        // ここでキャンセルしてしまうと二度と発火しないため、確実に回収する。
        // exitSourceのハンドラと競合してもどちらか一方がECHILDを受け取るだけで無害。
        if needsReap {
            let childPid = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                waitpid(childPid, &status, 0)
            }
        }
    }

    private func cleanup() {
        stateLock.lock()
        if terminated {
            stateLock.unlock()
            return
        }
        terminated = true
        stateLock.unlock()

        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
    }

    deinit { terminate() }
}
