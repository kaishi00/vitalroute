import Foundation

/// Exactly-once release for one HealthKit observer completion.
///
/// HealthKit's update handler must call the completion handler it is given:
/// never calling it stops delivery being credited to the app, and calling it
/// twice is a misuse of the system's contract. Every release path — the
/// durable-capture boundary, a failure, a cancellation, or the deadline —
/// goes through this token, so the first one wins and the rest are no-ops.
final class ObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let release: () -> Void
    private var isReleased = false

    init(_ release: @escaping () -> Void) {
        self.release = release
    }

    var hasBeenReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }

    func complete() {
        lock.lock()
        if isReleased {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        release()
    }
}
