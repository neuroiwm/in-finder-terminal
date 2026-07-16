import XCTest
@testable import FinderTerm

final class PtyShellInspectorTests: XCTestCase {
    private var pty: PtyProcess!
    private var inspector: PtyShellInspector!

    override func setUp() {
        super.setUp()
        // -f: rcファイルを読まないzsh(環境差の排除)
        pty = PtyProcess(shellPath: "/bin/zsh",
                         arguments: ["-f", "-i"],
                         loginShell: false,
                         environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()],
                         initialDirectory: "/tmp")
        XCTAssertNotNil(pty)
        inspector = PtyShellInspector(masterFD: pty.masterFD, shellPid: pty.pid)
        // プロンプトが出るまで少し待つ
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
    }

    override func tearDown() {
        pty?.terminate()
        super.tearDown()
    }

    func testIdleShellIsForeground() {
        XCTAssertEqual(inspector.foregroundProcessGroup(), inspector.shellProcessGroup())
    }

    func testRunningCommandIsNotShellForeground() {
        pty.write(Array("sleep 5\r".utf8))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        let fg = inspector.foregroundProcessGroup()
        XCTAssertNotNil(fg)
        XCTAssertNotEqual(fg, inspector.shellProcessGroup())
    }

    func testWorkingDirectoryIsReadable() {
        let cwd = inspector.shellWorkingDirectory()
        // /tmpは/private/tmpのシンボリックリンク
        XCTAssertEqual(URL(fileURLWithPath: cwd ?? "").resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path)
    }
}
