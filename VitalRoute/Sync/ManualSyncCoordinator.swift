import Foundation
import Observation

/// Bounds for one manual sync. Upload batching and per-page queries keep
/// both HealthKit work and request payloads bounded; a run that reaches a
/// budget is reported as a resumable backfill in progress, never as a
/// dead-end failure, because the cursor it saved lets the next sync
/// continue exactly where this one stopped.
enum SyncLimits {
    static let recordsPerUploadBatch = 200
    static let healthQueryPageSize = 500
    /// Pages per category one manual run may read. Generous on purpose —
    /// memory is bounded by the page size, not the total, and the run can
    /// be cancelled — but finite, so one tap cannot spin unbounded. 400
    /// pages × 500 records = 200,000 records per category per run.
    static let manualPagesPerMetricRun = 400
    /// Wall-clock bound for one manual run, so a slow link cannot hold the
    /// shared work gate (background sync waits behind it) for unbounded
    /// minutes. Hitting it reports the same resumable backfill state as the
    /// page budget; progress is saved either way.
    static let maxManualRunSeconds: TimeInterval = 180
}

/// Manual-path failures that need stable, honest user copy.
enum ManualSyncError: LocalizedError, Equatable {
    /// The source kept returning a full page without advancing the cursor;
    /// continuing would re-send the same page forever, so the run stops
    /// with delivered work intact.
    case cursorCannotAdvance
    case progressNotSaved

    var errorDescription: String? {
        switch self {
        case .cursorCannotAdvance:
            return "Sync stopped: this history could not be read past the last delivered page. The records already delivered were accepted; try a shorter history depth."
        case .progressNotSaved:
            return "Sync stopped: progress could not be saved on this device. The records already delivered were accepted; try again."
        }
    }
}

/// Everything one operation needs, captured when it starts so configuration
/// changes (new endpoint, replaced credential, changed selection) cannot
/// redirect a sync that is already underway.
struct SyncPlan: Equatable {
    let endpoint: URL
    let bearerToken: String
    let metrics: [HealthMetric]
}

/// Live counts for progress and outcome reporting. Nothing here is health
/// data — only record counts.
struct SyncSummary: Equatable {
    var recordsFound = 0
    var recordsByMetric: [HealthMetric: Int] = [:]
    var batchesPlanned = 0
    var batchesDelivered = 0
    var acceptedRecords = 0
    var duplicateRecords = 0
    /// Records the receiver refused to store because a tombstone exists
    /// (the sample was deleted through the automatic change stream before
    /// this manual batch arrived). Accounted for, but not stored.
    var supersededRecords = 0
    /// Records read from HealthKit but not sent because they exceed the
    /// receiver's structural limits (oversized metadata, non-finite
    /// values, …). They can never be delivered, so retrying them would
    /// poison their whole batch forever; they are skipped and surfaced
    /// instead.
    var skippedRecords = 0

    var deliveredRecords: Int {
        acceptedRecords + duplicateRecords + supersededRecords
    }

    /// Per-category counts for outcome copy, in catalog order.
    var breakdownText: String {
        MetricCatalog.selectableMetrics
            .compactMap { descriptor in
                recordsByMetric[descriptor.metric].map { "\(descriptor.displayName) \($0)" }
            }
            .joined(separator: " · ")
    }
}

enum SyncResult: Equatable {
    case completed
    /// The run delivered and acknowledged everything it read, but at least
    /// one category still has history pending behind the per-run page
    /// budget. Progress is saved; the next sync resumes from the cursor —
    /// this is a state to continue, not a failure to fix.
    case backfilling(metrics: Set<HealthMetric>)
    case failed(message: String)
    case cancelled
}

struct SyncOutcome: Equatable {
    let startedAt: Date
    let finishedAt: Date
    let result: SyncResult
    var summary = SyncSummary()
}

enum SyncPhase: Equatable {
    case idle
    case authorizing
    case readingHealthData
    /// `totalBatches` is 0 while streaming pages (the total is not known
    /// until the end); the progress copy renders that as "batch N".
    case uploading(batch: Int, totalBatches: Int)
}

