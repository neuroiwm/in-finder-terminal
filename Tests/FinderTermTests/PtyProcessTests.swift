import XCTest
@testable import FinderTerm

final class PtyProcessTests: XCTestCase {
    func testSpawnEchoAndExit() {
        let dataExp = expectation(description: "received output")
        let exitExp = expectation(description: "process exited")
        var output = ""

        let pty = PtyProcess(shellPath: "/bin/sh",
                             arguments: ["-c", "echo hello-pty"],
                             loginShell: false,
                             environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
                             initialDirectory: "/tmp")
        XCTAssertNotNil(pty)
        pty?.onData = { slice in
            output += String(decoding: slice, as: UTF8.self)
            if output.contains("hello-pty") { dataExp.fulfill() }
        }
        pty?.onExit = { _ in exitExp.fulfill() }
        wait(for: [dataExp, exitExp], timeout: 5.0)
    }

    func testInitialDirectoryIsRespected() {
        let exp = expectation(description: "pwd output")
        var output = ""
        let pty = PtyProcess(shellPath: "/bin/sh",
                             arguments: ["-c", "pwd"],
                             loginShell: false,
                             environment: ["PATH": "/usr/bin:/bin"],
                             initialDirectory: "/usr/share")
        pty?.onData = { slice in
            output += String(decoding: slice, as: UTF8.self)
            if output.contains("/usr/share") { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5.0)
    }

    // Regression test: terminate() must not leave a zombie. terminate() sends SIGHUP to a
    // still-running child and must ensure the child is reaped (waitpid'd) even though the
    // process-exit DispatchSource is torn down before the child has actually died. If the
    // child were never reaped, it would linger as a zombie and `kill(pid, 0)` would keep
    // succeeding (ESRCH is only returned once the kernel has released the process entry).
    func testTerminateReapsChildWithoutZombie() {
        let pty = PtyProcess(shellPath: "/bin/sh",
                             arguments: ["-c", "sleep 30"],
                             loginShell: false,
                             environment: ["PATH": "/usr/bin:/bin"],
                             initialDirectory: "/tmp")
        XCTAssertNotNil(pty)
        guard let pty else { return }
        let childPid = pty.pid

        pty.terminate()

        let deadline = Date().addingTimeInterval(5.0)
        var reaped = false
        while Date() < deadline {
            if kill(childPid, 0) == -1 && errno == ESRCH {
                reaped = true
                break
            }
            usleep(50_000)
        }
        XCTAssertTrue(reaped, "child process \(childPid) was not reaped (zombie leak)")
    }
}
