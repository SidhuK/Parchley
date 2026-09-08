import XCTest

final class ParchleyUITestsLaunchTests: XCTestCase {
  override class var runsForEachTargetApplicationUIConfiguration: Bool {
    true
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testCleanLaunch() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Add PDFs"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["More"].exists)
    XCTAssertTrue(app.staticTexts["Parchley"].exists)
    XCTAssertFalse(app.staticTexts["Unable to complete action"].exists)

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Clean launch"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
