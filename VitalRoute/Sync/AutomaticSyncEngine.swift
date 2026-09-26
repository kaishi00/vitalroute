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
    /// The persisted configuration (endpoint, credential) could not be read
    /// from secure storage — typically a locked-device background launch.
    /// Unlike `destinationMissing`, nothing needs the user: recovery is a
    /// successful configuration load, reported by the app's recovery path.
    case secureStorageUnavailable

    var isAutoRecoverable: Bool {
        switch self {
        case .destinationMissing, .credentialMissing, .selectionEmpty, .deferred, .queueAtCapacity,
             .secureStorageUnavailable:
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
            "Automatic sync is uploading a large backlog before it captures more history. Once the backlog shrinks, history capture resumes automatically."
        case .authenticationFailed:
            "Automatic sync is paused: the destination rejected the API key. Fix the key, then turn automatic sync off and on again."
        case .protocolFailure(let detail):
            "Automatic sync is paused: \(detail) Turn automatic sync off and on again after fixing the destination."
        case .deferred(let detail):
            "Automatic sync deferred: \(detail)"
        case .secureStorageUnavailable:
            "Automatic sync is waiting for secure storage (the device may be locked). It resumes automatically; queued data is kept."
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

    /// Backfill capture throttles when the historical queue reaches the
    /// high-water mark and resumes only below the low-water mark. The gap
    /// keeps a capture that is faster than delivery from flapping around a
    /// single threshold. Live capture is never throttled by these.
    static let backfillCaptureHighWater = 6_000
    static let backfillCaptureLowWater = 1_500
}

/// The engine's state as the user should see it. Deliberately richer than
/// `AutomaticSyncMode`: capture throttling and delivery are independent, and
/// reporting "Paused" while the queue is actively draining tells the user
/// the opposite of what is happening.
enum AutomaticSyncDisplayStatus: Equatable {
    /// Automatic sync is off.
    case off
    /// On, with nothing waiting and no work in flight.
    case idle
    /// On, with a pass running and no historical catch-up involved.
    case working
    /// On, with a pass reading a category's historical window.
    case backfilling
    /// On, with delivery draining a backlog while capture is throttled.
    /// New records keep flowing to the front of the queue.
    case deliveringBacklog
    /// On, with pending changes waiting for the next execution opportunity.
    case waitingRetry
    /// On, but stopped for a reason that needs the user (or time).
    case paused(AutomaticSyncPauseReason)
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
    /// Backfill-capture hysteresis thresholds. Injectable so tests can
    /// exercise the throttle with a handful of events.
    @ObservationIgnored private let backfillHighWater: Int
    @ObservationIgnored private let backfillLowWater: Int

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
    /// How many pending events belong to historical backfill lanes.
    private(set) var backfillPendingCount = 0
    /// Categories still reading their historical window.
    private(set) var backfillingMetrics: Set<HealthMetric> = []

    @ObservationIgnored private var activeRunTask: Task<Void, Never>?
    @ObservationIgnored private var needsCatchUp = false
    /// True while backfill capture is held back by the historical queue's
    /// high-water mark. Cleared with hysteresis once delivery has drained it.
    /// Observed: `displayStatus` projects it, so flipping it must invalidate
    /// the views reading the status.
    private var isBackfillThrottled = false
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
        now: @escaping @Sendable () -> Date = { Date() },
        backfillHighWater: Int = BackgroundSyncLimits.backfillCaptureHighWater,
        backfillLowWater: Int = BackgroundSyncLimits.backfillCaptureLowWater
    ) {
        self.healthData = healthData
        self.client = client
        self.stateStore = stateStore
        self.outbox = outbox
        self.workGate = workGate
        self.defaults = defaults
        self.now = now
        self.backfillHighWater = backfillHighWater
        self.backfillLowWater = backfillLowWater
        precondition(
            backfillLowWater <= backfillHighWater,
            "hysteresis requires low <= high water"
        )
        if defaults.bool(forKey: Self.enabledFlagKey) {
            mode = .active
        }
    }

    var isEnabled: Bool {
        mode != .disabled
    }

    /// The state as the UI should present it. The mode's `queueAtCapacity`
    /// pause is backpressure on historical capture only — delivery drains on
    /// every pass — so it is never reported as a paused engine, and a
    /// deferred pause between retries reads as waiting, not stopped.
    /// Prerequisite and destination-fault pauses keep the paused wording:
    /// nothing will upload until the user acts, and saying otherwise would
    /// be the same lie in the opposite direction.
    var displayStatus: AutomaticSyncDisplayStatus {
        guard mode != .disabled else { return .off }
        if case .paused(let reason) = mode {
            switch reason {
            case .deferred, .queueAtCapacity:
                break
            default:
                return .paused(reason)
            }
        }
        if isRunning {
            if isBackfillThrottled {
                return .deliveringBacklog
            }
            if case .paused(.queueAtCapacity) = mode {
                return .deliveringBacklog
            }
            return backfillingMetrics.isEmpty ? .working : .backfilling
        }
        return pendingCount > 0 ? .waitingRetry : .idle
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
            //
            // Checked synchronously, immediately before the teardown is
            // issued: a re-enable that starts in the instant between them has
            // its registration unwound by this stop and fails visibly with a
            // clean end state, rather than being silently left half-armed.
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
        isBackfillThrottled = false
        backfillingMetrics = []
        defaults.set(false, forKey: Self.enabledFlagKey)
        mode = .disabled
        // Nothing will capture these now; the next enable re-reads from the
        // checkpoint, so answering only abandons the notification.
        releaseObserverCompletions()
        discardedWorkNotice = nil
        // No retry belongs to a disabled engine: leaving this set made
        // Settings show a "Next retry" for sync that is off. An already
        // armed background request is harmless — its handler finds the
        // engine off and does nothing.
        nextRetryAt = nil
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
        // Category states are re-derived from persisted checkpoints by the
        // launch pass; nothing from the previous process carries over.
        isBackfillThrottled = false
        backfillingMetrics = []
        if let reason = unsatisfiedPrerequisite() {
            mode = .paused(reason)
            lastStatusMessage = reason.userMessage
            // The launch pass may never run (nothing changes to trigger one),
            // so the queued work is counted here rather than left at zero.
            await refreshPendingCount()
            return
        }
        do {
            try await registerObservers(for: metrics, generation: generation)
        } catch let error as HealthKitServiceError where error == .registrationSuperseded {
            // Launch runs this alongside the SwiftUI configuration callbacks,
            // which can share its generation; the concurrent report that won
            // owns observation, so this must not pause over a race it lost.
        } catch {
            guard isCurrent(generation) else { return }
            observersRegistered = false
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
            return
        }
        guard isCurrent(generation) else { return }
        startPass(trigger: .foregroundCatchUp)
    }

    /// Launch restoration when the persisted configuration could not be
    /// read — typically a locked-device background launch hitting
    /// `WhenUnlocked` Keychain items. The engine waits instead of treating
    /// the configuration as absent: no empty destination is claimed, queued
    /// work and checkpoints are untouched, and the app's recovery path
    /// (a settled load reported through `configurationChanged`) re-arms
    /// observers and resumes passes without user interaction.
    func restorePausedOnSecureStorage() async {
        guard mode != .disabled else { return }
        // A configuration re-report that already applied a real destination
        // wins: this launch decision was evaluated against unsettled stores
        // and is stale by the time it lands. Overwriting a recovered engine
        // with the wait would leave it paused until the next report — and a
        // background launch has no scene to produce one.
        guard destination.isEmpty else { return }
        mode = .paused(.secureStorageUnavailable)
        lastStatusMessage = AutomaticSyncPauseReason.secureStorageUnavailable.userMessage
        // The launch pass will not run (nothing is loaded to capture), so
        // the queued work is counted here rather than left at zero.
        await refreshPendingCount()
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

        // An empty report carries information only when the engine holds a
        // destination for it to purge (the removal flow: the report then
        // takes the destinationChanged branch below). When the engine has no
        // destination — a waiting launch, a disabled engine — the report is
        // a no-op, and relabeling the secure-storage wait as
        // destinationMissing would be the same lie as acting on it.
        if newDestination.isEmpty && destination.isEmpty {
            return
        }

        // A real change invalidates in-flight work before the first
        // suspension; an unchanged re-report (the UI re-renders) must not
        // cancel an enablement the user just asked for.
        let claim = claimConfigurationIfChanged(
            destination: newDestination,
            token: newToken,
            metrics: newMetrics
        )
        let generation = claim.generation

        let previousDestination = destination
        let previousMetrics = selectedMetrics
        // Observation is bound to the destination identity and the category
        // set, not to the credential: re-arming it for an identical
        // re-report would tear down and rebuild background delivery for
        // nothing, and is what made the registration race reachable.
        let registrationChanged = claim.isNew
            && (previousDestination != newDestination || previousMetrics != newMetrics)
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
            // The claim is dropped with the rest of the purged state; a
            // trigger arriving from here on belongs to whatever comes next.
            needsCatchUp = false
            isBackfillThrottled = false
            backfillingMetrics = []
            let passWasRunning = activeRunTask != nil
            activeRunTask?.cancel()
            if let task = activeRunTask {
                _ = await task.value
            }
            activeRunTask = nil
            isRunning = false
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
        // first so the purge is authoritative, and the absorbed claim is
        // dropped before the first suspension — the cancelled run must not
        // spawn a successor that drains the queue generically, before the
        // removal below runs, with the disabled category's events in it.
        if !previousMetrics.subtracting(newMetrics).isEmpty {
            needsCatchUp = false
            activeRunTask?.cancel()
            if let task = activeRunTask {
                _ = await task.value
            }
            activeRunTask = nil
            isRunning = false
        }
        for removed in previousMetrics where !newMetrics.contains(removed) {
            await outbox.removeCategory(removed)
            await stateStore.clearCheckpoint(for: removed)
            backfillingMetrics.remove(removed)
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
        // its checkpoint was cleared above. An identical re-report, or one
        // that only replaced the credential, keeps the existing registration.
        guard registrationChanged || !observersRegistered else {
            if case .paused(let reason) = mode, reason.isAutoRecoverable {
                mode = .active
                // The pause notice is stale the moment work resumes.
                lastStatusMessage = nil
            }
            startPass(trigger: .foregroundCatchUp)
            return
        }
        do {
            try await registerObservers(for: newMetrics, generation: generation)
        } catch let error as HealthKitServiceError where error == .registrationSuperseded {
            // One user action is reported through several observable
            // properties, so this call is not alone: a concurrent report for
            // the same decision won the registration race and owns
            // observation. Reporting that as a failure would pause the engine
            // and mark it unarmed while it is in fact armed, so this falls
            // through to the tail below, which schedules a pass. That is safe
            // to run redundantly — the loser shares the winner's generation,
            // the pass is single-flight and idempotent, and `startPass`
            // itself refuses to run while the engine is off, so a concurrent
            // destination change that already purged cannot be undone by it.
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
    ///
    /// An absorbed trigger is deliberately left in place across the
    /// cancellation: the successor guard stops the cancelled run from
    /// spawning one, and the flag is then consumed by whatever pass runs next
    /// — under the configuration in effect by then, after any purge has
    /// committed. That is redundant work at worst, never a leak; clearing it
    /// here is not required and must not be replaced by dropping the guard.
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
            // A cancelled run must never spawn a successor: a purge cancels
            // and awaits this task precisely so nothing continues against the
            // state it is about to mutate, and a background-task expiration is
            // an explicit instruction to stop spending budget. A run that was
            // superseded *without* being cancelled — a credential replacement
            // for the same destination, say — still honours the absorbed
            // trigger, because that claim belongs to the configuration now in
            // effect; dropping it there would defer delivery to an unrelated
            // trigger.
            if self.needsCatchUp, self.isEnabled, !Task.isCancelled {
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
            // A failed pass must not chain into a hot retry loop: the
            // scheduled retry (with backoff) owns resumption. Clearing the
            // absorbed trigger ends the chain here.
            needsCatchUp = false
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
            if case .secureStorageUnavailable = reason {
                // Held until the app's recovery path reports a settled
                // configuration (configurationChanged). Re-evaluating the
                // prerequisites here would relabel the wait as
                // destinationMissing, whose remedy — user action — is
                // exactly what the device being locked takes away.
                return false
            }
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
        if await discardMismatchedQueue(generation: generation) {
            guard isCurrent(generation) else { return false }
        }

        // Observers lost to a deferred pause (or a fresh enable whose pass
        // has not run yet) are re-armed before any work in this pass.
        if !observersRegistered {
            do {
                try await registerObservers(for: selectedMetrics, generation: generation)
            } catch let error as HealthKitServiceError where error == .registrationSuperseded {
                // A concurrent reconfiguration installed the observers for
                // this same decision; that decision's own pass does the work,
                // and this one must not pause over a race it lost.
                return false
            } catch {
                guard isCurrent(generation) else { return false }
                mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
                return false
            }
        }

        let counts = (try? await outbox.laneCounts()) ?? (live: 0, backfill: 0)
        guard isCurrent(generation) else { return false }
        updateBackfillThrottle(backfillPending: counts.backfill)

        let atCapacity = (try? await outbox.isAtCapacity()) ?? false
        guard isCurrent(generation) else { return false }
        if atCapacity {
            // Extreme backpressure at the queue's total capacity: even live
            // capture waits. Delivery is untouched and drains on this pass;
            // the pause is auto-recoverable, clearing once delivery has
            // made room.
            mode = .paused(.queueAtCapacity)
        } else {
            try await runQueryPass(generation: generation)
        }
        return true
    }

    /// Hysteresis for historical capture: throttle at the high-water mark,
    /// resume below the low-water mark. Evaluated once per pass; within a
    /// pass only setting (never clearing) applies, so a single pass cannot
    /// oscillate.
    private func updateBackfillThrottle(backfillPending: Int) {
        if isBackfillThrottled {
            if backfillPending <= backfillLowWater {
                isBackfillThrottled = false
            }
        } else if backfillPending >= backfillHighWater {
            isBackfillThrottled = true
        }
    }

    /// Bounded incremental capture: for every selected category, page
    /// through additions and deletions since the checkpoint, appending to
    /// the outbox *before* advancing the checkpoint.
    ///
    /// Each page rides the lane its content belongs to: pages of a category
    /// still draining its historical window are backfill, delivered behind
    /// live captures; once a read reaches the head of the stream (a page
    /// that is not full), the category is live and everything it reads —
    /// including that tail page — rides the live lane. Live capture is never
    /// throttled; only historical reading pauses at the backfill high-water
    /// mark, so a huge backfill can never delay newly arriving samples.
    private func runQueryPass(generation: Int) async throws {
        guard !selectedMetrics.isEmpty else { return }
        // Record the queue's owner before anything is added to it: if the
        // app dies before the first append, a stale marker is refused by
        // the mismatch check, which is the safe direction. A marker that
        // cannot be written fails the capture — otherwise the next pass
        // would read a correctly-attributed queue as foreign and discard it.
        try await stateStore.savePendingScope(destination)

        let capacity = await outbox.capacityLimitValue()
        // The configured backfill depth decides how far a bootstrap reaches.
        // An existing scope survives unless the depth now reaches DEEPER
        // than the scope's fixed window (a shallower preference never
        // discards already-captured history), and unless destination or
        // category changed — the identity rules below.
        let desiredWindowStart = BackfillDepth.stored(in: defaults)
            .windowStart(from: now())
        var backfillPending = ((try? await outbox.laneCounts())?.backfill) ?? 0
        for metric in HealthMetric.allCases where selectedMetrics.contains(metric) {
            try Task.checkCancellation()

            let checkpoint = await stateStore.loadCheckpoint(for: metric)
            let scope: CategoryScope
            var anchorData: Data?
            var isCaughtUp: Bool
            if let checkpoint,
               checkpoint.scope.destination == destination,
               checkpoint.scope.metric == metric,
               checkpoint.scope.windowStart <= desiredWindowStart {
                // The stored checkpoint's generation and window are only
                // valid for this exact scope identity, and its window is at
                // least as deep as the current preference.
                scope = checkpoint.scope
                anchorData = checkpoint.anchorData
                isCaughtUp = checkpoint.isCaughtUp
            } else {
                // Bootstrap: fresh generation, fixed window from the
                // configured depth (down to the entire history). Never a
                // moved predicate.
                scope = CategoryScope(
                    destination: destination,
                    metric: metric,
                    generation: UUID(),
                    windowStart: desiredWindowStart
                )
                anchorData = nil
                isCaughtUp = false
            }
            if isCaughtUp {
                backfillingMetrics.remove(metric)
            } else {
                backfillingMetrics.insert(metric)
            }

            // Backpressure on historical reading only: a category still
            // working through its window pauses that reading while a large
            // backfill queue waits to upload, resuming with hysteresis once
            // delivery drains it. Its FRESH samples are still served — the
            // head read below keeps them flowing on the live lane — so a
            // deep backfill can never delay newly arriving data.
            if !isCaughtUp, isBackfillThrottled {
                do {
                    let fresh = try await healthData.latestRecords(
                        for: metric,
                        windowStart: scope.windowStart,
                        limit: BackgroundSyncLimits.changePageSize
                    )
                    if !fresh.isEmpty {
                        // The checkpoint is untouched: these additions ride
                        // the live lane ahead of the queued history, and the
                        // unthrottled anchored read re-reports them later —
                        // the outbox dedupes by event identity and the
                        // receiver answers idempotently. Deletions for these
                        // samples are captured by that same later read.
                        _ = try await outbox.append(fresh.map { SyncChangeEvent.upsert($0) }, lane: .live)
                    }
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    // A sick head-read must not take the pass down: later
                    // live categories and the delivery phase still run, and
                    // the next pass retries from the untouched checkpoint.
                    continue
                }
                let pendingNow = (try? await outbox.pendingCount()) ?? 0
                if pendingNow >= capacity {
                    mode = .paused(.queueAtCapacity)
                    return
                }
                continue
            }

            for pageLoopIndex in 0..<BackgroundSyncLimits.pagesPerCategoryPerPass {
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
                // A full page belongs to the historical catch-up; the page
                // that drains the stream to its head is live data.
                let lane: Outbox.Lane = isCaughtUp || !page.isFull ? .live : .backfill
                var events: [SyncChangeEvent] = page.additions.map { .upsert($0) }
                events.append(contentsOf: page.deletions.map { .delete($0) })
                if !events.isEmpty {
                    let written = try await outbox.append(events, lane: lane)
                    if lane == .backfill {
                        // Only actually-written events count toward the
                        // high-water mark: crash-replay pages dedupe to zero.
                        backfillPending += written
                    }
                }
                if !page.isFull, !isCaughtUp {
                    isCaughtUp = true
                    backfillingMetrics.remove(metric)
                }
                // Checkpoint advance happens only after the page's changes
                // are durably recorded: a crash before this line replays
                // the page (harmlessly — events dedupe).
                anchorData = page.anchorData
                try await stateStore.save(CategoryCheckpoint(
                    scope: scope,
                    anchorData: anchorData,
                    updatedAt: now(),
                    isCaughtUp: isCaughtUp
                ))
                if !page.isFull {
                    break
                }
                // A full page means more changes may follow; the page budget
                // bounds this run and the persisted checkpoint lets the next
                // run resume mid-stream.
                //
                // Ending on a full page also re-arms the catch-up chain: a
                // deep backfill (All records) then converges pass after pass
                // in one app-open instead of waiting for the next external
                // trigger. Capacity pauses and delivery backoff still bound
                // the chain naturally.
                if pageLoopIndex == BackgroundSyncLimits.pagesPerCategoryPerPass - 1 {
                    needsCatchUp = true
                }
                // Historical reading yields to delivery at the high-water
                // mark without blocking later live categories in this pass.
                if !isCaughtUp, backfillPending >= backfillHighWater {
                    isBackfillThrottled = true
                    break
                }
            }

            guard isCurrent(generation) else { return }
            backfillPending = ((try? await outbox.laneCounts())?.backfill) ?? backfillPending
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
            } catch let cancellation as CancellationError {
                // A deliberate stop — background-task expiration, a purge —
                // is not a destination fault. Recording it as a failed
                // attempt would inflate the backoff and report a failure that
                // never happened; the pass's own cancellation handling owns
                // the message.
                throw cancellation
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
                    // Nothing is scheduled any more: showing the retry that
                    // was armed before would be a promise the engine will
                    // not keep.
                    nextRetryAt = nil
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
            nextRetryAt = nil
            lastStatusMessage = reason.userMessage
        case .deferred(let detail):
            retryState.nextAttemptAt = now().addingTimeInterval(60)
            await stateStore.saveRetryState(retryState)
            nextRetryAt = retryState.nextAttemptAt
            lastStatusMessage = AutomaticSyncPauseReason.deferred(detail).userMessage
        }
    }

    private func refreshPendingCount() async {
        let counts = (try? await outbox.laneCounts()) ?? (live: 0, backfill: 0)
        backfillPendingCount = counts.backfill
        pendingCount = counts.live + counts.backfill
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
        // The retry belonged to the queue being discarded.
        nextRetryAt = nil
        isBackfillThrottled = false
        backfillingMetrics = []
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
    private func discardMismatchedQueue(generation: Int) async -> Bool {
        let pending = (try? await outbox.pendingCount()) ?? 0
        guard pending > 0 else { return false }
        guard await stateStore.loadPendingScope() != destination else { return false }
        await outbox.removeAll()
        await stateStore.clearAllCheckpoints()
        await stateStore.clearPendingScope()
        await stateStore.saveRetryState(.initial)
        await refreshPendingCount()
        nextRetryAt = nil
        isBackfillThrottled = false
        backfillingMetrics = []
        discardedWorkNotice = "\(pending) queued change(s) were discarded because they were captured for a different destination. They will never be sent anywhere else."
        // The fact is recorded unconditionally — a user must not silently
        // lose queued health data — but the visible line is only this pass's
        // to write while it is still the current decision, matching the
        // destination purge.
        if isCurrent(generation) {
            lastStatusMessage = discardedWorkNotice
        }
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

    private struct ConfigurationClaim {
        let generation: Int
        /// Whether anything the engine acts on actually differs. The UI
        /// re-reports identical values on unrelated renders, and that must
        /// neither cancel work the user just asked for nor churn observation.
        let isNew: Bool
    }

    /// Claims a new generation only when the configuration actually differs
    /// from the last one reported.
    private func claimConfigurationIfChanged(
        destination: String,
        token: String?,
        metrics: Set<HealthMetric>
    ) -> ConfigurationClaim {
        let new = ConfigurationSnapshot(destination: destination, token: token, metrics: metrics)
        guard new != latestConfiguration else {
            return ConfigurationClaim(generation: configurationGeneration, isNew: false)
        }
        latestConfiguration = new
        configurationGeneration += 1
        return ConfigurationClaim(generation: configurationGeneration, isNew: true)
    }

    // MARK: - Classification

    static func classify(_ error: Error) -> DeliveryFailureClassification {
        // Unreachable from the delivery path since cancellation is rethrown
        // before classification; kept so a future caller cannot silently turn
        // a cancellation into an actionable destination failure.
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
        if error is CocoaError {
            // Storage failures during a pass are treated as deferred work:
            // the common cause is file protection while the device is
            // locked; anything else is retried with backoff and surfaced.
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
