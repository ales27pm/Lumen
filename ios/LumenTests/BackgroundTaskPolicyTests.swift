import XCTest
@testable import Lumen

final class BackgroundTaskPolicyTests: XCTestCase {
    func testCriticalThermalDenied() {
        let d = BackgroundTaskPolicy.decide(.init(taskKind: .triggerScan, lowPowerMode: false, thermalState: .critical, isForeground: false, backgroundAgentsEnabled: true, requiresNetwork: false, estimatedCost: 1))
        XCTAssertFalse(d.allow)
    }
}
