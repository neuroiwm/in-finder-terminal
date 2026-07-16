import Foundation
import Darwin

struct PtyShellInspector: ShellInspecting {
    let masterFD: Int32
    let shellPid: pid_t

    func foregroundProcessGroup() -> pid_t? {
        let pg = tcgetpgrp(masterFD)
        return pg > 0 ? pg : nil
    }

    func shellProcessGroup() -> pid_t {
        // forkptyによりシェルはセッションリーダー = pgid == pid
        let pg = getpgid(shellPid)
        return pg > 0 ? pg : shellPid
    }

    func shellWorkingDirectory() -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(shellPid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n > 0 else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }
}