/// Persisted record of the last fully successful sync (counts and a
/// timestamp only; no health data).
struct LastSyncInfo: Equatable, Codable {
    let finishedAt: Date
    let deliveredRecords: Int
    let acceptedRecords: Int
    let duplicateRecords: Int
    var supersededRecords: Int = 0

    private enum CodingKeys: String, CodingKey {
        case finishedAt, deliveredRecords, acceptedRecords, duplicateRecords, supersededRecords
    }

    init(finishedAt: Date, deliveredRecords: Int, acceptedRecords: Int, duplicateRecords: Int, supersededRecords: Int = 0) {
        self.finishedAt = finishedAt
        self.deliveredRecords = deliveredRecords
        self.acceptedRecords = acceptedRecords
        self.duplicateRecords = duplicateRecords
        self.supersededRecords = supersededRecords
    }

    /// `supersededRecords` was added after the first releases of this
    /// struct; values persisted before it decode as zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        deliveredRecords = try container.decode(Int.self, forKey: .deliveredRecords)
        acceptedRecords = try container.decode(Int.self, forKey: .acceptedRecords)
        duplicateRecords = try container.decode(Int.self, forKey: .duplicateRecords)
        supersededRecords = try container.decodeIfPresent(Int.self, forKey: .supersededRecords) ?? 0
    }
}

/// Drives foreground, user-initiated syncs: authorize for the selected
/// categories, read from the configured history window, upload in batches,
/// and report honest progress, partial, backfilling, and cancelled states.
///
/// Reading is resumable: each category advances through additions-only
/// anchored pages, and the page's cursor is persisted only after its
/// records have been acknowledged. A large historical window therefore
/// converges across successive syncs — deepening the configured history
/// starts a fresh backfill that continues automatically run after run
/// instead of failing on an oversized read. Deletions are not part of the
/// manual path; they belong to the automatic change stream.
///
/// The coordinator never starts work on its own — saving configuration,
/// opening the app, or refreshing the dashboard must not upload anything.
@MainActor
@Observable
final class ManualSyncCoordinator {
    @ObservationIgnored private let healthData: any HealthDataProviding
    @ObservationIgnored private let client: any DestinationClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateStore: SyncStateStore
    @ObservationIgnored private static let lastSyncStorageKey = "sync.lastSuccessful"

    private(set) var phase: SyncPhase = .idle
    private(set) var currentSummary = SyncSummary()
    private(set) var lastOutcome: SyncOutcome?
    private(set) var lastSuccessfulSync: LastSyncInfo?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// Shared with the automatic engine: the single serialization boundary
    /// that keeps manual and background work from racing checkpoints or
    /// duplicating active uploads.
    @ObservationIgnored private let workGate: SyncWorkGate

    init(
        healthData: any HealthDataProviding,
        client: any DestinationClient,
        stateStore: SyncStateStore,
        defaults: UserDefaults = .standard,
        workGate: SyncWorkGate = SyncWorkGate()
    ) {
        self.healthData = healthData
        self.client = client
        self.stateStore = stateStore
        self.defaults = defaults
        self.workGate = workGate
        lastSuccessfulSync = Self.loadLastSync(from: defaults)
    }

    /// Observable in-flight state.
    ///
    /// `syncTask` is observation-ignored, so a computed `isSyncing` over it
    /// registers no Observation dependency; a view reading it never
    /// updates. That matters now that a manual sync can wait behind an
    /// automatic pass: the wait is real, and the screen has to show it and
    /// offer the cancel.
    private(set) var isSyncing = false

