import Foundation

/// The single serialization boundary for all synchronization work. The
/// manual coordinator and the automatic engine acquire it, so manual and
/// background work can never run concurrently, race checkpoints, or
/// duplicate active delivery work.
actor SyncWorkGate {
    /// A waiter that can be resumed exactly once, even if the waiting task
    /// was cancelled in between — belt and braces against double-resume.
    private final class Waiter: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, Never>
        private let lock = NSLock()
        private var resumed = false

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resumeOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    /// Runs `operation` exclusively; callers queue in arrival order.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        // A waiter cancelled while queued releases the gate immediately
        // instead of running a dead operation.
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        if isOccupied {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(continuation))
            }
        } else {
            isOccupied = true
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Ownership passes directly to the next waiter.
            next.resumeOnce()
        } else {
            isOccupied = false
        }
    }
}
