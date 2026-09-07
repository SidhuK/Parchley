import XCTest
import CoreGraphics
import AppKit

final class ParchleyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testImportConvertEditAndExport() throws {
        let fixture = try makeFixturePDF()
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["Add PDFs"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let open = app.dialogs["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.typeKey("g", modifierFlags: [.command, .shift])
        let goToFolder = app.sheets.firstMatch
        XCTAssertTrue(goToFolder.waitForExistence(timeout: 3))
        goToFolder.textFields.firstMatch.typeText(fixture.path)
        goToFolder.buttons["Go"].click()
        open.buttons["Open"].click()
        XCTAssertTrue(app.staticTexts["UITest Fixture"].waitForExistence(timeout: 10))
        let convert = app.buttons["Convert"].firstMatch
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        convert.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.click()
        editor.typeText("\nEdited in UI test")
        let export = app.buttons["Export…"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        let save = app.dialogs["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Parchley UI Export.md")
        save.textFields.firstMatch.click()
        save.textFields.firstMatch.typeText(output.lastPathComponent)
        save.buttons["Save"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let contents = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(contents.contains("Edited in UI test"), "Exported Markdown did not contain the editor change")
        try? FileManager.default.removeItem(at: output)
    }

    private func makeFixturePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Parchley UITest Fixture.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw NSError(domain: "ParchleyUITests", code: 1) }
        context.beginPDFPage(nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24)]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "UITest Fixture", attributes: attributes).draw(at: CGPoint(x: 72, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
