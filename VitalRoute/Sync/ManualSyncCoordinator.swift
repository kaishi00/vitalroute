import Foundation
import Observation

/// Bounds for one manual sync. Query paging and upload batching keep both
/// HealthKit work and request payloads bounded; hitting a bound is surfaced
/// as truncation, never as silent success.
enum SyncLimits {
    static let windowDays = 7
    static let recordsPerUploadBatch = 200
    static let healthQueryPageSize = 500
    static let maxPagesPerMetric = 40
}

/// Everything one operation needs, captured when it starts so configuration
/// changes (new endpoint, replaced credential, changed selection) cannot
/// redirect a sync that is already underway.
struct SyncPlan: Equatable {
    let endpoint: URL
    let bearerToken: String
    let metrics: [HealthMetric]
    let windowStart: Date
    let windowEnd: Date
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

    var deliveredRecords: Int {
        acceptedRecords + duplicateRecords
    }

    /// Per-category counts for outcome copy, in catalog order.
    var breakdownText: String {
        HealthMetric.allCases
            .compactMap { metric in recordsByMetric[metric].map { "\(metric.displayName) \($0)" } }
            .joined(separator: " · ")
    }
}

enum SyncResult: Equatable {
    case completed
    case truncated(metrics: Set<HealthMetric>)
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
    case uploading(batch: Int, totalBatches: Int)
}

/// Persisted record of the last fully successful sync (counts and a
/// timestamp only; no health data).
struct LastSyncInfo: Equatable, Codable {
    let finishedAt: Date
    let deliveredRecords: Int
    let acceptedRecords: Int
    let duplicateRecords: Int
}

/// Drives foreground, user-initiated syncs: authorize for the selected
/// categories, read the full seven-day window, upload in batches, and report
/// honest progress, partial, truncated, and cancelled states.
///
/// The coordinator never starts work on its own — saving configuration,
/// opening the app, or refreshing the dashboard must not upload anything.
@MainActor
@Observable
final class ManualSyncCoordinator {
    @ObservationIgnored private let healthData: any HealthDataProviding
    @ObservationIgnored private let client: any DestinationClient
    @ObservationIgnored private let defaults: UserDefaults
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
        defaults: UserDefaults = .standard,
        workGate: SyncWorkGate = SyncWorkGate()
    ) {
        self.healthData = healthData
        self.client = client
        self.defaults = defaults
        self.workGate = workGate
        lastSuccessfulSync = Self.loadLastSync(from: defaults)
    }

    var isSyncing: Bool {
        syncTask != nil
    }

    /// Starts a sync from the current configuration. All inputs are captured
    /// into the plan immediately; overlapping calls are ignored while a sync
    /// is in flight.
    func startSync(endpoint: String, token: String?, metrics: Set<HealthMetric>, now: Date = Date()) {
        guard syncTask == nil else {
            return
        }

        let plan: SyncPlan
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
            let windowStart = Calendar.current.date(
                byAdding: .day,
                value: -SyncLimits.windowDays,
                to: now
            ) ?? now
            plan = SyncPlan(
                endpoint: configuration.endpoint,
                bearerToken: trimmedToken,
                metrics: HealthMetric.allCases.filter { metrics.contains($0) },
                windowStart: windowStart,
                windowEnd: now
            )
        } catch {
            recordPreflightFailure(
                "The saved destination is not usable: \(error.localizedDescription)"
            )
            return
        }

        let gate = workGate
        let task = Task { [weak self] in
            guard let self else { return }
            // The in-flight marker is cleared here rather than inside
            // `runSync`: a cancellation that lands while this task is still
            // queued behind the gate makes `gate.run` throw before `runSync`
            // is ever entered, and an uncleared marker reads as a permanent
            // "syncing" state that also blocks every later start.
            defer {
                self.syncTask = nil
                self.phase = .idle
            }
            // Serialized with automatic sync: the whole manual operation
            // (query + upload) holds the gate.
            do {
                try await gate.run { @MainActor [weak self] () throws -> Void in
                    try await self?.runSync(plan: plan)
                }
            } catch {
                // runSync handles its own failures; only cancellation can
                // escape the gate wrapper.
            }
        }
        syncTask = task
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

    private func runSync(plan: SyncPlan) async throws {
        let startedAt = Date()
        var summary = SyncSummary()
        currentSummary = summary
        phase = .authorizing

        do {
            try await healthData.requestReadAuthorization(for: Set(plan.metrics))

            phase = .readingHealthData
            let export = try await healthData.exportRecords(
                since: plan.windowStart,
                through: plan.windowEnd,
                metrics: Set(plan.metrics)
            )
            summary.recordsFound = export.records.count
            summary.recordsByMetric = Dictionary(grouping: export.records, by: \.metric).mapValues(\.count)
            currentSummary = summary

            let batches = export.records.batched(into: SyncLimits.recordsPerUploadBatch)
            summary.batchesPlanned = batches.count
            currentSummary = summary

            let authorization = DestinationAuthorization(bearerToken: plan.bearerToken)
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                phase = .uploading(batch: index + 1, totalBatches: batches.count)
                let payload = SyncPayload(records: batch)
                let acknowledgment = try await client.send(
                    payload,
                    to: plan.endpoint,
                    authorization: authorization
                )
                summary.batchesDelivered += 1
                summary.acceptedRecords += acknowledgment.accepted
                summary.duplicateRecords += acknowledgment.duplicates
                currentSummary = summary
            }

            let outcome = SyncOutcome(
                startedAt: startedAt,
                finishedAt: Date(),
                result: export.isTruncated ? .truncated(metrics: export.truncatedMetrics) : .completed,
                summary: summary
            )
            lastOutcome = outcome
            // A truncated sync delivered only part of the window, so it must
            // not update the "last successful sync" marker.
            if case .completed = outcome.result {
                let info = LastSyncInfo(
                    finishedAt: outcome.finishedAt,
                    deliveredRecords: summary.deliveredRecords,
                    acceptedRecords: summary.acceptedRecords,
                    duplicateRecords: summary.duplicateRecords
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

    /// Maps errors to user-facing text. Messages never contain the endpoint,
    /// token, or health-record contents.
    private static func failureMessage(for error: Error) -> String {
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

private extension Array {
    func batched(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
