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
}
