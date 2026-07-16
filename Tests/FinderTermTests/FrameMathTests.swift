import XCTest
@testable import FinderTerm

final class FrameMathTests: XCTestCase {
    func testPaneFrameIsBottomPortionInAXCoords() {
        // AX座標系は左上原点・Y下向き。下半分 = yが大きい側
        let finder = CGRect(x: 100, y: 200, width: 800, height: 600)
        let pane = FrameMath.paneFrameAX(finderFrame: finder, ratio: 0.4)
        XCTAssertEqual(pane, CGRect(x: 100, y: 560, width: 800, height: 240))
    }

    func testRatioIsClamped() {
        let finder = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(FrameMath.paneFrameAX(finderFrame: finder, ratio: 0.05).height, 10)
        XCTAssertEqual(FrameMath.paneFrameAX(finderFrame: finder, ratio: 1.5).height, 90)
    }

    func testAxToCocoaFlipsY() {
        // 高さ900の主画面。AXでy=560, h=240 → Cocoaではy = 900 - (560+240) = 100
        let ax = CGRect(x: 100, y: 560, width: 800, height: 240)
        let cocoa = FrameMath.axToCocoa(ax, primaryScreenHeight: 900)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 100, width: 800, height: 240))
    }
}
