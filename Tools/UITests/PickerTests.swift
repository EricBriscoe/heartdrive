import XCTest

final class PickerTests: XCTestCase {
    func testTrainerPickerCanOpenCloseAndReopen() {
        let app = XCUIApplication()
        app.launch()
        let connect = app.navigationBars["HeartDrive"].buttons["Connect trainer"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            connect.tap()
            XCTAssertTrue(app.navigationBars["Connect trainer"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Scanning…"].exists)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Power + Cadence")).firstMatch.exists)
            attachScreenshot(app, name: "trainer-picker")
            app.buttons["Close"].tap()
            XCTAssertTrue(app.navigationBars["HeartDrive"].waitForExistence(timeout: 5))
        }
    }

    func testMonitorPickerReturnsToSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let bluetooth = app.segmentedControls.buttons["Bluetooth"]
        if !bluetooth.isHittable { app.swipeUp() }
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        bluetooth.tap()
        let monitor = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Heart-rate monitor")).firstMatch
        if !monitor.isHittable { app.swipeUp() }
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Connect monitor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scanning…"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "moisten")).firstMatch.exists)
        attachScreenshot(app, name: "monitor-picker")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["HeartDrive"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
