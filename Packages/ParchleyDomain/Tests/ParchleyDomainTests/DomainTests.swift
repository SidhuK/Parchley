import XCTest
@testable import ParchleyDomain

final class DomainTests: XCTestCase {
    func testPageSelectionRejectsZeroAndDuplicates() {
        XCTAssertThrowsError(try PageSelection(pages: [0]))
        XCTAssertThrowsError(try PageSelection(pages: [2, 2]))
        XCTAssertNoThrow(try PageSelection(pages: [1, 3]))
    }

    func testTerminalSnapshotsAreExplicit() {
        let snapshot = JobSnapshot(attemptID: AttemptID(), revision: 4, state: .completed)
        XCTAssertTrue(snapshot.isTerminal)
    }
}
