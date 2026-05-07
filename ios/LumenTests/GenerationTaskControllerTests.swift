import XCTest
@testable import Lumen

@MainActor
final class GenerationTaskControllerTests: XCTestCase {
    func testStartupGuardRunsOnlyOncePerKey() {
        let controller = GenerationTaskController<String>()
        var count = 0

        controller.startupIfNeeded(for: "chat") { count += 1 }
        controller.startupIfNeeded(for: "chat") { count += 1 }

        XCTAssertEqual(count, 1)
    }

    func testBeginCancelsPreviousAndPreventsStaleRequest() async {
        let controller = GenerationTaskController<String>()
        let firstTask = Task<Void, Never> { await Task.yield() }
        let first = controller.begin(for: "chat", task: firstTask)
        let secondTask = Task<Void, Never> { await Task.yield() }
        let second = controller.begin(for: "chat", task: secondTask)

        XCTAssertFalse(controller.isCurrent(first, for: "chat"))
        XCTAssertTrue(controller.isCurrent(second, for: "chat"))
        XCTAssertTrue(firstTask.isCancelled)
    }

    func testCancelClearsActiveRequest() {
        let controller = GenerationTaskController<String>()
        let task = Task<Void, Never> { await Task.yield() }
        let requestID = controller.begin(for: "voice", task: task)

        controller.cancel(for: "voice")

        XCTAssertFalse(controller.isCurrent(requestID, for: "voice"))
        XCTAssertTrue(task.isCancelled)
    }
}
