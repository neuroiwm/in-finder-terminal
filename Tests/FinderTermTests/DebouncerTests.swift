import XCTest
@testable import FinderTerm

final class DebouncerTests: XCTestCase {
    func testOnlyLastCallFires() {
        let exp = expectation(description: "fired once")
        var count = 0
        let d = Debouncer(delay: 0.05)
        d.call { count += 1; XCTFail("最初の呼び出しはキャンセルされるべき") }
        d.call { count += 1; exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(count, 1)
    }

    func testCancelPreventsFiring() {
        var fired = false
        let d = Debouncer(delay: 0.05)
        d.call { fired = true }
        d.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertFalse(fired)
    }
}
