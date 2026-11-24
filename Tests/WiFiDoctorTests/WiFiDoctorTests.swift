import XCTest
@testable import WiFiDoctor

// Requires full Xcode (XCTest). Command Line Tools alone can't run these; use `WiFiDoctor --selftest` instead.
final class WiFiDoctorTests: XCTestCase {
    func testSelfChecks() {
        XCTAssertEqual(SelfTest.run(), [])
    }
}
