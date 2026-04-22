//
//  LumenUITests.swift
//  LumenUITests
//
//  Created by Rork on April 20, 2026.
//

import XCTest

final class LumenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissOnboardingIfNeeded()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testDeveloperSectionIsVisibleInSettings() throws {
        openSettings()
        assertDeveloperRowsExist()
    }

    @MainActor
    func testDeveloperRowsDisplayInRequestedOrder() throws {
        openSettings()
        let order = [
            "settings.developer.runTests",
            "settings.developer.logs",
            "settings.developer.debug",
            "settings.developer.diagnostic"
        ]
        var previousMinY: CGFloat = 0
        for (index, identifier) in order.enumerated() {
            let row = app.staticTexts[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing row: \(identifier)")
            let currentMinY = row.frame.minY
            if index > 0 {
                XCTAssertGreaterThan(currentMinY, previousMinY, "Row order is incorrect for \(identifier)")
            }
            previousMinY = currentMinY
        }
    }

    @MainActor
    func testDeveloperRowsRemainAccessibleAfterNavigationAwayAndBack() throws {
        openSettings()
        assertDeveloperRowsExist()

        if app.buttons["Chat"].exists {
            app.buttons["Chat"].tap()
        } else if app.staticTexts["Chat"].exists {
            app.staticTexts["Chat"].tap()
        }

        openSettings()
        assertDeveloperRowsExist()
    }

    @MainActor
    func testDeveloperRowsAreVisibleAfterAppRelaunch() throws {
        openSettings()
        assertDeveloperRowsExist()

        app.terminate()
        app.launch()
        dismissOnboardingIfNeeded()

        openSettings()
        assertDeveloperRowsExist()
    }

    @MainActor
    func testDeveloperRowsRemainHittableAfterScroll() throws {
        openSettings()
        assertDeveloperRowsExist()

        app.swipeUp()
        app.swipeDown()

        let identifiers = [
            "settings.developer.runTests",
            "settings.developer.logs",
            "settings.developer.debug",
            "settings.developer.diagnostic"
        ]
        for identifier in identifiers {
            let row = app.staticTexts[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing row: \(identifier)")
            XCTAssertTrue(row.isHittable, "Row is not hittable: \(identifier)")
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func openSettings() {
        if app.buttons["Settings"].waitForExistence(timeout: 4) {
            app.buttons["Settings"].tap()
            return
        }
        if app.staticTexts["Settings"].waitForExistence(timeout: 4) {
            app.staticTexts["Settings"].tap()
            return
        }
        if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 4) {
            app.navigationBars.buttons.firstMatch.tap()
            if app.staticTexts["Settings"].waitForExistence(timeout: 4) {
                app.staticTexts["Settings"].tap()
                return
            }
        }
        XCTFail("Unable to navigate to Settings")
    }

    @MainActor
    private func assertDeveloperRowsExist() {
        XCTAssertTrue(app.staticTexts["settings.developer.runTests"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["settings.developer.logs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["settings.developer.debug"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["settings.developer.diagnostic"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func dismissOnboardingIfNeeded() {
        let skip = app.buttons["Skip for now"]
        if skip.waitForExistence(timeout: 2) {
            skip.tap()
        }
    }
}
