import BackgroundTasks
import Foundation
import os

/// BGTaskScheduler glue for automatic sync. The identifier and background
/// modes are declared in project.yml (the project's source of truth).
enum BackgroundSyncTasks {
    static let appRefreshIdentifier = "com.milim.vitalroute.sync"
    private static let logger = Logger(subsystem: "com.milim.vitalroute", category: "background-sync")

    /// Must be called before the app finishes launching. Registration
    /// failures (e.g. identifier missing from Info.plist) are logged, never
    /// silently swallowed.
    static func register(engine: AutomaticSyncEngine) -> Bool {
        do {
            try BGTaskScheduler.shared.register(
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
            return true
        } catch {
            // No sensitive data: identifier and error reason only.
            logger.error("BGTask registration failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Submits an app-refresh request no earlier than `delay` seconds from
    /// now. Submission can legitimately fail (too many pending requests,
    /// unsupported identifier); the outcome is reported so callers can
    /// surface that the retry is not armed.
    @discardableResult
    static func scheduleNext(after delay: TimeInterval) -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(delay, 1))
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            logger.info("BGTask submit deferred: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
