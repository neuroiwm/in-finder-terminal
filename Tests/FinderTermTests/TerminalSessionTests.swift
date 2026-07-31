import XCTest
@testable import FinderTerm

final class TerminalSessionTests: XCTestCase {
    func testSessionBecomesIdleAndSyncsDirectory() throws {
        let session = try XCTUnwrap(
            TerminalSession(initialDirectory: "/tmp",
                            frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        defer { session.terminate() }

        // プロンプトが出てアイドルになるまで待つ(最大5秒)
        waitUntil(timeout: 5.0) { session.isIdle }
        XCTAssertTrue(session.isIdle)

        // アイドルなのでcd注入される → cwdが変わる
        session.syncDirectoryIfIdle(to: "/usr/share")
        waitUntil(timeout: 5.0) {
            session.debugShellCwd().map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == "/usr/share"
            } ?? false
        }
        XCTAssertEqual(session.debugShellCwd().map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }, "/usr/share")
    }

    func testAnchorAfterLongCommandAndReleaseByManualCd() throws {
        let session = try XCTUnwrap(
            TerminalSession(initialDirectory: "/tmp",
                            frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        defer { session.terminate() }
        session.anchorThreshold = 1.0  // テスト用に短縮

        waitUntil(timeout: 5.0) { session.isIdle }
        XCTAssertFalse(session.isAnchored)

        // 閾値超の長時間コマンド → 終了後にアンカーされる
        session.sendInput("sleep 2\r")
        waitUntil(timeout: 3.0) { session.tickAnchorState(); return !session.isIdle }
        waitUntil(timeout: 5.0) { session.tickAnchorState(); return session.isAnchored }
        XCTAssertTrue(session.isAnchored)

        // アンカー中はcd注入されない
        let before = session.debugShellCwd()
        session.syncDirectoryIfIdle(to: "/usr/share")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertEqual(session.debugShellCwd(), before)

        // 手動cd(ユーザー操作相当)でアンカー解除
        session.sendInput("cd /usr\r")
        waitUntil(timeout: 5.0) { session.tickAnchorState(); return !session.isAnchored }
        XCTAssertFalse(session.isAnchored)

        // 解除後は追従が復活する
        session.syncDirectoryIfIdle(to: "/usr/share")
        waitUntil(timeout: 5.0) {
            session.debugShellCwd().map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == "/usr/share"
            } ?? false
        }
        XCTAssertEqual(session.debugShellCwd().map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }, "/usr/share")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}
