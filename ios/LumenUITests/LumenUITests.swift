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
            let row = developerRow(identifier)
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
            let row = developerRow(identifier)
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing row: \(identifier)")
            XCTAssertTrue(row.isHittable, "Row is not hittable: \(identifier)")
        }
    }

    @MainActor
    func testRunTestsButtonPresentsResultsAlert() throws {
        openSettings()

        let runTests = developerRow("settings.developer.runTests")
        XCTAssertTrue(runTests.waitForExistence(timeout: 3))
        runTests.tap()

        let alert = app.alerts["Run tests"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "checks passed")).firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.exists)
    }

    @MainActor
    func testLogsNavigationOpensLogsScreen() throws {
        openSettings()

        let logs = developerRow("settings.developer.logs")
        XCTAssertTrue(logs.waitForExistence(timeout: 3))
        logs.tap()

        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testDebugNavigationOpensDebugScreen() throws {
        openSettings()

        let debug = developerRow("settings.developer.debug")
        XCTAssertTrue(debug.waitForExistence(timeout: 3))
        debug.tap()

        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testDiagnosticNavigationOpensDiagnosticScreen() throws {
        openSettings()

        let diagnostic = developerRow("settings.developer.diagnostic")
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        diagnostic.tap()

        XCTAssertTrue(app.navigationBars["Diagnostic"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testDeveloperFeaturesEndToEndFlow() throws {
        openSettings()

        let runTests = developerRow("settings.developer.runTests")
        XCTAssertTrue(runTests.waitForExistence(timeout: 3))
        runTests.tap()

        let runTestsAlert = app.alerts["Run tests"]
        XCTAssertTrue(runTestsAlert.waitForExistence(timeout: 4))
        XCTAssertTrue(runTestsAlert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "checks passed")).firstMatch.exists)
        runTestsAlert.buttons["OK"].tap()

        let logs = developerRow("settings.developer.logs")
        XCTAssertTrue(logs.waitForExistence(timeout: 3))
        logs.tap()
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 4))
        goBackIfNeeded()

        let debug = developerRow("settings.developer.debug")
        XCTAssertTrue(debug.waitForExistence(timeout: 3))
        debug.tap()
        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 4))
        goBackIfNeeded()

        let diagnostic = developerRow("settings.developer.diagnostic")
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        diagnostic.tap()
        XCTAssertTrue(app.navigationBars["Diagnostic"].waitForExistence(timeout: 4))
        goBackIfNeeded()

        assertDeveloperRowsExist()
    }

    @MainActor
    func testDeveloperFeaturesEndToEndAfterRelaunch() throws {
        openSettings()
        assertDeveloperRowsExist()

        app.terminate()
        app.launch()
        dismissOnboardingIfNeeded()
        openSettings()

        let runTests = developerRow("settings.developer.runTests")
        XCTAssertTrue(runTests.waitForExistence(timeout: 3))
        runTests.tap()
        let runTestsAlert = app.alerts["Run tests"]
        XCTAssertTrue(runTestsAlert.waitForExistence(timeout: 4))
        runTestsAlert.buttons["OK"].tap()

        let logs = developerRow("settings.developer.logs")
        XCTAssertTrue(logs.waitForExistence(timeout: 3))
        logs.tap()
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 4))
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
        XCTAssertTrue(developerRow("settings.developer.runTests").waitForExistence(timeout: 3))
        XCTAssertTrue(developerRow("settings.developer.logs").waitForExistence(timeout: 3))
        XCTAssertTrue(developerRow("settings.developer.debug").waitForExistence(timeout: 3))
        XCTAssertTrue(developerRow("settings.developer.diagnostic").waitForExistence(timeout: 3))
    }

    @MainActor
    private func developerRow(_ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists {
            return element
        }

        let button = app.buttons[identifier]
        if button.exists {
            return button
        }

        return app.staticTexts[identifier]
    }

    @MainActor
    private func goBackIfNeeded() {
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 2) {
            back.tap()
        }
    }

    @MainActor
    private func dismissOnboardingIfNeeded() {
        let skip = app.buttons["Skip for now"]
        if skip.waitForExistence(timeout: 2) {
            skip.tap()
        }
    }
}
