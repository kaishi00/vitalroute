import XCTest
import HealthKit
@testable import VitalRoute

/// Observer-lifecycle tests against a controllable HealthKit adapter: a
/// partial enablement failure, a registration suspended mid-flight, and a
/// callback delivered after removal are all real hazards that the live store
/// cannot be made to reproduce on demand.
@MainActor
final class HealthObserverCoordinatorTests: XCTestCase {
    private var steps: HKSampleType!
    private var sleep: HKSampleType!

    override func setUp() async throws {
        steps = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        sleep = try XCTUnwrap(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Registration

    func testRegistrationArmsDeliveryAndReplacesThePreviousObservers() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend)

        try await coordinator.start(for: [steps, sleep]) { _ in }

        XCTAssertTrue(coordinator.isObserving)
        XCTAssertEqual(backend.enableCalls, [steps, sleep])
        XCTAssertEqual(backend.registeredTypes, [steps, sleep])
        XCTAssertTrue(backend.deliveryArmed)

        // Replacing the set unwinds the previous delivery first and re-arms
        // it for the new set.
        try await coordinator.start(for: [steps]) { _ in }

        XCTAssertEqual(backend.registeredTypes, [steps])
        XCTAssertEqual(backend.disableAllCalls, 1)
        XCTAssertTrue(backend.deliveryArmed)
        XCTAssertEqual(backend.enableCalls, [steps, sleep, steps])
    }

    func testPartialEnablementFailureUnwindsEverythingItArmed() async throws {
        let backend = ControllableObserverBackend()
        backend.failEnablement(for: sleep, with: HealthKitServiceError.authorizationFailed)
        let coordinator = HealthObserverCoordinator(backend: backend)

        do {
            try await coordinator.start(for: [steps, sleep]) { _ in }
            XCTFail("expected the registration to fail")
        } catch let error as HealthKitServiceError {
            XCTAssertEqual(error, .authorizationFailed)
        }

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertTrue(backend.registeredTypes.isEmpty, "no observer may outlive a failed registration")
        XCTAssertEqual(backend.disableAllCalls, 1,
                       "delivery armed for the first type must be unwound, not left running")
        XCTAssertFalse(backend.deliveryArmed)
    }

    func testEnablementRejectedWithoutErrorAlsoUnwinds() async throws {
        let backend = ControllableObserverBackend()
        backend.rejectEnablement(for: steps)
        let coordinator = HealthObserverCoordinator(backend: backend)

        do {
            try await coordinator.start(for: [steps]) { _ in }
            XCTFail("expected the registration to fail")
        } catch let error as HealthKitServiceError {
            XCTAssertEqual(error, .authorizationFailed)
        }

        XCTAssertTrue(backend.registeredTypes.isEmpty)
        XCTAssertFalse(backend.deliveryArmed)
    }

    func testSuspendedRegistrationIsUnwoundWhenItResumesAfterStop() async throws {
        let backend = ControllableObserverBackend()
        backend.parkEnablement(for: sleep)
        let coordinator = HealthObserverCoordinator(backend: backend)

        let starting = Task { try await coordinator.start(for: [steps, sleep]) { _ in } }
        await waitFor("the registration to suspend") { backend.parkedEnablementCount == 1 }

        // Teardown is requested while the registration is still suspended;
        // the second type's enablement then succeeds late.
        coordinator.invalidateInFlightRegistration()
        backend.releaseParkedEnablements()

        do {
            try await starting.value
            XCTFail("a registration that resumed after the stop must not report success")
        } catch let error as HealthKitServiceError {
            XCTAssertEqual(error, .registrationSuperseded)
        }
        await coordinator.stop()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertTrue(backend.registeredTypes.isEmpty,
                      "observers must not be installed after the app stopped observing")
        XCTAssertFalse(backend.deliveryArmed, "and background delivery must not be left armed")
    }

