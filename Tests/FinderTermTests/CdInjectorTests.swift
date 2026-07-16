import XCTest
@testable import FinderTerm

final class CdInjectorTests: XCTestCase {
    func testEscapeSingleQuotes() {
        XCTAssertEqual(CdInjector.escapeSingleQuotes("/a/it's here"), "/a/it'\\''s here")
        XCTAssertEqual(CdInjector.escapeSingleQuotes("/plain/path"), "/plain/path")
    }

    func testInjectionBytesFormat() {
        // 仕様4.4: Ctrl-U(0x15) → 先頭スペース付き cd 'path' → CR(0x0d)
        let bytes = CdInjector.injectionBytes(for: "/tmp")
        XCTAssertEqual(bytes.first, 0x15)
        XCTAssertEqual(bytes.last, 0x0d)
        XCTAssertEqual(String(decoding: bytes.dropFirst().dropLast(), as: UTF8.self), " cd '/tmp'")
    }

    func testInjectionBytesEscapesQuotes() {
        let bytes = CdInjector.injectionBytes(for: "/a/it's")
        XCTAssertEqual(String(decoding: bytes.dropFirst().dropLast(), as: UTF8.self), " cd '/a/it'\\''s'")
    }
}
