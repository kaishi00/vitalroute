import XCTest
@testable import VitalRoute

final class HealthKitServiceTests: XCTestCase {
    func testAuthorizationErrorMappingPassesUnderlyingErrorThrough() {
        let underlying = NSError(domain: "com.apple.healthkit", code: 42)

        let mapped = HealthKitServiceError.authorizationError(granted: false, error: underlying)

        XCTAssertEqual(mapped as NSError?, underlying as NSError?)
    }

    func testAuthorizationErrorMappingThrowsWhenNotGrantedWithoutError() {
        let mapped = HealthKitServiceError.authorizationError(granted: false, error: nil)

        XCTAssertEqual(mapped as? HealthKitServiceError, .authorizationFailed)
        XCTAssertNotNil((mapped as? LocalizedError)?.errorDescription)
    }

    func testAuthorizationErrorMappingReturnsNilWhenGranted() {
        XCTAssertNil(HealthKitServiceError.authorizationError(granted: true, error: nil))
    }
    func testSeriesQueryCoordinatorCompletesOnceAndStopsAfterSuccess() async throws {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        var query: FakeSeriesQuery? = FakeSeriesQuery()
        weak let weakQuery = query

        let result = try await coordinator.run { operation in
            operation.scheduleTimeout(after: 30_000_000_000)
            XCTAssertTrue(operation.installQuery(query!, stop: { $0.record("stop") }))
            XCTAssertTrue(operation.executeIfActive { $0.record("execute") })
            XCTAssertTrue(operation.finish(.success("done")))
            XCTAssertFalse(operation.finish(.failure(CancellationError())))
        }

        XCTAssertEqual(result, "done")
        XCTAssertEqual(query?.events, ["execute", "stop"])
        XCTAssertFalse(coordinator.performIfActive { XCTFail("Late callbacks must be ignored") })
        query = nil
        XCTAssertNil(weakQuery, "Terminal completion must release the retained query")
    }

