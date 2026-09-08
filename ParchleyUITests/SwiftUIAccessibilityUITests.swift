import XCTest

final class SwiftUIAccessibilityUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testDocumentMenuKeepsUnavailableActionsDiscoverable() throws {
    let app = launchApp()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

    app.menuBars.menuItems["File"].click()
    let clearList = app.menuItems["Clear Document List…"]
    XCTAssertTrue(clearList.waitForExistence(timeout: 3))
    XCTAssertFalse(clearList.isEnabled)
    app.typeKey(.escape, modifierFlags: [])

    app.menuBars.menuItems["Document"].click()
    let cancel = app.menuItems["Cancel Conversion"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 3))
    XCTAssertFalse(cancel.isEnabled)
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  func testCommandOOpensPdfImporter() throws {
    let app = launchApp()
    XCTAssertTrue(app.buttons["Add PDFs"].waitForExistence(timeout: 10))

    app.typeKey("o", modifierFlags: [.command])
    let open = app.dialogs["Open"].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }
}
