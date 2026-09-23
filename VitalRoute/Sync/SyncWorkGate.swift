import Foundation

/// The single serialization boundary for all synchronization work. The
/// manual coordinator and the automatic engine acquire it, so manual and
/// background work can never run concurrently, race checkpoints, or
/// duplicate active delivery work.
actor SyncWorkGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `operation` exclusively; callers queue in arrival order.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if isOccupied {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isOccupied = true
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            // Ownership passes directly to the next waiter.
        } else {
            isOccupied = false
        }
    }
}
