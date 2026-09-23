import Foundation
import Observation

/// Why automatic work is paused. Auto-recoverable reasons re-evaluate on
/// every trigger; actionable reasons require the user to intervene.
enum AutomaticSyncPauseReason: Equatable {
    case destinationMissing
    case credentialMissing
    case selectionEmpty
    case receiverIncompatible(String)
    case queueAtCapacity
    case authenticationFailed
    case protocolFailure(String)
    case deferred(String)

    var isAutoRecoverable: Bool {
        switch self {
        case .destinationMissing, .credentialMissing, .selectionEmpty, .deferred, .queueAtCapacity:
            true
        case .receiverIncompatible, .authenticationFailed, .protocolFailure:
            false
        }
    }

    var userMessage: String {
        switch self {
        case .destinationMissing:
            "Automatic sync is paused: save a destination first."
        case .credentialMissing:
            "Automatic sync is paused: add the API key for this destination."
        case .selectionEmpty:
            "Automatic sync is paused: enable at least one category in Health Data."
        case .receiverIncompatible(let detail):
            "Automatic sync is paused: the destination is not compatible (\(detail)). Update the receiver, then turn automatic sync off and on again."
        case .queueAtCapacity:
            "Automatic sync is paused: too many pending changes are waiting to upload. Once they are delivered it will resume automatically."
        case .authenticationFailed:
            "Automatic sync is paused: the destination rejected the API key. Fix the key, then turn automatic sync off and on again."
        case .protocolFailure(let detail):
            "Automatic sync is paused: \(detail) Turn automatic sync off and on again after fixing the destination."
        case .deferred(let detail):
            "Automatic sync deferred: \(detail)"
        }
    }
}

enum AutomaticSyncMode: Equatable {
    case disabled
    case active
    case paused(AutomaticSyncPauseReason)
}

enum AutomaticSyncTrigger: Equatable {
    case enablement
    case observer
    case backgroundTask
    case foregroundCatchUp
    case manualSyncFinished
    case absorbedCatchUp
}

enum AutomaticSyncEnableResult: Equatable {
    case enabled
    case failed(message: String)
}

enum AutomaticSyncEngineError: LocalizedError, Equatable {
    /// A newer configuration decision replaced this operation while it was
    /// suspended. The newer decision owns the engine's state; this one must
    /// not touch it.
    case configurationSuperseded

    var errorDescription: String? {
        "The configuration changed before this finished."
    }
}

/// Bounds for one background execution opportunity.
enum BackgroundSyncLimits {
    static let changePageSize = 500
    static let pagesPerCategoryPerPass = 20
    static let maxDeliveryBatchesPerRun = 30
    /// The initial scope covers the same seven-day window as manual sync.
    static let bootstrapWindowDays = 7
}

/// How a delivery failure should be handled.
enum DeliveryFailureClassification: Equatable {
    case transient
    case actionable(AutomaticSyncPauseReason)
    case deferred(String)
}

/// Drives automatic synchronization: observers for the selected categories,
/// bounded incremental query passes with durable checkpoints, a durable
/// outbox, bounded delivery with persisted retry/backoff, and honest
/// status. All work passes through the shared `SyncWorkGate`, so manual and
/// automatic work are serialized and can never race checkpoints.
///
/// ### Ownership
/// Every asynchronous operation here can outlive the user intent that
/// started it — an authorization prompt, a capability check, a suspended
/// observer registration. A monotonic *configuration generation* arbitrates:
/// a user decision (enable, disable, destination or category change, purge)
/// claims a new generation before its first suspension, and any older
/// operation that resumes afterwards unwinds instead of applying. Nothing
/// stale may change the mode, arm observers, schedule successor work, or
/// start an upload under a configuration the user has already replaced.
@MainActor
@Observable
final class AutomaticSyncEngine {
    private let healthData: any HealthDataProviding
    private let client: any DestinationClient
    private let stateStore: SyncStateStore
    private let outbox: Outbox
    private let workGate: SyncWorkGate
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// Injectable so tests can observe scheduling without BackgroundTasks;
    /// production sets the BGTaskScheduler-backed closure. Returns whether a
    /// wake-up was actually armed, so the engine can be honest when it was
    /// not.
    @ObservationIgnored var scheduleBackgroundRetry: (@Sendable (TimeInterval) -> Bool)?

    private(set) var mode: AutomaticSyncMode = .disabled
    private(set) var pendingCount = 0
    private(set) var lastDeliveryAt: Date?
    private(set) var lastCheckAt: Date?
    private(set) var lastStatusMessage: String?
    private(set) var isRunning = false
    private(set) var nextRetryAt: Date?

    @ObservationIgnored private var activeRunTask: Task<Void, Never>?
    @ObservationIgnored private var needsCatchUp = false
    /// Set when captured changes were discarded without being delivered.
    ///
    /// Dropping health data the user chose to send is not a transient
    /// delivery hiccup, so a later successful delivery must not clear the
    /// notice before it was ever read. It is cleared when the user acts —
    /// enabling or disabling automatic sync.
    @ObservationIgnored private var discardedWorkNotice: String?
    /// Configuration snapshot; never carried across a destination change.
    @ObservationIgnored private var destination = ""
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var selectedMetrics: Set<HealthMetric> = []
    @ObservationIgnored private static let enabledFlagKey = "automaticSync.enabled"

