import XCTest

@testable import ParchleyDomain

final class DomainTests: XCTestCase {
  func testPageSelectionRejectsZeroAndDuplicates() {
    XCTAssertThrowsError(try PageSelection(pages: [0]))
    XCTAssertThrowsError(try PageSelection(pages: [2, 2]))
    XCTAssertThrowsError(try PageSelection(pages: [Int(UInt32.max) + 1]))
    XCTAssertNoThrow(try PageSelection(pages: [1, 3]))
  }

  func testRequestRejectsRelativePathsAndAcceptsOnlyFileURLs() {
    XCTAssertThrowsError(
      try JobRequest(
        documentID: DocumentID(), attemptID: AttemptID(),
        stagedInputPath: URL(string: "input.pdf")!,
        outputDirectory: URL(fileURLWithPath: "/tmp/output")))
    XCTAssertThrowsError(
      try JobRequest(
        documentID: DocumentID(), attemptID: AttemptID(),
        stagedInputPath: URL(string: "https://example.com/input.pdf")!,
        outputDirectory: URL(fileURLWithPath: "/tmp/output")))
  }

  func testTerminalSnapshotsAreExplicit() {
    let snapshot = JobSnapshot(attemptID: AttemptID(), revision: 4, state: .completed)
    XCTAssertTrue(snapshot.isTerminal)
  }
}
