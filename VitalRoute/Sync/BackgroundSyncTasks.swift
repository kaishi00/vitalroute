import BackgroundTasks
import Foundation

/// BGTaskScheduler glue for automatic sync. The identifier and background
/// modes are declared in project.yml (the project's source of truth).
enum BackgroundSyncTasks {
    static let appRefreshIdentifier = "com.milim.vitalroute.sync"

    /// Must be called before the app finishes launching.
    static func register(engine: AutomaticSyncEngine) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: appRefreshIdentifier) { task in
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
                refresh.setTaskCompleted(success: true)
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
    /// now. Submission can legitimately fail (too many requests, not
    /// allowed) — the foreground catch-up and observer triggers remain.
    static func scheduleNext(after delay: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(delay, 1))
        try? BGTaskScheduler.shared.submit(request)
    }
}