    // MARK: - Configuration ownership

    /// The configuration the engine has been told about, whether or not
    /// automatic sync is on. Comparing against this survives UI callbacks
    /// that re-report identical values, while a genuine change still
    /// invalidates in-flight work.
    private struct ConfigurationSnapshot: Equatable {
        var destination: String
        var token: String?
        var metrics: Set<HealthMetric>
    }

    init(
        healthData: any HealthDataProviding,
        client: any DestinationClient,
        stateStore: SyncStateStore,
        outbox: Outbox,
        workGate: SyncWorkGate = SyncWorkGate(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.healthData = healthData
        self.client = client
        self.stateStore = stateStore
        self.outbox = outbox
        self.workGate = workGate
        self.defaults = defaults
        self.now = now
        if defaults.bool(forKey: Self.enabledFlagKey) {
            mode = .active
        }
    }

    var isEnabled: Bool {
        mode != .disabled
    }

    /// Prepares the durable stores' on-disk layout (app-launch step).
    func prepareStorage() async {
        try? await stateStore.prepare()
        try? await outbox.prepare()
    }

    // MARK: - Lifecycle

    /// Enables automatic sync. Foreground user action: requests HealthKit
    /// authorization for the selection and verifies the receiver supports
    /// contract v2 (deletions) before any background work is armed.
    func enable(
        destination endpoint: String,
        token bearerToken: String?,
        metrics: Set<HealthMetric>
    ) async -> AutomaticSyncEnableResult {
        guard mode == .disabled else {
            return .failed(message: "Automatic sync is already on.")
        }
        guard !metrics.isEmpty else {
            let message = AutomaticSyncPauseReason.selectionEmpty.userMessage
            lastStatusMessage = message
            return .failed(message: message)
        }
        guard let trimmedToken = Self.normalizedToken(bearerToken) else {
            let message = AutomaticSyncPauseReason.credentialMissing.userMessage
            lastStatusMessage = message
            return .failed(message: message)
        }
        let configuration: DestinationConfiguration
        do {
            configuration = try DestinationConfiguration(endpoint: endpoint)
        } catch {
            let message = "The saved destination is not usable: \(error.localizedDescription)"
            lastStatusMessage = message
            return .failed(message: message)
        }
        let armedDestination = configuration.endpoint.absoluteString

        // Claim the user's intent before the first suspension. Everything
        // below is this generation's work; a destination or category change
        // arriving during the authorization prompt or capability check
        // supersedes it instead of being overwritten by it.
        let generation = claimConfiguration(
            destination: armedDestination,
            token: trimmedToken,
            metrics: metrics
        )

        // Foreground HealthKit authorization: background work must never
        // present an authorization sheet.
        do {
            try await healthData.requestReadAuthorization(for: metrics)
        } catch {
            guard isCurrent(generation) else { return superseded("authorization") }
            lastStatusMessage = error.localizedDescription
            return .failed(message: error.localizedDescription)
        }
        // Authorization returned, but the user may have moved the destination
        // (or the selection) while the prompt was up. Everything below is
        // work for an obsolete configuration, so it must not run.
        guard isCurrent(generation) else { return superseded("authorization") }

        // Capability check: automatic sync requires deletion support.
        do {
            let health = try await client.testConnection(
                to: configuration.endpoint,
                authorization: DestinationAuthorization(bearerToken: trimmedToken)
            )
            guard health.supportsDeletions else {
                guard isCurrent(generation) else { return superseded("the capability check") }
                let message = "The destination receiver does not support deletions (contract v2). Update it to a v2 receiver, then try again. Manual sync keeps working."
                lastStatusMessage = message
                return .failed(message: message)
            }
        } catch {
            guard isCurrent(generation) else { return superseded("the capability check") }
            let message = "Could not verify the destination: \(error.localizedDescription)"
            lastStatusMessage = message
            return .failed(message: message)
        }

        guard isCurrent(generation) else { return superseded("the capability check") }

        destination = armedDestination
        token = trimmedToken
        selectedMetrics = metrics

        do {
            try await registerObservers(for: metrics, generation: generation)
        } catch {
            // A newer decision may have replaced this enablement while
            // registration was suspended; that decision owns the state now.
            guard isCurrent(generation) else { return superseded("observer registration") }
            let message = "Automatic sync could not start: observers could not be registered (\(error.localizedDescription))."
            lastStatusMessage = message
            return .failed(message: message)
        }

        // Registration is the last thing that can fail, so the engine only
        // reports itself on once the observers are actually armed.
        defaults.set(true, forKey: Self.enabledFlagKey)
        mode = .active
        discardedWorkNotice = nil
        lastStatusMessage = nil

        startPass(trigger: .enablement)
        return .enabled
    }

    private func superseded(_ phase: String) -> AutomaticSyncEnableResult {
        .failed(message: "Automatic sync was not turned on: the configuration changed during \(phase). Turn it on again to use the current destination.")
    }

    private func registerObservers(for metrics: Set<HealthMetric>, generation: Int) async throws {
        registrationAttempts += 1
        let attempt = registrationAttempts
        try await healthData.observeChanges(for: metrics) { [weak self] completion in
            guard let self else {
                // Nothing is left to capture into: answering is the only
                // correct outcome, or HealthKit waits on this notification
                // forever.
                completion.complete()
                return
            }
            Task { @MainActor in self.observerFired(completion: completion) }
        }
        // Registration that finished after a stop or a newer configuration
        // belongs to neither, and the engine must not record it as armed.
        guard isCurrent(generation) else {
            // The newer decision owns observation now: it either replaced
            // this registration (a newer start) or tore it down (a stop), and
            // a stop issued from here could tear down what it installed. The
            // exception is a decision that superseded this enablement without
            // touching observation — the engine is off and no newer attempt
            // is coming, so these observers would stay armed with no owner.
            if attempt == registrationAttempts, mode == .disabled {
                await healthData.stopObservingChanges()
            }
            throw AutomaticSyncEngineError.configurationSuperseded
        }
        observersRegistered = true
    }

    /// Counts registration attempts so a superseded one can tell whether a
    /// newer attempt already took over observation.
    @ObservationIgnored private var registrationAttempts = 0

    /// Whether observers are currently registered; a pass that finds this
    /// false re-registers them (e.g. recovering from a deferred pause).
    @ObservationIgnored private var observersRegistered = false

    /// Disables automatic sync. Work stops; queued events and checkpoints
    /// are kept so re-enabling resumes where it left off (nothing is ever
    /// re-pointed to a different destination — that is `configurationChanged`).
    ///
    /// Asynchronous because teardown is transactional: observer registration
    /// and background delivery are unwound before this returns, so a
    /// re-enable that follows immediately cannot race a stale stop.
    func disable() async {
        // Claimed even when already off: an enablement suspended in
        // authorization or registration must not turn it back on afterwards.
        _ = claimConfiguration(destination: destination, token: token, metrics: selectedMetrics)
        guard mode != .disabled else { return }

        activeRunTask?.cancel()
        observersRegistered = false
        defaults.set(false, forKey: Self.enabledFlagKey)
        mode = .disabled
        // Nothing will capture these now; the next enable re-reads from the
        // checkpoint, so answering only abandons the notification.
        releaseObserverCompletions()
        discardedWorkNotice = nil
        lastStatusMessage = "Automatic sync is off."

        await healthData.stopObservingChanges()
        if let task = activeRunTask {
            _ = await task.value
        }
        activeRunTask = nil
        isRunning = false
        needsCatchUp = false
        await refreshPendingCount()
    }

    /// Called at every supported app launch (app-level, not screen-level)
    /// with the current persisted configuration.
    func restoreOnLaunch(
        destination endpoint: String,
        token bearerToken: String?,
        metrics: Set<HealthMetric>
    ) async {
        guard mode != .disabled else { return }
        let generation = claimConfiguration(
            destination: Self.normalizedDestination(endpoint),
            token: Self.normalizedToken(bearerToken),
            metrics: metrics
        )
        destination = Self.normalizedDestination(endpoint)
        token = Self.normalizedToken(bearerToken)
        selectedMetrics = metrics
        if let reason = unsatisfiedPrerequisite() {
            mode = .paused(reason)
            return
        }
        do {
            try await registerObservers(for: metrics, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            observersRegistered = false
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
            return
        }
        guard isCurrent(generation) else { return }
        startPass(trigger: .foregroundCatchUp)
    }

    /// Configuration-change hook. Enforces the destination-identity policy:
    /// pending work and checkpoints are never moved to a different
    /// recipient; a destination change disables automatic sync and discards
    /// the previous destination's pending work with a visible notice.
    func configurationChanged(
        destination newDestinationRaw: String,
        token newToken: String?,
        metrics newMetrics: Set<HealthMetric>
    ) async {
        let newDestination = Self.normalizedDestination(newDestinationRaw)
        let newToken = Self.normalizedToken(newToken)

        // A real change invalidates in-flight work before the first
        // suspension; an unchanged re-report (the UI re-renders) must not
        // cancel an enablement the user just asked for.
        let generation = claimConfigurationIfChanged(
            destination: newDestination,
            token: newToken,
            metrics: newMetrics
        )

        let previousDestination = destination
        let previousMetrics = selectedMetrics
        let destinationChanged = !previousDestination.isEmpty && previousDestination != newDestination

        if mode == .disabled {
            // Track configuration so the first post-enable snapshot is
            // consistent, and keep the snapshot current so a later
            // comparison never has to reason about how long it has been
            // stale. A destination change still has to discard: work
            // captured for the previous endpoint must never become
            // deliverable to the new one once sync is turned back on.
            destination = newDestination
            token = newToken
            selectedMetrics = newMetrics
            if destinationChanged {
                await discardPendingWork(generation: generation, notice: .destinationChangedWhileOff)
            }
            return
        }

        if destinationChanged {
            // Flip the guards synchronously BEFORE the first await: any
            // trigger arriving during the purge awaits must find the engine
            // disabled and the destination cleared, so no fresh pass can
            // start against the old destination mid-purge.
            mode = .disabled
            defaults.set(false, forKey: Self.enabledFlagKey)
            destination = ""
            token = nil
            let passWasRunning = activeRunTask != nil
            activeRunTask?.cancel()
            if let task = activeRunTask {
                _ = await task.value
            }
            activeRunTask = nil
            isRunning = false
            needsCatchUp = false
            releaseObserverCompletions()
            await healthData.stopObservingChanges()
            guard isCurrent(generation) else { return }
            observersRegistered = false
            await discardPendingWork(generation: generation, notice: .destinationChanged(passWasRunning: passWasRunning))
            return
        }

        destination = newDestination
        token = newToken
        selectedMetrics = newMetrics

        // Categories that were disabled must never upload their queued data.
        // A pass re-appending that category's events mid-flight is drained
        // first so the purge is authoritative.
        if !previousMetrics.subtracting(newMetrics).isEmpty {
            activeRunTask?.cancel()
            if let task = activeRunTask {
                _ = await task.value
            }
            activeRunTask = nil
            isRunning = false
            needsCatchUp = false
        }
        for removed in previousMetrics where !newMetrics.contains(removed) {
            await outbox.removeCategory(removed)
            await stateStore.clearCheckpoint(for: removed)
        }
        await refreshPendingCount()

        guard isCurrent(generation) else { return }

        if let reason = unsatisfiedPrerequisite() {
            if case .paused(let current) = mode, !current.isAutoRecoverable {
                // Keep the actionable reason; it still applies.
            } else {
                mode = .paused(reason)
            }
            return
        }

        // Re-register observers for the (possibly changed) set; a category
        // re-enable gets a fresh scope generation on its next query because
        // its checkpoint was cleared above.
        do {
            try await registerObservers(for: newMetrics, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            observersRegistered = false
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
            return
        }
        guard isCurrent(generation) else { return }
        if case .paused(let reason) = mode, reason.isAutoRecoverable {
            mode = .active
        }
        startPass(trigger: .foregroundCatchUp)
    }

    /// Canonical destination identity: identical spellings must compare
    /// equal no matter which entry point stored them.
    private static func normalizedDestination(_ raw: String) -> String {
        (try? DestinationConfiguration(endpoint: raw).endpoint.absoluteString) ?? raw
    }

    /// Bearer tokens are trimmed at every entry point: a whitespace-only
    /// value is not a credential, and `!token.isEmpty` must not accept one.
    private static func normalizedToken(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Observer notifications

    /// Notifications whose capture has not become durable yet.
    ///
    /// HealthKit is waiting on each of these. They are released at the end of
    /// the capture phase that handles them — durable, not merely transmitted —
    /// or immediately when there is nothing to capture, and the coordinator's
    /// deadline covers a capture that never finishes. Delivery is never
    /// allowed to hold one: a parked upload must not delay HealthKit's
    /// completion, and a slow receiver must not look like a stalled app.
    @ObservationIgnored private var pendingObserverCompletions: [ObserverCompletion] = []

    /// The observer handler: a trigger, not a result. The callback itself
    /// stays trivial; bounded work happens in the single-flight pass.
    private func observerFired(completion: ObserverCompletion) {
        guard mode != .disabled else {
            completion.complete()
            return
        }
        pendingObserverCompletions.append(completion)
        startPass(trigger: .observer)
    }

    /// Releases every held completion exactly once. Called wherever the
    /// capture they were waiting on has settled one way or the other.
    private func releaseObserverCompletions() {
        guard !pendingObserverCompletions.isEmpty else { return }
        let pending = pendingObserverCompletions
        pendingObserverCompletions.removeAll()
        for completion in pending {
            completion.complete()
        }
    }

    /// Foreground transition hook: catch up when there is something to do.
    func foregroundCatchUp() {
        guard mode != .disabled else { return }
        startPass(trigger: .foregroundCatchUp)
    }

    /// BGTaskScheduler entry point.
    func backgroundTaskFired() {
        guard mode != .disabled else { return }
        startPass(trigger: .backgroundTask)
    }

    /// Bounded wait used by the background-task handler to hold the task
    /// open while the pass finishes; the expiration handler cancels the work
    /// regardless, so this is best-effort only. Real time, not the injected
    /// clock, so tests advancing the clock cannot shorten the wait.
    func waitUntilIdle(timeout: TimeInterval = 25) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            if Task.isCancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func manualSyncFinished() {
        guard mode != .disabled else { return }
        startPass(trigger: .manualSyncFinished)
    }

    /// Cancels in-flight work (background task expiration). Pending work is
    /// preserved by construction; the checkpoint only ever covers changes
    /// already durably recorded.
    func cancelActiveWork() {
        activeRunTask?.cancel()
    }

    // MARK: - Single-flight pass

    private func startPass(trigger: AutomaticSyncTrigger) {
        guard mode != .disabled else {
            releaseObserverCompletions()
            return
        }
        guard activeRunTask == nil else {
            // Absorb triggers that arrive during a run: one catch-up pass
            // after the current one finishes.
            needsCatchUp = true
            return
        }
        // Set synchronously so waiters see the run as soon as the trigger
        // returns; cleared only when no absorbed catch-up follows.
        isRunning = true
        let generation = configurationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPass(trigger: trigger, generation: generation)
            self.activeRunTask = nil
            // A cancelled run must never spawn a successor against purged
            // state. That is enforced by `isEnabled` together with the purge
            // paths clearing `needsCatchUp` synchronously before their first
            // suspension, so a surviving flag was set by a trigger arriving
            // for the configuration in effect now — and dropping it would
            // defer that work to the next unrelated trigger (a credential
            // replacement during a pass is the common case).
            if self.needsCatchUp, self.isEnabled {
                self.needsCatchUp = false
                self.startPass(trigger: .absorbedCatchUp)
                return
            }
            self.isRunning = false
        }
        activeRunTask = task
    }

    private func performPass(trigger: AutomaticSyncTrigger, generation: Int) async {
        // Belt and braces: the capture phase releases these on every path it
        // can reach, and this covers the paths it cannot (a run cancelled
        // while still waiting for the gate).
        defer { releaseObserverCompletions() }
        do {
            try await workGate.run { @MainActor [weak self] () throws -> Void in
                try await self?.performPassBody(trigger: trigger, generation: generation)
            }
        } catch is CancellationError {
            if isCurrent(generation) {
                lastStatusMessage = "Automatic sync stopped early this run; pending work is kept and will resume."
            }
        } catch {
            await handlePassFailure(error, generation: generation)
        }
        await refreshPendingCount()
        await scheduleRetryIfNeeded(generation: generation)
    }

    private func performPassBody(trigger: AutomaticSyncTrigger, generation: Int) async throws {
        // Capture first. The completions HealthKit is waiting on are released
        // as soon as the captured changes are durable; delivery follows and
        // never holds them.
        guard try await capturePhase(trigger: trigger, generation: generation) else { return }
        try await deliverPending(generation: generation)
        if isCurrent(generation) {
            lastCheckAt = now()
        }
    }

    /// Prerequisites, pause re-evaluation, queue/destination binding,
    /// observer re-arming, backpressure, and the bounded incremental query.
    ///
    /// Returns false when the pass must stop (a pause that still applies).
    /// Releases every held observer completion on the way out — durable
    /// capture, early return, failure, or cancellation — because the work
    /// they were waiting on is settled by then.
    private func capturePhase(trigger: AutomaticSyncTrigger, generation: Int) async throws -> Bool {
        defer { releaseObserverCompletions() }
        guard mode != .disabled else { return false }

        // Pause re-evaluation: auto-recoverable reasons clear when their
        // prerequisite is satisfied again.
        if case .paused(let reason) = mode {
            if !reason.isAutoRecoverable {
                lastStatusMessage = reason.userMessage
                return false
            }
            if let stillUnsatisfied = unsatisfiedPrerequisite() {
                mode = .paused(stillUnsatisfied)
                lastStatusMessage = stillUnsatisfied.userMessage
                return false
            }
            mode = .active
            // Recovered: the pause notice is stale once work resumes.
            lastStatusMessage = nil
        } else if let reason = unsatisfiedPrerequisite() {
            mode = .paused(reason)
            lastStatusMessage = reason.userMessage
            return false
        }

        // Queued changes are bound to the destination they were captured
        // for, durably. A mismatch means the engine was reconfigured without
        // this queue being discarded — typically a change made while the app
        // was not running. Discard before capturing: nothing may be added to
        // a queue that is no longer addressable, and nothing in it may reach
        // an endpoint the user did not configure for it.
        if await discardMismatchedQueue() {
            guard isCurrent(generation) else { return false }
        }

        // Observers lost to a deferred pause (or a fresh enable whose pass
        // has not run yet) are re-armed before any work in this pass.
        if !observersRegistered {
            do {
                try await registerObservers(for: selectedMetrics, generation: generation)
            } catch {
                guard isCurrent(generation) else { return false }
                mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
                return false
            }
        }

        let atCapacity = (try? await outbox.isAtCapacity()) ?? false
        guard isCurrent(generation) else { return false }
        if atCapacity {
            // Backpressure: stop capturing, keep draining. The pause is
            // auto-recoverable — once delivery drains below capacity, the
            // next pass resumes queries.
            mode = .paused(.queueAtCapacity)
        } else {
            try await runQueryPass(generation: generation)
        }
        return true
    }

    /// Bounded incremental capture: for every selected category, page
    /// through additions and deletions since the checkpoint, appending to
    /// the outbox *before* advancing the checkpoint.
    private func runQueryPass(generation: Int) async throws {
        guard !selectedMetrics.isEmpty else { return }
        // Record the queue's owner before anything is added to it: if the
        // app dies before the first append, a stale marker is refused by
        // the mismatch check, which is the safe direction. A marker that
        // cannot be written fails the capture — otherwise the next pass
        // would read a correctly-attributed queue as foreign and discard it.
        try await stateStore.savePendingScope(destination)

        let capacity = Outbox.capacityLimit
        for metric in HealthMetric.allCases where selectedMetrics.contains(metric) {
            try Task.checkCancellation()

            let checkpoint = await stateStore.loadCheckpoint(for: metric)
            let scope: CategoryScope
            var anchorData: Data?
            if let checkpoint,
               checkpoint.scope.destination == destination,
               checkpoint.scope.metric == metric {
                // The stored checkpoint's generation and window are only
                // valid for this exact scope identity.
                scope = checkpoint.scope
                anchorData = checkpoint.anchorData
            } else {
                // Bootstrap: fresh generation, fixed seven-day window. Never
                // lifetime history, and never a moved predicate.
                scope = CategoryScope(
                    destination: destination,
                    metric: metric,
                    generation: UUID(),
                    windowStart: Calendar.current.date(
                        byAdding: .day,
                        value: -BackgroundSyncLimits.bootstrapWindowDays,
                        to: now()
                    ) ?? now()
                )
                anchorData = nil
            }

            for _ in 0..<BackgroundSyncLimits.pagesPerCategoryPerPass {
                try Task.checkCancellation()
                let page: HealthChangePage
                do {
                    page = try await healthData.changePage(
                        for: metric,
                        since: anchorData,
                        windowStart: scope.windowStart,
                        limit: BackgroundSyncLimits.changePageSize
                    )
                } catch let error as HealthKitServiceError where error == .corruptedAnchor {
                    // Drop only the unreadable cursor; the next pass
                    // bootstraps a fresh scope (replay dedupes safely).
                    await stateStore.clearCheckpoint(for: metric)
                    throw error
                }
                // A page captured while a destination change or category
                // disable began must not be committed after that purge.
                try Task.checkCancellation()
                var events: [SyncChangeEvent] = page.additions.map { .upsert($0) }
                events.append(contentsOf: page.deletions.map { .delete($0) })
                if !events.isEmpty {
                    _ = try await outbox.append(events)
                }
                // Checkpoint advance happens only after the page's changes
                // are durably recorded: a crash before this line replays
                // the page (harmlessly — events dedupe).
                anchorData = page.anchorData
                try await stateStore.save(CategoryCheckpoint(
                    scope: scope,
                    anchorData: anchorData,
                    updatedAt: now()
                ))
                if !page.isFull {
                    break
                }
                // A full page means more changes may follow; the page budget
                // bounds this run and the persisted checkpoint lets the next
                // run resume mid-stream.
            }

            guard isCurrent(generation) else { return }
            let pending = (try? await outbox.pendingCount()) ?? 0
            if pending >= capacity {
                mode = .paused(.queueAtCapacity)
                return
            }
        }
    }

    /// Bounded delivery: drain the outbox in batches, removing events only
    /// after a reconciled acknowledgment.
    private func deliverPending(generation: Int) async throws {
        guard let endpointURL = URL(string: destination), endpointURL.scheme == "https",
              let token else {
            return
        }
        let authorization = DestinationAuthorization(bearerToken: token)

        var retryState = await stateStore.loadRetryState()
        guard isCurrent(generation) else { return }
        if let nextAttempt = retryState.nextAttemptAt, nextAttempt > now() {
            nextRetryAt = nextAttempt
            return
        }

        var quarantinedDuringRun = 0
        for _ in 0..<BackgroundSyncLimits.maxDeliveryBatchesPerRun {
            try Task.checkCancellation()
            let snapshot = try await outbox.nextBatch()
            pendingCount = snapshot.totalPending
            quarantinedDuringRun += snapshot.quarantinedCount
            if quarantinedDuringRun > 0 {
                lastStatusMessage = "Some captured changes were unreadable and were set aside (\(quarantinedDuringRun)). Delivery of the remaining changes continues."
            }
            if snapshot.events.isEmpty {
                break
            }

            do {
                _ = try await client.sendChanges(
                    snapshot.events,
                    batchID: UUID(),
                    to: endpointURL,
                    authorization: authorization
                )
                // Removal only after the receiver's committed, reconciled
                // acknowledgment; a crash before removal re-sends and the
                // receiver answers idempotently.
                await outbox.remove(eventIDs: snapshot.events.map(\.eventID))
                lastDeliveryAt = now()
                retryState.consecutiveFailures = 0
                retryState.nextAttemptAt = nil
                retryState.lastFailureIsActionable = false
                retryState.lastFailureMessage = nil
                retryState.lastSuccessAt = now()
                await stateStore.saveRetryState(retryState)
                nextRetryAt = nil
                if quarantinedDuringRun == 0 {
                    lastStatusMessage = discardedWorkNotice
                }
            } catch {
                // The error may have arrived after a newer configuration
                // decision superseded this pass; that decision owns the mode
                // and the queue now.
                guard isCurrent(generation) else { return }
                let classification = Self.classify(error)
                switch classification {
                case .transient:
                    retryState.consecutiveFailures += 1
                    retryState.lastFailureIsActionable = false
                    retryState.lastFailureMessage = error.localizedDescription
                    retryState.nextAttemptAt = now().addingTimeInterval(
                        retryState.backoffSeconds(afterFailureCount: retryState.consecutiveFailures)
                    )
                    await stateStore.saveRetryState(retryState)
                    nextRetryAt = retryState.nextAttemptAt
                    lastStatusMessage = "Delivery failed (\(error.localizedDescription)). Pending changes are kept; retry is scheduled with backoff."
                case .actionable(let reason):
                    retryState.consecutiveFailures += 1
                    retryState.lastFailureIsActionable = true
                    retryState.lastFailureMessage = reason.userMessage
                    retryState.nextAttemptAt = nil
                    await stateStore.saveRetryState(retryState)
                    mode = .paused(reason)
                    lastStatusMessage = reason.userMessage
                case .deferred(let detail):
                    retryState.lastFailureMessage = detail
                    retryState.nextAttemptAt = now().addingTimeInterval(60)
                    await stateStore.saveRetryState(retryState)
                    nextRetryAt = retryState.nextAttemptAt
                    lastStatusMessage = AutomaticSyncPauseReason.deferred(detail).userMessage
                }
                return
            }
        }
    }

    private func handlePassFailure(_ error: Error, generation: Int) async {
        guard isCurrent(generation) else { return }
        let classification = Self.classify(error)
        var retryState = await stateStore.loadRetryState()
        guard isCurrent(generation) else { return }
        switch classification {
        case .transient:
            retryState.consecutiveFailures += 1
            retryState.lastFailureIsActionable = false
            retryState.lastFailureMessage = error.localizedDescription
            retryState.nextAttemptAt = now().addingTimeInterval(
                retryState.backoffSeconds(afterFailureCount: retryState.consecutiveFailures)
            )
            await stateStore.saveRetryState(retryState)
            nextRetryAt = retryState.nextAttemptAt
            lastStatusMessage = "Automatic sync could not finish (\(error.localizedDescription)). Pending work is kept; it will retry."
        case .actionable(let reason):
            retryState.lastFailureIsActionable = true
            retryState.lastFailureMessage = reason.userMessage
            retryState.nextAttemptAt = nil
            await stateStore.saveRetryState(retryState)
            mode = .paused(reason)
            lastStatusMessage = reason.userMessage
        case .deferred(let detail):
            retryState.nextAttemptAt = now().addingTimeInterval(60)
            await stateStore.saveRetryState(retryState)
            nextRetryAt = retryState.nextAttemptAt
            lastStatusMessage = AutomaticSyncPauseReason.deferred(detail).userMessage
        }
    }

    private func refreshPendingCount() async {
        pendingCount = (try? await outbox.pendingCount()) ?? 0
    }

    private func scheduleRetryIfNeeded(generation: Int) async {
        guard isCurrent(generation) else { return }
        guard mode != .disabled, pendingCount > 0 else { return }
        if case .paused(let reason) = mode, !reason.isAutoRecoverable {
            // Actionable pauses need the user; a wakeup would burn budget
            // and accomplish nothing.
            return
        }
        // No scheduler is configured in tests; production always sets one.
        guard let scheduleRetry = scheduleBackgroundRetry else { return }
        let retryState = await stateStore.loadRetryState()
        guard isCurrent(generation) else { return }
        let delay: TimeInterval
        if let next = retryState.nextAttemptAt {
            delay = max(0, next.timeIntervalSince(now()))
        } else {
            delay = 60
        }
        if !scheduleRetry(delay) {
            // Honest reporting: iOS refused the request (too many pending
            // requests, or an unpermitted identifier), so no wake-up is
            // armed and the status line must not imply otherwise.
            lastStatusMessage = "Pending changes are waiting, but iOS did not accept a background retry request. They will be delivered the next time VitalRoute runs."
        }
    }

    // MARK: - Queue ownership

    private enum DiscardNotice {
        case destinationChanged(passWasRunning: Bool)
        case destinationChangedWhileOff

        /// `discarded` is reported so the user learns how much was dropped;
        /// with nothing queued the notice says only what actually happened.
        func message(discarded: Int) -> String {
            let base = switch self {
            case .destinationChanged:
                "Automatic sync turned off because the destination changed."
            case .destinationChangedWhileOff:
                "The destination changed while automatic sync was off."
            }
            guard discarded > 0 else { return base }
            let inFlight: String
            if case .destinationChanged(let passWasRunning) = self, passWasRunning {
                // A request already on the wire cannot be recalled; saying so
                // is the honest account of what may have left the device.
                inFlight = " A batch already in flight may still have reached it."
            } else {
                inFlight = ""
            }
            return base + " \(discarded) pending change(s) for the previous destination were discarded — they will never be sent anywhere else.\(inFlight)"
        }
    }

    /// Discards the queue and clears everything bound to the destination it
    /// belonged to.
    private func discardPendingWork(generation: Int, notice: DiscardNotice) async {
        let discarded = (try? await outbox.pendingCount()) ?? 0
        await outbox.removeAll()
        await refreshPendingCount()
        await stateStore.clearAllCheckpoints()
        await stateStore.clearPendingScope()
        await stateStore.saveRetryState(.initial)
        // The discard happened whatever the generation now says, so the fact
        // is recorded unconditionally — a user must not silently lose queued
        // health data. Only the visible line is yielded to a newer decision
        // that has its own message; the notice resurfaces on the next
        // successful delivery otherwise.
        discardedWorkNotice = notice.message(discarded: discarded)
        if isCurrent(generation) {
            lastStatusMessage = discardedWorkNotice
        }
    }

    /// True when the queued changes were captured for a different
    /// destination and had to be discarded.
    ///
    /// This is the last line of defence for the destination-identity policy:
    /// a queue whose owner no longer matches is never delivered, and never
    /// added to. Absent ownership information fails closed.
    private func discardMismatchedQueue() async -> Bool {
        let pending = (try? await outbox.pendingCount()) ?? 0
        guard pending > 0 else { return false }
        guard await stateStore.loadPendingScope() != destination else { return false }
        await outbox.removeAll()
        await stateStore.clearAllCheckpoints()
        await stateStore.clearPendingScope()
        await stateStore.saveRetryState(.initial)
        await refreshPendingCount()
        discardedWorkNotice = "\(pending) queued change(s) were discarded because they were captured for a different destination. They will never be sent anywhere else."
        lastStatusMessage = discardedWorkNotice
        return true
    }

    // MARK: - Configuration ownership

    /// Bumped by every user configuration decision. Operations capture the
    /// generation they belong to and check it before touching state.
    @ObservationIgnored private var configurationGeneration = 0
    @ObservationIgnored private var latestConfiguration = ConfigurationSnapshot(
        destination: "",
        token: nil,
        metrics: []
    )

    private func isCurrent(_ generation: Int) -> Bool {
        generation == configurationGeneration
    }

    /// Claims a new generation for a decision, and records the configuration
    /// it applies to. Called before the caller's first suspension.
    private func claimConfiguration(
        destination: String,
        token: String?,
        metrics: Set<HealthMetric>
    ) -> Int {
        latestConfiguration = ConfigurationSnapshot(
            destination: destination,
            token: token,
            metrics: metrics
        )
        configurationGeneration += 1
        return configurationGeneration
    }

    /// Claims a new generation only when the configuration actually differs
    /// from the last one reported. The UI re-reports identical values on
    /// unrelated renders, and that must not cancel work the user just asked
    /// for.
    private func claimConfigurationIfChanged(
        destination: String,
        token: String?,
        metrics: Set<HealthMetric>
    ) -> Int {
        let new = ConfigurationSnapshot(destination: destination, token: token, metrics: metrics)
        guard new != latestConfiguration else {
            return configurationGeneration
        }
        latestConfiguration = new
        configurationGeneration += 1
        return configurationGeneration
    }

    // MARK: - Classification

    static func classify(_ error: Error) -> DeliveryFailureClassification {
        if error is CancellationError {
            return .transient
        }
        if error is AutomaticSyncEngineError {
            // Superseded work is not a destination fault; the newer decision
            // owns the state, so this only needs to not be reported as an
            // actionable destination problem.
            return .transient
        }
        if let clientError = error as? DestinationClientError {
            switch clientError {
            case .authenticationFailed:
                return .actionable(.authenticationFailed)
            case .redirected:
                return .actionable(.protocolFailure("the destination tried to redirect requests."))
            case .insecureEndpoint:
                return .actionable(.protocolFailure("the destination is not a valid HTTPS endpoint."))
            case .malformedAcknowledgment:
                return .actionable(.protocolFailure("the destination acknowledged batches in an unexpected format."))
            case .payloadTooLarge:
                return .actionable(.protocolFailure("the destination rejected the batch size."))
            case .tlsValidationFailed:
                return .actionable(.protocolFailure("the destination's certificate could not be validated."))
            case .requestTimedOut, .connectionFailed, .invalidResponse:
                return .transient
            case .serverRejected(let status):
                // Rate limiting is transient by nature; other 4xx responses
                // need the user to fix the destination.
                if status >= 500 || status == 429 {
                    return .transient
                }
                return .actionable(.protocolFailure("the destination returned HTTP \(status)."))
            case .emptyBatch:
                return .actionable(.protocolFailure("an empty batch was about to be sent."))
            }
        }
        if let healthError = error as? HealthKitServiceError {
            switch healthError {
            case .unavailable:
                return .deferred("Apple Health is unavailable right now.")
            case .corruptedAnchor:
                // The checkpoint will be rebuilt from the initial window.
                return .transient
            case .registrationSuperseded:
                // Another decision owns observer registration now.
                return .deferred("background observation was replaced.")
            case .authorizationFailed, .noMetricsRequested:
                return .deferred(healthError.localizedDescription)
            }
        }
        if let cocoaError = error as? CocoaError {
            // Storage failures during a pass are treated as deferred work:
            // the common cause is file protection while the device is
            // locked; anything else is retried with backoff and surfaced.
            _ = cocoaError
            return .deferred("protected storage is unavailable; the device may be locked.")
        }
        return .transient
    }

    private func unsatisfiedPrerequisite() -> AutomaticSyncPauseReason? {
        if destination.isEmpty {
            return .destinationMissing
        }
        guard token != nil else {
            return .credentialMissing
        }
        if selectedMetrics.isEmpty {
            return .selectionEmpty
        }
        return nil
    }
}
