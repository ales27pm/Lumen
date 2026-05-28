import XCTest
@testable import Lumen

final class PermissionStateTests: XCTestCase {
    func testStateRawValuesStable() { XCTAssertEqual(PermissionState.granted.rawValue, "granted") }
}
