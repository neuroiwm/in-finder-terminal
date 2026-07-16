import Foundation
import Darwin

struct PtyShellInspector: ShellInspecting {
    let masterFD: Int32
    let shellPid: pid_t

    func foregroundProcessGroup() -> pid_t? {
        // Query the foreground process group from the pty master
        // On macOS, tcgetpgrp may return 0 for an idle shell when using certain
        // shell flags, in which case we treat the shell itself as the foreground
        let pg = tcgetpgrp(masterFD)
        if pg > 0 {
            return pg
        }
        if pg == 0 {
            return shellProcessGroup()
        }
        // pg == -1 indicates an error
        return nil
    }

    func shellProcessGroup() -> pid_t {
        // POSIX_SPAWN_SETSIDによりシェルはセッションリーダー = pgid == pid
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
