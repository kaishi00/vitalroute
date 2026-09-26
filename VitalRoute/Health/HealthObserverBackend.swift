import Foundation
import HealthKit

/// Handle for one registered sample-type observer.
protocol HealthObserverHandle: AnyObject {}

/// The HealthKit surface the observer lifecycle needs.
///
/// Kept as a port (the production conformance below is `HKHealthStore`) so
/// the registration and teardown state machine can be exercised against a
/// controllable adapter: a partial enablement failure, a registration
/// suspended mid-flight, and a late callback are all real hazards that a
/// test cannot reproduce through the live store.
protocol HealthObserverBackend: AnyObject {
    /// Arms background delivery for one sample type.
    func enableBackgroundDelivery(
        for sampleType: HKSampleType,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    )

    /// Registers an observer. `handler` runs on a HealthKit queue and
    /// receives an exactly-once completion to release when the work it
    /// triggered is durable.
    func startObserver(
        for sampleType: HKSampleType,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) -> any HealthObserverHandle

    func removeObserver(_ handle: any HealthObserverHandle)

    /// HealthKit offers no per-type disable, so teardown is all-or-nothing.
    func disableAllBackgroundDelivery(completion: @escaping @Sendable () -> Void)
}

extension HKHealthStore: HealthObserverBackend {
    func enableBackgroundDelivery(
        for sampleType: HKSampleType,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        enableBackgroundDelivery(for: sampleType, frequency: .immediate, withCompletion: completion)
    }

    func startObserver(
        for sampleType: HKSampleType,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) -> any HealthObserverHandle {
        let handle = HKObserverHandle()
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, _ in
            handler(ObserverCompletion(completionHandler))
        }
        handle.query = query
        execute(query)
        return handle
    }

    func removeObserver(_ handle: any HealthObserverHandle) {
        guard let handle = handle as? HKObserverHandle, let query = handle.query else { return }
        stop(query)
    }

    func disableAllBackgroundDelivery(completion: @escaping @Sendable () -> Void) {
        disableAllBackgroundDelivery { _, _ in completion() }
    }
}

/// Wraps the query so it can be stopped later; the observer callback closure
/// cannot capture the query it is being constructed into.
private final class HKObserverHandle: HealthObserverHandle {
    var query: HKObserverQuery?
}
