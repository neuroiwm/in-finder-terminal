import XCTest
@testable import FinderTerm

private struct MockInspector: ShellInspecting {
    var fg: pid_t?
    var shellPG: pid_t
    var cwd: String?
    func foregroundProcessGroup() -> pid_t? { fg }
    func shellProcessGroup() -> pid_t { shellPG }
    func shellWorkingDirectory() -> String? { cwd }
}

final class SyncDeciderTests: XCTestCase {
    func testInjectsWhenShellIsForegroundAndCwdDiffers() {
        let m = MockInspector(fg: 100, shellPG: 100, cwd: "/old")
        XCTAssertTrue(SyncDecider.shouldInjectCd(target: "/new", inspector: m))
    }

    func testDoesNotInjectWhenForegroundIsAnotherProcess() {
        // claude等が前面 → 絶対に注入しない(仕様R4)
        let m = MockInspector(fg: 200, shellPG: 100, cwd: "/old")
        XCTAssertFalse(SyncDecider.shouldInjectCd(target: "/new", inspector: m))
    }

    func testDoesNotInjectWhenForegroundUnknown() {
        let m = MockInspector(fg: nil, shellPG: 100, cwd: "/old")
        XCTAssertFalse(SyncDecider.shouldInjectCd(target: "/new", inspector: m))
    }

    func testDoesNotInjectWhenAlreadyThere() {
        let m = MockInspector(fg: 100, shellPG: 100, cwd: "/same")
        XCTAssertFalse(SyncDecider.shouldInjectCd(target: "/same", inspector: m))
    }

    func testPathComparisonIsStandardized() {
        let m = MockInspector(fg: 100, shellPG: 100, cwd: "/same/dir")
        XCTAssertFalse(SyncDecider.shouldInjectCd(target: "/same/dir/", inspector: m))
    }

    func testInjectsWhenCwdUnknown() {
        // cwdが取れないときは注入する(安全側=追従優先)
        let m = MockInspector(fg: 100, shellPG: 100, cwd: nil)
        XCTAssertTrue(SyncDecider.shouldInjectCd(target: "/new", inspector: m))
    }
}