    func testStopRemovesObserversAndDisarmsDelivery() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend)
        try await coordinator.start(for: [steps, sleep]) { _ in }

        await coordinator.stop()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertTrue(backend.registeredTypes.isEmpty)
        XCTAssertFalse(backend.deliveryArmed)
        XCTAssertEqual(backend.disableAllCalls, 1)

        // Teardown is idempotent: a second stop changes nothing.
        await coordinator.stop()
        XCTAssertEqual(backend.disableAllCalls, 1)
    }

    func testRegistrationAfterStopIsLive() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend)
        try await coordinator.start(for: [steps]) { _ in }
        await coordinator.stop()

        try await coordinator.start(for: [sleep]) { _ in }

        XCTAssertTrue(coordinator.isObserving)
        XCTAssertEqual(backend.registeredTypes, [sleep])
        XCTAssertTrue(backend.deliveryArmed)
    }

    // MARK: Completions

    func testCallbackHandsTheAppAnExactlyOnceCompletion() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend)
        try await coordinator.start(for: [steps]) { _ in }

        let fired = try XCTUnwrap(backend.fireObserver(for: steps))
        XCTAssertFalse(fired.completion.hasBeenReleased)

        fired.completion.complete()
        XCTAssertEqual(fired.releases.count, 1, "releasing answers HealthKit once")

        // HealthKit's completion handler must not be called twice, whatever
        // the engine does afterwards.
        fired.completion.complete()
        XCTAssertEqual(fired.releases.count, 1)
    }

    func testDeadlineAnswersANotificationTheAppNeverReleases() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend, completionDeadline: 0.05)
        // A handler that never answers: the app is stuck somewhere the
        // capture contract could not bound on its own.
        try await coordinator.start(for: [steps]) { _ in }

        let fired = try XCTUnwrap(backend.fireObserver(for: steps))
        XCTAssertEqual(fired.releases.count, 0)

        await waitFor("the deadline to answer the notification") { fired.releases.count == 1 }

        // Exactly once: the deadline does not answer again, and neither does
        // a later engine release.
        try await Task.sleep(nanoseconds: 200_000_000)
        fired.completion.complete()
        XCTAssertEqual(fired.releases.count, 1)
    }

    func testLateCallbackAfterStopIsStillAnswered() async throws {
        let backend = ControllableObserverBackend()
        let coordinator = HealthObserverCoordinator(backend: backend, completionDeadline: 0.05)
        try await coordinator.start(for: [steps]) { _ in }
        await coordinator.stop()

        // HealthKit had already scheduled this callback when the observer was
        // removed. The app must still answer it rather than leave the system
        // waiting on a notification nobody owns.
        let fired = try XCTUnwrap(backend.fireLateObserver(for: steps))
        await waitFor("the deadline to answer the late callback") { fired.releases.count == 1 }
        XCTAssertEqual(fired.releases.count, 1)
    }
}

// MARK: - Test doubles

/// Counts releases of a HealthKit completion.
private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Controllable HealthKit stand-in for the observer lifecycle: enablement can
/// fail for a chosen type, a completion can be parked, observers can be fired
/// on demand, and a handler is retained after removal so a callback that was
/// already scheduled can still be delivered.
private final class ControllableObserverBackend: HealthObserverBackend, @unchecked Sendable {
    private final class Handle: HealthObserverHandle {
        let sampleType: HKSampleType
        let handler: @Sendable (ObserverCompletion) -> Void

        init(sampleType: HKSampleType, handler: @escaping @Sendable (ObserverCompletion) -> Void) {
            self.sampleType = sampleType
            self.handler = handler
        }
    }

    struct FiredNotification {
        let completion: ObserverCompletion
        let releases: ReleaseCounter
    }

    private let lock = NSLock()
    private var handles: [Handle] = []
    /// Retained after removal so a late callback can be delivered.
    private var knownHandlers: [HKSampleType: @Sendable (ObserverCompletion) -> Void] = [:]
    private var enableErrors: [HKSampleType: Error] = [:]
    private var rejectedTypes: Set<HKSampleType> = []
    private var parkedTypes: Set<HKSampleType> = []
    private var parkedCompletions: [(Bool, Error?) -> Void] = []
    private var enableCallList: [HKSampleType] = []
    private var disableAllCallCount = 0
    private var isDeliveryArmed = false

