import Foundation
import HealthKit

/// Owns the health-change observer lifecycle: transactional registration,
/// ordered teardown, and exactly-once completions.
///
/// Registration is all-or-nothing. `start` unwinds whatever it armed if any
/// step fails, and `start`/`stop` are serialized, so a teardown can never
/// interleave with a registration — which is what previously allowed a
/// cancelled registration to install observers after sync had been turned
/// off, or a stale unwind to tear down a newer registration.
@MainActor
final class HealthObserverCoordinator {
    /// How long a triggered capture may hold HealthKit's completion handler
    /// before it is released anyway. HealthKit expects the handler to be
    /// called promptly; the capture after a notification is bounded, and if
    /// it cannot finish inside this window the completion is released and the
    /// next pass resumes from the persisted checkpoint. Nothing is lost by
    /// answering late — only the notification is.
    nonisolated static let defaultCompletionDeadline: TimeInterval = 25

    private struct Registration {
        var handles: [any HealthObserverHandle]
        var deliveryArmed: Bool
    }

    private let backend: any HealthObserverBackend
    private let completionDeadline: TimeInterval

    /// Bumped by every start and stop. An operation whose generation is no
    /// longer current stops touching the backend.
    private var generation = 0
    private var registration: Registration?

    /// Serializes registrations and teardowns.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        backend: any HealthObserverBackend,
        completionDeadline: TimeInterval = HealthObserverCoordinator.defaultCompletionDeadline
    ) {
        self.backend = backend
        self.completionDeadline = completionDeadline
    }

    /// True while a registration is installed.
    var isObserving: Bool {
        registration != nil
    }

    /// Registers observers for `sampleTypes`, replacing any previous
    /// registration. Throws without leaving partial state behind.
    func start(
        for sampleTypes: [HKSampleType],
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws {
        guard !sampleTypes.isEmpty else {
            throw HealthKitServiceError.noMetricsRequested
        }
        // Claimed before queueing so operations take effect in request
        // order: a stop requested after this start invalidates it, however
        // the two are scheduled.
        let claimed = claimGeneration()
        await acquire()
        defer { release() }

        // Queued behind a stop or a newer registration.
        try ensureCurrent(claimed)
        await unwindCurrentRegistration()

        let deadline = completionDeadline
        var armed: [any HealthObserverHandle] = []
        var deliveryArmed = false
        do {
            for sampleType in sampleTypes {
                try ensureCurrent(claimed)
                try await enableBackgroundDelivery(for: sampleType)
                // Recorded as soon as the first type succeeds: a failure on a
                // later type must not leave background delivery armed with
                // nothing receiving it.
                deliveryArmed = true
            }
            try ensureCurrent(claimed)
            for sampleType in sampleTypes {
                try ensureCurrent(claimed)
                armed.append(backend.startObserver(for: sampleType) { completion in
                    Self.armDeadline(for: completion, after: deadline)
                    handler(completion)
                })
            }
        } catch {
            // This attempt's partial work is unwound here rather than left to
            // the next teardown. The sequence is serialized, so nothing newer
            // can exist to disturb.
            for handle in armed {
                backend.removeObserver(handle)
            }
            if deliveryArmed {
                await disableBackgroundDelivery()
            }
            throw error
        }

        registration = Registration(handles: armed, deliveryArmed: true)
    }

    /// Marks every in-flight registration obsolete without waiting for it.
    ///
    /// A registration that is still being established unwinds what it armed
    /// and fails rather than installing observers — the guarantee that a
    /// registration suspended mid-flight cannot arm observation after the
    /// app has decided to stop, or after a newer configuration took over.
    /// An already-installed registration is untouched; removing that is
    /// `stop()`.
    func invalidateInFlightRegistration() {
        _ = claimGeneration()
    }

    /// Removes the current registration, including its background delivery,
    /// and invalidates any registration that is still being established.
    func stop() async {
        invalidateInFlightRegistration()
        await acquire()
        defer { release() }
        await unwindCurrentRegistration()
    }

    // MARK: - Internals

    private func claimGeneration() -> Int {
        generation += 1
        return generation
    }

    private func isCurrent(_ claimed: Int) -> Bool {
        claimed == generation
    }

    private func ensureCurrent(_ claimed: Int) throws {
        guard isCurrent(claimed) else {
            throw HealthKitServiceError.registrationSuperseded
        }
    }

    private func unwindCurrentRegistration() async {
        guard let current = registration else { return }
        registration = nil
        for handle in current.handles {
            backend.removeObserver(handle)
        }
        if current.deliveryArmed {
            await disableBackgroundDelivery()
        }
    }

    private func enableBackgroundDelivery(for sampleType: HKSampleType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backend.enableBackgroundDelivery(for: sampleType) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.authorizationFailed)
                }
            }
        }
    }

    private func disableBackgroundDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backend.disableAllBackgroundDelivery { continuation.resume() }
        }
    }

    /// Held only until the capture that the notification triggered is
    /// durable, and never past the deadline: HealthKit must not be left
    /// waiting on a notification forever, whatever the engine is doing.
    private nonisolated static func armDeadline(
        for completion: ObserverCompletion,
        after deadline: TimeInterval
    ) {
        Task {
            let nanoseconds = UInt64(max(deadline, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            completion.complete()
        }
    }

    // MARK: - Serialization

    /// A registration and a teardown must not interleave: the backend has a
    /// single global delivery switch, so a stale unwind running inside a
    /// newer registration would silently disarm it.
    private func acquire() async {
        while isBusy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        // Every waiter is resumed and re-checks the flag; the first one
        // through takes over and the rest queue again.
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
