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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}