    var enableCalls: [HKSampleType] {
        lock.lock()
        defer { lock.unlock() }
        return enableCallList
    }

    var disableAllCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return disableAllCallCount
    }

    var deliveryArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDeliveryArmed
    }

    var registeredTypes: [HKSampleType] {
        lock.lock()
        defer { lock.unlock() }
        return handles.map(\.sampleType)
    }

    var parkedEnablementCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedCompletions.count
    }

    func failEnablement(for sampleType: HKSampleType, with error: Error) {
        lock.lock()
        enableErrors[sampleType] = error
        lock.unlock()
    }

    /// Reports `(false, nil)`: the request was refused without an error,
    /// which must not be read as success.
    func rejectEnablement(for sampleType: HKSampleType) {
        lock.lock()
        rejectedTypes.insert(sampleType)
        lock.unlock()
    }

    func parkEnablement(for sampleType: HKSampleType) {
        lock.lock()
        parkedTypes.insert(sampleType)
        lock.unlock()
    }

    /// Completes every parked enablement successfully — the "late success"
    /// that an invalidated registration must not act on.
    func releaseParkedEnablements() {
        lock.lock()
        let pending = parkedCompletions
        parkedCompletions.removeAll()
        parkedTypes.removeAll()
        isDeliveryArmed = true
        lock.unlock()
        for completion in pending {
            completion(true, nil)
        }
    }

    // MARK: HealthObserverBackend

    func enableBackgroundDelivery(
        for sampleType: HKSampleType,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        lock.lock()
        enableCallList.append(sampleType)
        let error = enableErrors[sampleType]
        let isRejected = rejectedTypes.contains(sampleType)
        let isParked = parkedTypes.contains(sampleType)
        if isParked {
            parkedCompletions.append(completion)
        }
        if !isParked && error == nil && !isRejected {
            isDeliveryArmed = true
        }
        lock.unlock()

        guard !isParked else { return }
        if let error {
            completion(false, error)
        } else if isRejected {
            completion(false, nil)
        } else {
            completion(true, nil)
        }
    }

    func startObserver(
        for sampleType: HKSampleType,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) -> any HealthObserverHandle {
        let handle = Handle(sampleType: sampleType, handler: handler)
        lock.lock()
        handles.append(handle)
        knownHandlers[sampleType] = handler
        lock.unlock()
        return handle
    }

    func removeObserver(_ handle: any HealthObserverHandle) {
        lock.lock()
        handles.removeAll { existing in existing === (handle as? Handle) }
        lock.unlock()
    }

    func disableAllBackgroundDelivery(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        disableAllCallCount += 1
        isDeliveryArmed = false
        lock.unlock()
        completion()
    }

    // MARK: Firing callbacks

    /// Fires the callback for a live observer, the way HealthKit would.
    func fireObserver(for sampleType: HKSampleType) -> FiredNotification? {
        lock.lock()
        let handler = handles.first { $0.sampleType == sampleType }?.handler
        lock.unlock()
        return fire(handler)
    }

    /// Fires a callback for a removed observer — one HealthKit had already
    /// scheduled when the observer was stopped.
    func fireLateObserver(for sampleType: HKSampleType) -> FiredNotification? {
        lock.lock()
        let handler = knownHandlers[sampleType]
        lock.unlock()
        return fire(handler)
    }

    private func fire(_ handler: (@Sendable (ObserverCompletion) -> Void)?) -> FiredNotification? {
        guard let handler else { return nil }
        let releases = ReleaseCounter()
        let completion = ObserverCompletion { releases.increment() }
        handler(completion)
        return FiredNotification(completion: completion, releases: releases)
    }
}
