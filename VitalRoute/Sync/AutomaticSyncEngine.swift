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
    case absorbedCatchUp
}

enum AutomaticSyncEnableResult: Equatable {
    case enabled
    case failed(message: String)
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
    /// production sets the BGTaskScheduler-backed closure.
    @ObservationIgnored var scheduleBackgroundRetry: (@Sendable (TimeInterval) -> Void)?

    private(set) var mode: AutomaticSyncMode = .disabled
    private(set) var pendingCount = 0
    private(set) var lastDeliveryAt: Date?
    private(set) var lastCheckAt: Date?
    private(set) var lastStatusMessage: String?
    private(set) var isRunning = false
    private(set) var nextRetryAt: Date?

    @ObservationIgnored private var activeRunTask: Task<Void, Never>?
    @ObservationIgnored private var needsCatchUp = false
    /// Configuration snapshot; never carried across a destination change.
    @ObservationIgnored private var destination = ""
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var selectedMetrics: Set<HealthMetric> = []
    @ObservationIgnored private static let enabledFlagKey = "automaticSync.enabled"

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
            return .failed(message: AutomaticSyncPauseReason.selectionEmpty.userMessage)
        }
        let trimmedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedToken.isEmpty else {
            return .failed(message: AutomaticSyncPauseReason.credentialMissing.userMessage)
        }
        let configuration: DestinationConfiguration
        do {
            configuration = try DestinationConfiguration(endpoint: endpoint)
        } catch {
            return .failed(message: "The saved destination is not usable: \(error.localizedDescription)")
        }

        // Foreground HealthKit authorization: background work must never
        // present an authorization sheet.
        do {
            try await healthData.requestReadAuthorization(for: metrics)
        } catch {
            return .failed(message: error.localizedDescription)
        }

        // Capability check: automatic sync requires deletion support.
        do {
            let health = try await client.testConnection(
                to: configuration.endpoint,
                authorization: DestinationAuthorization(bearerToken: trimmedToken)
            )
            guard health.supportsDeletions else {
                return .failed(
                    message: "The destination receiver does not support deletions (contract v2). Update it to a v2 receiver, then try again. Manual sync keeps working."
                )
            }
        } catch {
            return .failed(message: "Could not verify the destination: \(error.localizedDescription)")
        }

        destination = configuration.endpoint.absoluteString
        token = trimmedToken
        selectedMetrics = metrics
        defaults.set(true, forKey: Self.enabledFlagKey)
        mode = .active
        lastStatusMessage = nil

        do {
            try await healthData.observeChanges(for: metrics) { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.observerFired() }
            }
        } catch {
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
        }

        startPass(trigger: .enablement)
        return .enabled
    }

    /// Disables automatic sync. Work stops; queued events and checkpoints
    /// are kept so re-enabling resumes where it left off (nothing is ever
    /// re-pointed to a different destination — that is `configurationChanged`).
    func disable() {
        guard mode != .disabled else { return }
        activeRunTask?.cancel()
        Task { await healthData.stopObservingChanges() }
        defaults.set(false, forKey: Self.enabledFlagKey)
        mode = .disabled
        lastStatusMessage = "Automatic sync is off."
    }

    /// Called at every supported app launch (app-level, not screen-level)
    /// with the current persisted configuration.
    func restoreOnLaunch(
        destination endpoint: String,
        token bearerToken: String?,
        metrics: Set<HealthMetric>
    ) async {
        guard mode != .disabled else { return }
        destination = endpoint
        token = bearerToken
        selectedMetrics = metrics
        if let reason = unsatisfiedPrerequisite() {
            mode = .paused(reason)
            return
        }
        do {
            try await healthData.observeChanges(for: metrics) { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.observerFired() }
            }
        } catch {
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
            return
        }
        startPass(trigger: .foregroundCatchUp)
    }

    /// Configuration-change hook. Enforces the destination-identity policy:
    /// pending work and checkpoints are never moved to a different
    /// recipient; a destination change disables automatic sync and discards
    /// the previous destination's pending work with a visible notice.
    func configurationChanged(
        destination newDestination: String,
        token newToken: String?,
        metrics newMetrics: Set<HealthMetric>
    ) async {
        let previousDestination = destination
        let previousMetrics = selectedMetrics

        if mode == .disabled {
            // Track configuration so the first post-enable snapshot is
            // consistent; nothing else to do while off.
            return
        }

        let destinationChanged = previousDestination.isEmpty
            ? false
            : previousDestination != newDestination

        if destinationChanged || newDestination.isEmpty {
            let discarded = (try? await outbox.pendingCount()) ?? 0
            await healthDataStopObserving()
            activeRunTask?.cancel()
            await outbox.removeAll()
            await stateStore.clearAllCheckpoints()
            var retry = await stateStore.loadRetryState()
            retry = .initial
            await stateStore.saveRetryState(retry)
            defaults.set(false, forKey: Self.enabledFlagKey)
            mode = .disabled
            lastStatusMessage = discarded > 0
                ? "Automatic sync turned off because the destination changed. \(discarded) pending change(s) for the previous destination were discarded — they were never sent anywhere else."
                : "Automatic sync turned off because the destination changed."
            return
        }

        destination = newDestination
        token = newToken
        selectedMetrics = newMetrics

        // Categories that were disabled must never upload their queued data.
        for removed in previousMetrics where !newMetrics.contains(removed) {
            await outbox.removeCategory(removed)
            await stateStore.clearCheckpoint(for: removed)
        }

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
            try await healthData.observeChanges(for: newMetrics) { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.observerFired() }
            }
        } catch {
            mode = .paused(.deferred("observers could not be registered: \(error.localizedDescription)"))
            return
        }
        if case .paused(let reason) = mode, reason.isAutoRecoverable {
            mode = .active
        }
        startPass(trigger: .foregroundCatchUp)
    }

    private func healthDataStopObserving() async {
        await healthData.stopObservingChanges()
    }

    /// The observer handler: a trigger, not a result. The callback itself
    /// stays trivial; bounded work happens in the single-flight pass.
    private func observerFired() {
        startPass(trigger: .observer)
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
    /// regardless, so this is best-effort only.
    func waitUntilIdle(timeout: TimeInterval = 25) async {
        let deadline = now() + timeout
        while isRunning && now() < deadline {
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
        guard mode != .disabled else { return }
        guard activeRunTask == nil else {
            // Absorb triggers that arrive during a run: one catch-up pass
            // after the current one finishes.
            needsCatchUp = true
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPass(trigger: trigger)
            self.activeRunTask = nil
            if self.needsCatchUp, self.isEnabled {
                self.needsCatchUp = false
                self.startPass(trigger: .absorbedCatchUp)
            }
        }
        activeRunTask = task
    }

    private func performPass(trigger: AutomaticSyncTrigger) async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await workGate.run { @MainActor [weak self] () throws -> Void in
                try await self?.performPassBody(trigger: trigger)
            }
        } catch is CancellationError {
            lastStatusMessage = "Automatic sync stopped early this run; pending work is kept and will resume."
        } catch {
            await handlePassFailure(error)
        }
        await refreshPendingCount()
        await scheduleRetryIfNeeded()
    }

    private func performPassBody(trigger: AutomaticSyncTrigger) async throws {
        guard mode != .disabled else { return }

        // Pause re-evaluation: auto-recoverable reasons clear when their
        // prerequisite is satisfied again.
        if case .paused(let reason) = mode {
            if !reason.isAutoRecoverable {
                lastStatusMessage = reason.userMessage
                return
            }
            if let stillUnsatisfied = unsatisfiedPrerequisite() {
                mode = .paused(stillUnsatisfied)
                lastStatusMessage = stillUnsatisfied.userMessage
                return
            }
            mode = .active
        } else if let reason = unsatisfiedPrerequisite() {
            mode = .paused(reason)
            lastStatusMessage = reason.userMessage
            return
        }

        let atCapacity = (try? await outbox.isAtCapacity()) ?? false
        if atCapacity {
            // Backpressure: stop capturing, keep draining. The pause is
            // auto-recoverable — once delivery drains below capacity, the
            // next pass resumes queries.
            mode = .paused(.queueAtCapacity)
        } else {
            try await runQueryPass()
        }

        try await deliverPending()
        lastCheckAt = now()
    }

    /// Bounded incremental capture: for every selected category, page
    /// through additions and deletions since the checkpoint, appending to
    /// the outbox *before* advancing the checkpoint.
    private func runQueryPass() async throws {
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
                let page = try await healthData.changePage(
                    for: metric,
                    since: anchorData,
                    windowStart: scope.windowStart,
                    limit: BackgroundSyncLimits.changePageSize
                )
                var events: [SyncChangeEvent] = page.additions.map { .upsert($0) }
                events.append(contentsOf: page.deletions.map { .delete($0) })
                if !events.isEmpty {
                    _ = try await outbox.append(events)
                }
                // Checkpoint advance happens only after the page's changes
                // are durably recorded: a crash before this line replays
                // the page (harmlessly — events dedupe).
                anchorData = page.anchorData
                await stateStore.save(CategoryCheckpoint(
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

            let pending = (try? await outbox.pendingCount()) ?? 0
            if pending >= capacity {
                mode = .paused(.queueAtCapacity)
                return
            }
        }
    }

    /// Bounded delivery: drain the outbox in batches, removing events only
    /// after a reconciled acknowledgment.
    private func deliverPending() async throws {
        guard let endpointURL = URL(string: destination), endpointURL.scheme == "https",
              let token else {
            return
        }
        let authorization = DestinationAuthorization(bearerToken: token)

        var retryState = await stateStore.loadRetryState()
        if let nextAttempt = retryState.nextAttemptAt, nextAttempt > now() {
            nextRetryAt = nextAttempt
            return
        }

        for _ in 0..<BackgroundSyncLimits.maxDeliveryBatchesPerRun {
            try Task.checkCancellation()
            let snapshot = try await outbox.nextBatch()
            pendingCount = snapshot.totalPending
            if snapshot.events.isEmpty {
                break
            }

            do {
                let acknowledgment = try await client.sendChanges(
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
                lastStatusMessage = nil
            } catch {
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

    private func handlePassFailure(_ error: Error) async {
        let classification = Self.classify(error)
        var retryState = await stateStore.loadRetryState()
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

    private func scheduleRetryIfNeeded() async {
        guard mode != .disabled, pendingCount > 0 else { return }
        let retryState = await stateStore.loadRetryState()
        let delay: TimeInterval
        if let next = retryState.nextAttemptAt {
            delay = max(0, next.timeIntervalSince(now()))
        } else {
            delay = 60
        }
        scheduleBackgroundRetry?(delay)
    }

    // MARK: - Classification

    static func classify(_ error: Error) -> DeliveryFailureClassification {
        if error is CancellationError {
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
            case .requestTimedOut, .connectionFailed, .invalidResponse:
                return .transient
            case .serverRejected(let status):
                return status >= 500 ? .transient : .actionable(.protocolFailure("the destination returned HTTP \(status)."))
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
            case .authorizationFailed, .noMetricsRequested:
                return .deferred(healthError.localizedDescription)
            }
        }
        if let cocoaError = error as? CocoaError,
           cocoaError.isFileProtectionError {
            return .deferred("the device is locked and protected storage is unavailable.")
        }
        return .transient
    }

    private func unsatisfiedPrerequisite() -> AutomaticSyncPauseReason? {
        if destination.isEmpty {
            return .destinationMissing
        }
        guard let token, !token.isEmpty else {
            return .credentialMissing
        }
        if selectedMetrics.isEmpty {
            return .selectionEmpty
        }
        return nil
    }
}

private extension CocoaError {
    /// File-protection failures (writes refused while the device is locked)
    /// surface directly or wrapped; both mean deferred work, not an error.
    var isFileProtectionError: Bool {
        if code.rawValue == NSFileWriteFileProtectionError {
            return true
        }
        if let underlying = userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSCocoaErrorDomain
                && underlying.code == NSFileWriteFileProtectionError
        }
        return false
    }
}
