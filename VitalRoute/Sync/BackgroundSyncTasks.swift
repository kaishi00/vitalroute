import BackgroundTasks
import Foundation
import os

/// BGTaskScheduler glue for automatic sync. The identifier and background
/// modes are declared in project.yml (the project's source of truth).
enum BackgroundSyncTasks {
    static let appRefreshIdentifier = "com.milim.vitalroute.sync"
    private static let logger = Logger(subsystem: "com.milim.vitalroute", category: "background-sync")

    /// Must be called before the app finishes launching.
    static func register(engine: AutomaticSyncEngine) {
        // The closure overload of register does not throw on this toolchain;
        // an unpermitted identifier surfaces through the scheduler's own
        // diagnostics rather than a returned error.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: appRefreshIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Chain the next opportunity immediately; the engine decides
            // whether to actually run based on pending work and backoff.
            scheduleNext(after: 15 * 60)

            let work = Task { @MainActor in
                // Restoration may still be reading the configuration (or
                // discovering secure storage is unavailable); waiting for it
                // keeps this wake from completing as a no-op pass before the
                // engine knows what to do.
                await engine.waitForLaunchRestoration()
                // Expiration during a slow restoration: stop here instead of
                // starting work the budget can no longer cover.
                guard !Task.isCancelled else {
                    refresh.setTaskCompleted(success: false)
                    return
                }
                engine.backgroundTaskFired()
                await engine.waitUntilIdle()
                // Expiration cancels this task: report honestly.
                refresh.setTaskCompleted(success: !Task.isCancelled)
            }
            refresh.expirationHandler = {
                work.cancel()
                Task { @MainActor in
                    engine.cancelActiveWork()
                }
            }
        }
    }

    /// Submits an app-refresh request no earlier than `delay` seconds from
    /// now. Submission can legitimately fail (too many pending requests,
    /// unsupported identifier); the outcome is returned rather than only
    /// logged, because the engine reports whether a wake-up is actually
    /// armed instead of implying one is.
    @discardableResult
    static func scheduleNext(after delay: TimeInterval) -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(delay, 1))
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            // No sensitive data: error reason only.
            logger.info("BGTask submit deferred: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
