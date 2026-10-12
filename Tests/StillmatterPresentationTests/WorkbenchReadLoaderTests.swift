import XCTest
@testable import StillmatterPresentation

final class WorkbenchReadLoaderTests: XCTestCase {
    func testNewWorkspaceResultWinsEvenWhenOldReadFinishesLater() {
        let started = expectation(description: "old read started")
        let delivered = expectation(description: "new workspace delivered")
        let gate = DispatchSemaphore(value: 0)
        var results: [String] = []
        let loader = WorkbenchReadLoader<String>(label: "test.workbench.serial") { value in
            results.append(value)
            delivered.fulfill()
        }
        loader.reload {
            started.fulfill()
            gate.wait()
            return "old workspace"
        }
        wait(for: [started], timeout: 2)
        loader.reload { "new workspace" }
        gate.signal()
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(results, ["new workspace"])
        loader.stop()
    }

    func testDisposalSilencesPendingDelivery() {
        let started = expectation(description: "read started")
        let finished = expectation(description: "read finished")
        let gate = DispatchSemaphore(value: 0)
        var delivered = 0
        let loader = WorkbenchReadLoader<Int>(label: "test.workbench.stop") { _ in delivered += 1 }
        loader.reload {
            started.fulfill()
            gate.wait()
            finished.fulfill()
            return 1
        }
        wait(for: [started], timeout: 2)
        loader.stop()
        gate.signal()
        wait(for: [finished], timeout: 2)
        let drain = expectation(description: "main delivery drained")
        DispatchQueue.main.async { drain.fulfill() }
        wait(for: [drain], timeout: 2)
        XCTAssertEqual(delivered, 0)
    }
}
