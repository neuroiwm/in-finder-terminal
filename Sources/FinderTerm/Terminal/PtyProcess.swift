import Foundation
import Darwin

/// posix_openpt + posix_spawnによるptyシェル起動。
/// masterFDとpidを公開し、アイドル判定(tcgetpgrp)とcwd取得(proc_pidinfo)を可能にする。
final class PtyProcess {
    // Swiftに公開されないC定数(spawn.h / ttycom.h)
    private static let POSIX_SPAWN_SETSID: Int16 = 0x0400
    private static let TIOCSWINSZ: UInt = 0x8008_7467

    let masterFD: Int32
    let pid: pid_t
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let ioQueue = DispatchQueue(label: "com.iwama.finderterm.pty")
    private var terminated = false

    init?(shellPath: String,
          arguments: [String],
          loginShell: Bool,
          environment: [String: String],
          initialDirectory: String) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveNameC = ptsname(master) else {
            if master >= 0 { close(master) }
            return nil
        }
        let slavePath = String(cString: slaveNameC)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        // setsid後に最初に開いたttyが制御端末になる。fd 0/1/2をslaveに向ける
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addchdir_np(&fileActions, initialDirectory)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Self.POSIX_SPAWN_SETSID)

        // ログインシェル慣例: argv[0]を"-zsh"のようにする
        let baseName = (shellPath as NSString).lastPathComponent
        let argv0 = loginShell ? "-" + baseName : baseName
        let argv: [String] = [argv0] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, shellPath, &fileActions, &attrs, cArgv, cEnv)

        cArgv.forEach { if let p = $0 { free(p) } }
        cEnv.forEach { if let p = $0 { free(p) } }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attrs)

        guard rc == 0 else {
            close(master)
            return nil
        }

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
            guard n > 0 else {
                self.readSource?.cancel()
                return
            }
            let slice = buf[0..<n]
            DispatchQueue.main.async { self.onData?(slice) }
        }
        rs.resume()
        readSource = rs

        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        es.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            self.cleanup()
            self.onExit?(status)
        }
        es.resume()
        exitSource = es
    }

    func write(_ bytes: [UInt8]) {
        ioQueue.async { [masterFD] in
            _ = bytes.withUnsafeBufferPointer { ptr in
                Darwin.write(masterFD, ptr.baseAddress, ptr.count)
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, Self.TIOCSWINSZ, &size)
    }

    func terminate() {
        guard !terminated else { return }
        kill(pid, SIGHUP)
        cleanup()
    }

    private func cleanup() {
        guard !terminated else { return }
        terminated = true
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        close(masterFD)
    }

    deinit { terminate() }
}
