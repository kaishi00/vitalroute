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
        let beforeRun = DispatchSemaphore(value: 0)
        let continueRun = DispatchSemaphore(value: 0)
        let query = FakeSeriesQuery()
        let task = Task.detached(priority: .userInitiated) {
            beforeRun.signal()
            _ = waitForSignal(continueRun)
            return try await coordinator.run { operation in
                XCTAssertFalse(operation.installQuery(query, stop: { $0.record("stop") }))
                XCTAssertFalse(operation.executeIfActive { $0.record("execute") })
            }
        }

        XCTAssertTrue(waitForSignal(beforeRun))
        task.cancel()
        continueRun.signal()
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
        let queryInstalled = DispatchSemaphore(value: 0)
        let continueStart = DispatchSemaphore(value: 0)
        let query = FakeSeriesQuery()
        let task = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                queryInstalled.signal()
                _ = waitForSignal(continueStart)
                XCTAssertFalse(operation.executeIfActive { $0.record("execute") })
            }
        }

        XCTAssertTrue(waitForSignal(queryInstalled))
        task.cancel()
        continueStart.signal()
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
        let executing = DispatchSemaphore(value: 0)
        let returnFromExecute = DispatchSemaphore(value: 0)
        let query = FakeSeriesQuery()
        let task = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(query, stop: { $0.record("stop") }))
                XCTAssertTrue(operation.executeIfActive { activeQuery in
                    activeQuery.record("execute-start")
                    executing.signal()
                    _ = waitForSignal(returnFromExecute)
                    activeQuery.record("execute-return")
                })
            }
        }

        XCTAssertTrue(waitForSignal(executing))
        task.cancel()
        XCTAssertEqual(query.events, ["execute-start"], "stop must wait while execute is on the stack")
        returnFromExecute.signal()
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
        let resultTask = Task.detached(priority: .userInitiated) {
            try await coordinator.run { operation in
                XCTAssertTrue(operation.installQuery(FakeSeriesQuery(), stop: { $0.record("stop") }))
                XCTAssertTrue(operation.executeIfActive { $0.record("execute") })
            }
        }
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let finishEntered = DispatchSemaphore(value: 0)
        let callbackValues = FakeSeriesQuery()
        let measurementTask = Task.detached(priority: .userInitiated) {
            coordinator.performIfActive {
                callbackEntered.signal()
                _ = waitForSignal(releaseCallback)
                callbackValues.record("measurement")
            }
        }

        XCTAssertTrue(waitForSignal(callbackEntered))
        let finishTask = Task.detached(priority: .userInitiated) {
            finishEntered.signal()
            return coordinator.finish(result: {
                callbackValues.record("done")
                return .success(callbackValues.events.count)
            })
        }
        XCTAssertTrue(waitForSignal(finishEntered))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(callbackValues.events.isEmpty, "Terminal state must wait for an in-flight measurement callback")

        releaseCallback.signal()
        let measurementWasAccepted = await measurementTask.value
        XCTAssertTrue(measurementWasAccepted)
        let didFinish = await finishTask.value
        XCTAssertTrue(didFinish)
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
