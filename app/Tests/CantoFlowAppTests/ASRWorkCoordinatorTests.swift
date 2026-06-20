import XCTest
@testable import CantoFlowApp

final class ASRWorkCoordinatorTests: XCTestCase {

    func testAcquireWhenFree() {
        let c = ASRWorkCoordinator()
        XCTAssertTrue(c.tryAcquire(.pushToTalk))
        XCTAssertTrue(c.isBusy)
        XCTAssertTrue(c.isPushToTalkActive)
        XCTAssertFalse(c.isFileBatchActive)
    }

    func testMutualExclusion() {
        let c = ASRWorkCoordinator()
        let batch = UUID()
        XCTAssertTrue(c.tryAcquire(.fileBatch(batch)))
        // PTT cannot acquire while a file batch holds it.
        XCTAssertFalse(c.tryAcquire(.pushToTalk))
        XCTAssertTrue(c.isFileBatchActive)
        XCTAssertFalse(c.isPushToTalkActive)
    }

    func testReentrantSameOwner() {
        let c = ASRWorkCoordinator()
        let batch = UUID()
        XCTAssertTrue(c.tryAcquire(.fileBatch(batch)))
        XCTAssertTrue(c.tryAcquire(.fileBatch(batch)))   // same owner re-acquires
        XCTAssertFalse(c.tryAcquire(.fileBatch(UUID())))  // different batch id is a different owner
    }

    func testReleaseOnlyByOwner() {
        let c = ASRWorkCoordinator()
        XCTAssertTrue(c.tryAcquire(.pushToTalk))
        c.release(.fileBatch(UUID()))     // wrong owner → no-op
        XCTAssertTrue(c.isBusy)
        c.release(.pushToTalk)            // correct owner → frees
        XCTAssertFalse(c.isBusy)
        XCTAssertNil(c.owner)
    }

    func testReacquireAfterRelease() {
        let c = ASRWorkCoordinator()
        XCTAssertTrue(c.tryAcquire(.pushToTalk))
        c.release(.pushToTalk)
        let batch = UUID()
        XCTAssertTrue(c.tryAcquire(.fileBatch(batch)), "engine should be free after release")
    }
}