    /// Starts a sync from the current configuration. All inputs are captured
    /// into the plan immediately; overlapping calls are ignored while a sync
    /// is in flight.
    func startSync(endpoint: String, token: String?, metrics: Set<HealthMetric>, now: Date = Date()) {
        guard syncTask == nil else {
            return
        }

        let plan: SyncPlan
        let windowStart: Date
        do {
            let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedToken.isEmpty else {
                recordPreflightFailure("Add the API key for this destination before syncing.")
                return
            }
            let configuration = try DestinationConfiguration(endpoint: endpoint)
            guard !metrics.isEmpty else {
                recordPreflightFailure("Select at least one category in Health Data before syncing.")
                return
            }
            plan = SyncPlan(
                endpoint: configuration.endpoint,
                bearerToken: trimmedToken,
                metrics: MetricCatalog.selectableMetrics
                    .map(\.metric)
                    .filter { metrics.contains($0) }
            )
            // Captured with the plan so the window start is one decision:
            // configuration captured at start time, not whenever the gate
            // hands over.
            windowStart = BackfillDepth.stored(in: defaults)
                .windowStart(from: now, calendar: Calendar.current)
        } catch {
            recordPreflightFailure(
                "The saved destination is not usable: \(error.localizedDescription)"
            )
            return
        }

        let gate = workGate
        // Captured before the task so a cancellation while queued can report
        // the start the user actually experienced.
        let startedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            // The in-flight marker is cleared here rather than inside
            // `runSync`: a cancellation that lands while this task is still
            // queued behind the gate makes `gate.run` throw before `runSync`
            // is ever entered, and an uncleared marker reads as a permanent
            // "syncing" state that also blocks every later start.
            defer {
                self.syncTask = nil
                self.isSyncing = false
                self.phase = .idle
            }
            // Serialized with automatic sync: the whole manual operation
            // (query + upload) holds the gate.
            do {
                try await gate.run { @MainActor [weak self] () throws -> Void in
                    try await self?.runSync(plan: plan, startedAt: startedAt, windowStart: windowStart)
                }
            } catch is CancellationError {
                // Cancelled while queued: `runSync` was never entered, so it
                // could not record the stop itself. Without this the outcome
                // card would keep showing the previous run's result.
                self.lastOutcome = SyncOutcome(
                    startedAt: startedAt,
                    finishedAt: Date(),
                    result: .cancelled
                )
            } catch {
                // runSync handles its own failures; only cancellation is
                // expected to escape the gate wrapper. Anything else is a
                // bug worth surfacing in debug builds rather than losing.
                assertionFailure("ManualSyncCoordinator: unexpected gate error: \(error)")
            }
        }
        syncTask = task
        isSyncing = true
    }

    func cancelSync() {
        syncTask?.cancel()
    }

    private func recordPreflightFailure(_ message: String) {
        lastOutcome = SyncOutcome(
            startedAt: Date(),
            finishedAt: Date(),
            result: .failed(message: message)
        )
    }

    private func runSync(plan: SyncPlan, startedAt: Date, windowStart: Date) async throws {
        var summary = SyncSummary()
        currentSummary = summary
        phase = .authorizing

        do {
            try await healthData.requestReadAuthorization(for: Set(plan.metrics))

            // The depth decides the CANDIDATE window; the store freezes the
            // actual window per (category, depth, destination) on first
            // mint, so cursors stay valid tap after tap regardless of the
            // wall clock — the same fixed-predicate rule as scopes.
            let depth = BackfillDepth.stored(in: defaults)
            let destination = plan.endpoint.absoluteString
            let authorization = DestinationAuthorization(bearerToken: plan.bearerToken)
            // The budget starts when the gate hands over, not when the tap
            // happened: a long wait behind an automatic pass must not
            // consume the reading budget.
            let runDeadline = Date().addingTimeInterval(SyncLimits.maxManualRunSeconds)

            phase = .readingHealthData
            var backfilling: Set<HealthMetric> = []
            for metric in plan.metrics {
                try Task.checkCancellation()
                let metricWindow: Date
                do {
                    metricWindow = try await stateStore.manualWindowStart(
                        destination: destination,
                        metric: metric,
                        depth: depth,
                        candidate: windowStart
                    )
                } catch {
                    throw ManualSyncError.progressNotSaved
                }
                if try await syncMetric(
                    metric, plan: plan, destination: destination,
                    windowStart: metricWindow, authorization: authorization,
                    runDeadline: runDeadline,
                    summary: &summary
                ) {
                    backfilling.insert(metric)
                }
            }

            let outcome = SyncOutcome(
                startedAt: startedAt,
                finishedAt: Date(),
                result: backfilling.isEmpty ? .completed : .backfilling(metrics: backfilling),
                summary: summary
            )
            lastOutcome = outcome
            // A backfill still in progress delivered only part of the
            // history, so it must not update the "last successful sync"
            // marker; its progress lives in the saved cursors.
            if case .completed = outcome.result {
                let info = LastSyncInfo(
                    finishedAt: outcome.finishedAt,
                    deliveredRecords: summary.deliveredRecords,
                    acceptedRecords: summary.acceptedRecords,
                    duplicateRecords: summary.duplicateRecords,
                    supersededRecords: summary.supersededRecords
                )
                lastSuccessfulSync = info
                persistLastSync(info)
            }
        } catch is CancellationError {
            lastOutcome = SyncOutcome(
                startedAt: startedAt,
                finishedAt: Date(),
                result: .cancelled,
                summary: summary
            )
        } catch {
            lastOutcome = SyncOutcome(
                startedAt: startedAt,
                finishedAt: Date(),
                result: .failed(message: Self.failureMessage(for: error)),
                summary: summary
            )
        }
    }

    /// Streams one category: anchored addition pages, each page delivered
    /// and acknowledged before its cursor is saved. Returns true when the
    /// per-run page budget ended the category with more history pending —
    /// a resumable backfill state, not an error.
    private func syncMetric(
        _ metric: HealthMetric,
        plan: SyncPlan,
        destination: String,
        windowStart: Date,
        authorization: DestinationAuthorization,
        runDeadline: Date,
        summary: inout SyncSummary
    ) async throws -> Bool {
        let savedCursor = await stateStore.manualCursor(
            destination: destination, metric: metric, windowStart: windowStart
        )
        var anchorData = savedCursor?.anchorData

        for pageRead in 0..<SyncLimits.manualPagesPerMetricRun {
            try Task.checkCancellation()
            if Date() >= runDeadline {
                // Out of wall clock: same resumable state as the page
                // budget, with everything acknowledged so far checkpointed.
                phase = .readingHealthData
                return true
            }
            let page: HealthExportPage
            do {
                page = try await healthData.exportPage(
                    for: metric,
                    since: anchorData,
                    windowStart: windowStart,
                    limit: SyncLimits.healthQueryPageSize
                )
            } catch let error as HealthKitServiceError where error == .corruptedAnchor && anchorData != nil {
                // The saved cursor is unreadable: drop it and re-read the
                // window from its start, exactly like the change stream
                // rebuilds its checkpoint. The receiver dedupes everything
                // that was already acknowledged.
                anchorData = nil
                do {
                    try await stateStore.saveManualCursor(ManualExportCursor(
                        destination: destination,
                        metric: metric,
                        windowStart: windowStart,
                        anchorData: nil,
                        updatedAt: Date()
                    ))
                } catch {
                    throw ManualSyncError.progressNotSaved
                }
                continue
            }

            summary.recordsFound += page.records.count
            summary.recordsByMetric[metric, default: 0] += page.records.count
            currentSummary = summary

            // Deliver this page before its cursor moves: an acknowledged
            // page can never be lost, and an undelivered one is re-read on
            // the next sync (the receiver keeps one copy of each record).
            // Manual sync shares the automatic path's single v3 operation:
            // an additions-only change batch.
            let sendableRecords = page.records.filter(RecordWireLimits.isTransmittable)
            let skipped = page.records.count - sendableRecords.count
            if skipped > 0 {
                // A record the receiver would always reject must not poison
                // its batch: skipping it (with the cursor advancing past it)
                // is the only way this category keeps syncing.
                summary.skippedRecords += skipped
                currentSummary = summary
            }
            let batches = sendableRecords
                .map(SyncChangeEvent.upsert)
                .batchedForDelivery(maxCount: SyncLimits.recordsPerUploadBatch)
            summary.batchesPlanned += batches.count
            for batch in batches {
                try Task.checkCancellation()
                phase = .uploading(
                    batch: summary.batchesDelivered + 1,
                    totalBatches: 0 // streaming: the total is not known yet
                )
                let acknowledgment = try await client.sendChanges(
                    batch,
                    batchID: UUID(),
                    to: plan.endpoint,
                    authorization: authorization
                )
                summary.batchesDelivered += 1
                summary.acceptedRecords += acknowledgment.accepted
                summary.duplicateRecords += acknowledgment.duplicates
                summary.supersededRecords += acknowledgment.superseded
                currentSummary = summary
            }

            // A full page that did not advance the cursor would repeat
            // forever; stop honestly with the delivered work intact.
            if page.isFull, page.anchorData == anchorData, !page.records.isEmpty {
                throw ManualSyncError.cursorCannotAdvance
            }

            // Advance the cursor only after every batch of this page was
            // acknowledged. A failure above leaves the previous cursor, so
            // the next sync resumes at this page's start.
            anchorData = page.anchorData
            do {
                try await stateStore.saveManualCursor(ManualExportCursor(
                    destination: destination,
                    metric: metric,
                    windowStart: windowStart,
                    anchorData: anchorData,
                    updatedAt: Date()
                ))
            } catch {
                // Stopping without saving is the safe direction: the next
                // sync re-reads this page and the receiver dedupes.
                throw ManualSyncError.progressNotSaved
            }

            if !page.isFull {
                // Caught up: the category has no more history pending.
                phase = .readingHealthData
                return false
            }
            if pageRead == SyncLimits.manualPagesPerMetricRun - 1 {
                // Budget exhausted with more history pending: resumable
                // backfill state for this category.
                phase = .readingHealthData
                return true
            }
        }
        // Unreachable: the loop returns from both exits above.
        return false
    }

    /// Maps errors to user-facing text. Messages never contain the endpoint,
    /// token, or health-record contents.
    private static func failureMessage(for error: Error) -> String {
        if let manualError = error as? ManualSyncError {
            return manualError.errorDescription ?? "Sync stopped."
        }
        if let clientError = error as? DestinationClientError {
            return clientError.localizedDescription
        }
        if let healthError = error as? HealthKitServiceError {
            return healthError.localizedDescription
        }
        if let configurationError = error as? DestinationConfigurationError {
            return configurationError.localizedDescription
        }
        return "Sync stopped: \(error.localizedDescription)"
    }

    private func persistLastSync(_ info: LastSyncInfo) {
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: Self.lastSyncStorageKey)
        }
    }

    private static func loadLastSync(from defaults: UserDefaults) -> LastSyncInfo? {
        guard let data = defaults.data(forKey: lastSyncStorageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(LastSyncInfo.self, from: data)
    }
}

private extension Array where Element == SyncChangeEvent {
    /// Delivery batches bounded by both count and the same byte budget the
    /// outbox path enforces, so a series-chunk-heavy page cannot exceed the
    /// receiver's body limit (which the receiver rejects atomically, and a
    /// resumable cursor would then retry forever). A single element larger
    /// than the whole budget still ships alone — a legal batch of one.
    func batchedForDelivery(maxCount: Int) -> [[Element]] {
        precondition(maxCount > 0)
        let encoder = JSONEncoder()
        var batches: [[Element]] = []
        var current: [Element] = []
        var bytes = 0
        for element in self {
            let size = (try? encoder.encode(element))?.count ?? Outbox.unknownFileSizeEstimate
            if current.count == maxCount
                || (!current.isEmpty && bytes + size > Outbox.deliveryBatchByteLimit) {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(element)
            bytes += size
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }
}