    func testSeriesQueryCoordinatorPropagatesFirstErrorAndStopsOnce() async {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        let query = FakeSeriesQuery()
        let expected = NSError(domain: "ECG-test", code: 17)

        do {
            _ = try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                XCTAssertTrue(operation.executeIfActive { $0.record("execute") })
                XCTAssertTrue(operation.finish(.failure(expected)))
                XCTAssertFalse(operation.finish(.success("late done")))
            }
            XCTFail("The first query error should be propagated")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, expected.domain)
            XCTAssertEqual(error.code, expected.code)
        } catch {
            XCTFail("Unexpected ECG query error: \(error)")
        }
        XCTAssertEqual(query.events, ["execute", "stop"])
    }

    func testSeriesQueryCoordinatorDeadlineFailsOnceAndStopsQuery() async {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        let query = FakeSeriesQuery()

        do {
            _ = try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                XCTAssertTrue(operation.executeIfActive { $0.record("execute") })
                operation.scheduleTimeout(after: 20_000_000)
            }
            XCTFail("A query that never sends a terminal callback must time out")
        } catch let error as HealthKitServiceError {
            XCTAssertEqual(error, .seriesQueryTimedOut)
            XCTAssertEqual(error.errorDescription, "Apple Health did not finish reading the ECG series in time.")
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }
        XCTAssertEqual(query.events, ["execute", "stop"])
    }

    func testSeriesQueryCoordinatorCancellationBeforeQueryInstallDoesNotStartQuery() async {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        let gate = AsyncTestGate()
        let query = FakeSeriesQuery()
        let task = Task.detached(priority: .userInitiated) {
            await gate.wait()
            return try await coordinator.run { operation in
                XCTAssertFalse(operation.installQuery(query, stop: { $0.record("stop") }))
                XCTAssertFalse(operation.executeIfActive { $0.record("execute") })
            }
        }

        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancellation before query setup should fail the operation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertTrue(query.events.isEmpty)
    }

    func testSeriesQueryCoordinatorCancellationAfterInstallPreventsExecute() async {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        let queryInstalled = expectation(description: "query installed")
        let operationBox = LockedValue<SeriesQueryCoordinator<String, FakeSeriesQuery>>()
        let query = FakeSeriesQuery()
        let task = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                operationBox.set(operation)
                queryInstalled.fulfill()
            }
        }

        await fulfillment(of: [queryInstalled], timeout: 2)
        task.cancel()
        guard let operation = operationBox.value else {
            XCTFail("The query operation should be published after installation")
            return
        }
        XCTAssertFalse(operation.executeIfActive { $0.record("execute") })
        do {
            _ = try await task.value
            XCTFail("Cancellation must prevent starting an unsubmitted query")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertTrue(query.events.isEmpty, "An unstarted query must be released without stop or execute")
    }

    func testSeriesQueryCoordinatorDefersStopUntilExecuteReturns() async {
        let coordinator = SeriesQueryCoordinator<String, FakeSeriesQuery>()
        let queryInstalled = expectation(description: "query installed")
        let executing = expectation(description: "execute entered")
        let executeReturned = expectation(description: "execute returned")
        let returnFromExecute = DispatchSemaphore(value: 0)
        let query = FakeSeriesQuery()
        let operationBox = LockedValue<SeriesQueryCoordinator<String, FakeSeriesQuery>>()
        let task = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                operationBox.set(operation)
                queryInstalled.fulfill()
            }
        }

        await fulfillment(of: [queryInstalled], timeout: 2)
        guard let operation = operationBox.value else {
            XCTFail("The query operation should be published after installation")
            task.cancel()
            return
        }
        DispatchQueue(label: "SeriesQueryCoordinatorTests.execute").async {
            _ = operation.executeIfActive { activeQuery in
                activeQuery.record("execute-start")
                executing.fulfill()
                _ = waitForSignal(returnFromExecute)
                activeQuery.record("execute-return")
            }
            executeReturned.fulfill()
        }
        await fulfillment(of: [executing], timeout: 2)
        task.cancel()
        XCTAssertEqual(query.events, ["execute-start"], "stop must wait while execute is on the stack")
        returnFromExecute.signal()
        await fulfillment(of: [executeReturned], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("Cancellation during execute should fail the operation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertEqual(query.events, ["execute-start", "execute-return", "stop"])
    }

    func testSeriesQueryCoordinatorSerializesMeasurementWithTerminalCallback() async throws {
        let coordinator = SeriesQueryCoordinator<Int, FakeSeriesQuery>()
        let queryReady = expectation(description: "query installed and executed")
        let resultTask = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                operation.scheduleTimeout(after: 10_000_000_000)
                XCTAssertTrue(operation.installQuery(FakeSeriesQuery(), stop: { $0.record("stop") }))
                XCTAssertTrue(operation.executeIfActive { $0.record("execute") })
                queryReady.fulfill()
            }
        }
        let callbackEntered = expectation(description: "measurement entered")
        let releaseCallback = DispatchSemaphore(value: 0)
        let measurementFinished = expectation(description: "measurement finished")
        let finishFinished = expectation(description: "terminal callback finished")
        let finishStarted = expectation(description: "terminal callback started")
        let callbackValues = FakeSeriesQuery()
        let measurementResult = LockedValue<Bool>()
        await fulfillment(of: [queryReady], timeout: 2)
        DispatchQueue(label: "SeriesQueryCoordinatorTests.measurement").async {
            let accepted = coordinator.performIfActive {
                callbackEntered.fulfill()
                _ = waitForSignal(releaseCallback)
                callbackValues.record("measurement")
            }
            measurementResult.set(accepted)
            measurementFinished.fulfill()
        }

        await fulfillment(of: [callbackEntered], timeout: 2)
        let finishResult = LockedValue<Bool>()
        DispatchQueue(label: "SeriesQueryCoordinatorTests.terminal").async {
            finishStarted.fulfill()
            let completed = coordinator.finish(result: {
                callbackValues.record("done")
                return .success(callbackValues.events.count)
            })
            finishResult.set(completed)
            finishFinished.fulfill()
        }
        await fulfillment(of: [finishStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(callbackValues.events.isEmpty, "Terminal state must wait for an in-flight measurement callback")

        releaseCallback.signal()
        await fulfillment(of: [measurementFinished, finishFinished], timeout: 2)
        XCTAssertEqual(measurementResult.value, true)
        XCTAssertEqual(finishResult.value, true)
        let finalResult = try await resultTask.value
        XCTAssertEqual(finalResult, 2)
        XCTAssertEqual(callbackValues.events, ["measurement", "done"])
        XCTAssertFalse(coordinator.performIfActive { callbackValues.record("late measurement") })
        XCTAssertEqual(callbackValues.events, ["measurement", "done"])
    }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValue = value
    }
}

private final class FakeSeriesQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append(event)
    }
}
