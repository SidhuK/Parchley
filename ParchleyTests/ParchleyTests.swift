import Foundation
import XCTest

@testable import Parchley

@MainActor
final class ParchleyTests: XCTestCase {
  func testPreferencesUseDefaultsAndPersistChanges() throws {
    let suiteName = "ParchleyTests.preferences.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.ocrEnabled)
    XCTAssertEqual(preferences.retentionDays, 30)

    preferences.ocrEnabled = false
    preferences.retentionDays = 7

    let reopened = AppPreferences(defaults: defaults)
    XCTAssertFalse(reopened.ocrEnabled)
    XCTAssertEqual(reopened.retentionDays, 7)
  }

  func testPreferencesRepairUnsupportedRetentionValue() throws {
    let suiteName = "ParchleyTests.preferences.invalid.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(-1, forKey: "retentionDays")

    let preferences = AppPreferences(defaults: defaults)

    XCTAssertEqual(preferences.retentionDays, 30)
  }

  func testImportReportsUnavailableWorkspace() {
    let suiteName = "ParchleyTests.workspace.unavailable.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let expectedMessage = "The workspace could not be initialized."
    let dependencies = ParchleyDependencies(
      store: nil,
      coordinator: nil,
      ocrManager: nil,
      ocrManifest: .unavailable,
      preferences: AppPreferences(defaults: defaults),
      initializationMessage: expectedMessage
    )
    let model = ParchleyAppModel(dependencies: dependencies)

    model.importFiles([URL(fileURLWithPath: "/tmp/document.pdf")])

    XCTAssertEqual(model.alertMessage, expectedMessage)
  }

  func testPinnedOCRManifestMatchesTheReleaseMetadata() throws {
    let manifest = try OCRModelCatalog.defaultManifest()

    XCTAssertEqual(manifest.revision, "oar-ocr-v0.7.0")
    XCTAssertEqual(
      manifest.artifacts.map(\.name),
      [
        "pp-ocrv6_small_det.onnx",
        "pp-ocrv6_small_rec.onnx",
        "ppocrv6_dict.txt",
      ]
    )
    XCTAssertTrue(
      manifest.artifacts.allSatisfy { artifact in
        artifact.byteCount > 0 && artifact.sha256.count == 64 && artifact.url.scheme == "https"
      })
  }

  func testUserFacingErrorsExplainHowToRecover() {
    let errors: [DocumentServiceError] = [
      .unsupportedFile,
      .fileTooLarge(42),
      .unavailable,
      .invalidPDF,
      .hashMismatch,
      .cancelled,
      .passwordRequired,
      .modelRequired,
      .unsafeFilename,
      .diskFailure("disk"),
    ]

    for error in errors {
      XCTAssertFalse(error.localizedDescription.isEmpty)
      XCTAssertFalse(error.recoverySuggestion?.isEmpty ?? true)
    }
  }

  func testDependenciesShareTheInjectedDateProvider() {
    let fixedDate = Date(timeIntervalSince1970: 1234)
    let suiteName = "ParchleyTests.dependencies.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let dependencies = ParchleyDependencies(
      store: nil,
      coordinator: nil,
      ocrManager: nil,
      ocrManifest: .unavailable,
      preferences: AppPreferences(defaults: defaults),
      dateProvider: DateProvider { fixedDate }
    )

    XCTAssertEqual(dependencies.dateProvider.now(), fixedDate)
    XCTAssertEqual(dependencies.now(), fixedDate)
  }
}
