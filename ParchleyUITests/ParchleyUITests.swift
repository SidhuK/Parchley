import AppKit
import CoreGraphics
import XCTest

final class ParchleyUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunchExposesAccessibleDocumentControls() throws {
    let app = launchApp()

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let add = app.buttons["Add PDFs"].firstMatch
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    XCTAssertEqual(add.label, "Add PDFs")
    XCTAssertTrue(app.buttons["More"].exists)
    XCTAssertTrue(app.staticTexts["Parchley"].exists)
  }

  @MainActor
  func testImportConvertEditAndExport() throws {
    let fixture = try makeFixturePDF()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("Parchley UI Export \(UUID().uuidString).md")
    defer {
      try? FileManager.default.removeItem(at: fixture)
      try? FileManager.default.removeItem(at: output)
    }

    let app = launchApp()
    chooseFile(fixture, in: app, using: "Open")

    let document = app.staticTexts["UITest Fixture"].firstMatch
    XCTAssertTrue(document.waitForExistence(timeout: 10))
    XCTAssertEqual(document.label, "UITest Fixture")

    let editor = app.textViews["Markdown source editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 20))
    editor.click()
    editor.typeText("\nEdited in UI test")

    let export = app.buttons["Export…"].firstMatch
    XCTAssertTrue(export.waitForExistence(timeout: 5))
    export.click()
    let save = app.dialogs["Save"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    goToFolder(output.deletingLastPathComponent(), in: app, dialog: save)
    save.textFields.firstMatch.click()
    save.textFields.firstMatch.typeText(output.lastPathComponent)
    save.buttons["Save"].click()

    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let contents = try String(contentsOf: output, encoding: .utf8)
    XCTAssertTrue(contents.contains("Edited in UI test"))
  }

  @MainActor
  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  @MainActor
  private func chooseFile(_ file: URL, in app: XCUIApplication, using dialogName: String) {
    let add = app.buttons["Add PDFs"].firstMatch
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.click()

    let open = app.dialogs[dialogName].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    goToFolder(file, in: app, dialog: open)
    open.buttons["Open"].click()
  }

  @MainActor
  private func goToFolder(_ url: URL, in app: XCUIApplication, dialog: XCUIElement) {
    dialog.typeKey("g", modifierFlags: [.command, .shift])
    let goToFolder = app.sheets.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 3))
    goToFolder.textFields.firstMatch.typeText(url.path)
    goToFolder.buttons["Go"].click()
  }

  private func makeFixturePDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Parchley UITest Fixture \(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
      throw NSError(domain: "ParchleyUITests", code: 1)
    }
    context.beginPDFPage(nil)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 24)
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSAttributedString(string: "UITest Fixture", attributes: attributes)
      .draw(at: CGPoint(x: 72, y: 700))
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    return url
  }
}
