import XCTest
@testable import FinderTerm

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.iwama.finderterm.tests")!
        defaults.removePersistentDomain(forName: "com.iwama.finderterm.tests")
    }

    func testDefaultRatioIs04() {
        XCTAssertEqual(Preferences(defaults: defaults).paneHeightRatio, 0.4)
    }

    func testRatioRoundTripsAndClamps() {
        let p = Preferences(defaults: defaults)
        p.paneHeightRatio = 0.55
        XCTAssertEqual(Preferences(defaults: defaults).paneHeightRatio, 0.55)
        p.paneHeightRatio = 5.0
        XCTAssertEqual(p.paneHeightRatio, 0.9)
    }

    func testPanesVisibleDefaultsTrue() {
        let p = Preferences(defaults: defaults)
        XCTAssertTrue(p.panesVisible)
        p.panesVisible = false
        XCTAssertFalse(Preferences(defaults: defaults).panesVisible)
    }
}
