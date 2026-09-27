import Foundation
import os

/// Everything a category checkpoint is bound to: destination identity,
/// category, a generation minted on (re)bootstrap, and the fixed window
/// start of the scope's query predicate. An anchor is only ever reused with
/// the exact predicate it was produced with, so any configuration change
/// mints a new generation instead of moving the checkpoint.
struct CategoryScope: Codable, Equatable {
    let destination: String
    let metric: HealthMetric
    let generation: UUID
    let windowStart: Date

    /// The fixed query definition for this scope: samples that start at or
    /// after the bootstrap moment minus the initial window. Never moves.
    var predicateStart: Date {
        windowStart
    }
}

/// A persisted incremental cursor: the archived anchor of the last page
/// whose changes are durably recorded in the outbox (or acknowledged).
struct CategoryCheckpoint: Codable, Equatable {
    let scope: CategoryScope
    /// Serialized `HKQueryAnchor`; nil until the first page completes.
    let anchorData: Data?
    let updatedAt: Date
    /// False until a read of this scope drains the stream to its head (a
    /// page that is not full). Pages captured before that are historical
    /// backfill; pages after it are live changes, which the outbox delivers
    /// first. Checkpoints written before this flag existed decode as false,
    /// which correctly keeps their remaining pages classified as history.
    var isCaughtUp: Bool

    init(scope: CategoryScope, anchorData: Data?, updatedAt: Date, isCaughtUp: Bool = false) {
        self.scope = scope
        self.anchorData = anchorData
        self.updatedAt = updatedAt
        self.isCaughtUp = isCaughtUp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(CategoryScope.self, forKey: .scope)
        anchorData = try container.decodeIfPresent(Data.self, forKey: .anchorData)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isCaughtUp = try container.decodeIfPresent(Bool.self, forKey: .isCaughtUp) ?? false
    }
}

/// A manual ("Sync Now") export cursor: how far the additions-only export
/// for one (destination, category, window start) identity has been read AND
/// acknowledged. The window start is part of the identity because an anchor
/// is only valid with the exact predicate that produced it — a deeper
/// configured history mints a fresh cursor rather than moving this one, and
/// a shallower choice simply leaves an older, deeper cursor unused on disk
/// (nothing captured is ever discarded). Deletions are not tracked here;
/// they belong to the change stream the automatic engine owns.
struct ManualExportCursor: Codable, Equatable {
    let destination: String
    let metric: HealthMetric
    let windowStart: Date
    var anchorData: Data?
    var updatedAt: Date

    var storageKey: String {
        ManualExportCursor.key(destination: destination, metric: metric, windowStart: windowStart)
    }

    static func key(destination: String, metric: HealthMetric, windowStart: Date) -> String {
        "\(metric.rawValue)|\(Int(windowStart.timeIntervalSince1970))|\(destination)"
    }

    /// The destination component of a minted manual-window key
    /// (`metric|depth|destination`). `maxSplits` keeps everything after the
    /// second separator as one component, so this is the exact inverse of
    /// `key(destination:metric:windowStart:)` for the key's tail.
    static func destination(fromWindowKey key: String) -> String? {
        key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .last
            .map(String.init)
    }
}

/// What a receiver-datastore reconciliation decided. Computed and committed
/// as ONE actor-isolated step, so concurrent sync paths can never interleave
/// an invalidation between another reconciliation's decision and its commit.
enum GenerationReconciliation: Equatable, Sendable {
    /// Same datastore as last time: progress stays exactly as it is.
    case same
    /// No remembered generation and no legacy progress: a fresh setup
    /// adopting the receiver's identity.
    case adopted
    /// A remembered generation differs: the receiver's datastore was reset,
    /// replaced, or rolled back, and progress was invalidated.
    case rebuiltAfterReset
    /// No remembered generation but pre-generation progress existed: legacy
    /// state cannot prove compatibility with a generation-aware receiver,
    /// so it was invalidated and history is re-sent.
    case rebuiltFromLegacyState
}

/// Persisted retry/backoff bookkeeping. Counts and timestamps only.
struct DeliveryRetryState: Codable, Equatable {
    var consecutiveFailures = 0
    var nextAttemptAt: Date?
    var lastFailureIsActionable = false
    var lastFailureMessage: String?
    var lastSuccessAt: Date?

    static let initial = DeliveryRetryState()

    func backoffSeconds(afterFailureCount failures: Int) -> TimeInterval {
        let base: TimeInterval = 60
        let cap: TimeInterval = 24 * 3600
        var delay = base
        for _ in 1..<max(failures, 1) {
            delay *= 2
            if delay >= cap {
                return cap
            }
        }
        return min(delay, cap)
    }
}

/// Durable scopes, checkpoints, and retry state under a data-protected
/// directory. Writes are atomic (temp file + rename); files contain health
/// metadata (anchors, timestamps) — not records — and are excluded from
/// backups.
actor SyncStateStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let protection: FileProtectionType
    private var prepared = false
    /// Avoids rewriting the scope file on every capture pass.
    private var cachedPendingScope: String?

    init(directory: URL, protection: FileProtectionType = .completeUntilFirstUserAuthentication) {
        self.directory = directory.appendingPathComponent("state", isDirectory: true)
        self.protection = protection
    }

    /// Prepares the on-disk layout. Call once before use; callers that write
    /// without loading first reach it through `ensurePrepared()`.
    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        excludeFromBackup(directory)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(".tmp-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        // Set here, not only in ensurePrepared(): `prepareStorage()` calls
        // this directly at launch, and leaving the flag false made every
        // later write redo the directory setup.
        prepared = true
    }

    func loadCheckpoint(for metric: HealthMetric) -> CategoryCheckpoint? {
        guard let data = try? Data(contentsOf: url(for: metric)) else {
            return nil
        }
        return try? decoder.decode(CategoryCheckpoint.self, from: data)
    }

    /// Persists a checkpoint. Call only after the changes it covers are
    /// durably recorded in the outbox or already acknowledged.
    func save(_ checkpoint: CategoryCheckpoint) throws {
        try ensurePrepared()
        let data = try encoder.encode(checkpoint)
        try atomicWrite(data, to: url(for: checkpoint.scope.metric))
    }

    private func ensurePrepared() throws {
        if !prepared {
            try prepare()
            prepared = true
        }
    }

    func clearCheckpoint(for metric: HealthMetric) {
        try? FileManager.default.removeItem(at: url(for: metric))
    }

    func clearAllCheckpoints() {
        for metric in MetricCatalog.metrics.map(\.metric) {
            clearCheckpoint(for: metric)
        }
    }

    // MARK: - Manual export windows

    private var manualWindowsURL: URL { directory.appendingPathComponent("manual-windows.json") }

    /// The FIXED window start for one (category, depth, destination) manual
    /// identity — the exact rule automatic-sync scopes follow: the window is
    /// minted once from the candidate and then never moves, so a cursor
    /// stays valid tap after tap regardless of the wall clock. A candidate
    /// that reaches DEEPER than the minted window (the user deepened the
    /// history) re-mints it, backfilling the older data; anything at or
    /// after the minted start reuses it (unchanged depth resumes, a
    /// shallower depth is simply a different identity).
    func manualWindowStart(
        destination: String,
        metric: HealthMetric,
        depth: BackfillDepth,
        candidate: Date
    ) throws -> Date {
        try ensurePrepared()
        var windows = loadManualWindows()
        let key = "\(metric.rawValue)|\(depth.rawValue)|\(destination)"
        if let minted = windows[key], candidate >= minted {
            return minted
        }
        windows[key] = candidate
        let data = try encoder.encode(windows)
        try atomicWrite(data, to: manualWindowsURL)
        return candidate
    }

    private func loadManualWindows() -> [String: Date] {
        guard let data = try? Data(contentsOf: manualWindowsURL) else {
            return [:]
        }
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    // MARK: - Manual export cursors

    private var manualCursorsURL: URL { directory.appendingPathComponent("manual-cursors.json") }

    /// All persisted manual export cursors, keyed by
    /// `ManualExportCursor.storageKey`.
    func loadManualCursors() -> [String: ManualExportCursor] {
        guard let data = try? Data(contentsOf: manualCursorsURL) else {
            return [:]
        }
        return (try? decoder.decode([String: ManualExportCursor].self, from: data)) ?? [:]
    }

    func manualCursor(destination: String, metric: HealthMetric, windowStart: Date) -> ManualExportCursor? {
        loadManualCursors()[ManualExportCursor.key(destination: destination, metric: metric, windowStart: windowStart)]
    }

    /// Persists one cursor, preserving the others. Call only after the page
    /// the anchor came from has been delivered and acknowledged; write
    /// failures throw so the caller can stop advancing on a cursor it could
    /// not save.
    func saveManualCursor(_ cursor: ManualExportCursor) throws {
        try ensurePrepared()
        var cursors = loadManualCursors()
        cursors[cursor.storageKey] = cursor
        let data = try encoder.encode(cursors)
        try atomicWrite(data, to: manualCursorsURL)
    }

    func loadRetryState() -> DeliveryRetryState {
        guard let data = try? Data(contentsOf: retryURL) else {
            return .initial
        }
        return (try? decoder.decode(DeliveryRetryState.self, from: data)) ?? .initial
    }

    /// Persists backoff bookkeeping. `ensurePrepared()` matters here: retry
    /// state is written before any checkpoint exists (a purge writes
    /// `.initial`), and writing into an absent directory silently discarded
    /// the schedule instead of persisting it.
    ///
    /// Write failures do not throw: this is advisory bookkeeping, not health
    /// data, and losing it degrades to retrying on the default interval
    /// rather than the backed-off one. They are logged rather than dropped
    /// silently, and in the capture path a storage failure that matters is
    /// also surfaced by the throwing checkpoint write alongside this one.
    func saveRetryState(_ state: DeliveryRetryState) {
        do {
            try saveRetryStateThrowing(state)
        } catch {
            // Counts and timestamps only: nothing payload-bearing, and the
            // reason alone.
            Self.logger.info("Retry state not persisted: \(String(describing: error), privacy: .public)")
        }
    }

    /// Throwing twin of `saveRetryState` for the invalidation path, where a
    /// failed clear must stop the reconciliation instead of degrading to
    /// the default interval.
    func saveRetryStateThrowing(_ state: DeliveryRetryState) throws {
        try ensurePrepared()
        let data = try encoder.encode(state)
        try atomicWrite(data, to: retryURL)
    }

    private static let logger = Logger(subsystem: "com.milim.vitalroute", category: "sync-state")

    // MARK: - Pending-work scope

    /// The destination identity the queued changes belong to.
    ///
    /// Pending health data must never become deliverable to a destination it
    /// was not captured for, and that includes a change that happened while
    /// the app was not running. The engine records the destination here when
    /// it arms one and clears it when the queue is discarded, so delivery can
    /// refuse a queue whose owner no longer matches.
    func loadPendingScope() -> String? {
        guard let data = try? Data(contentsOf: pendingScopeURL) else {
            return nil
        }
        return try? decoder.decode(String.self, from: data)
    }

    /// Throws rather than swallowing a write failure: an unwritten marker
    /// would make the next pass read a correctly-attributed queue as foreign
    /// and discard it, so failing the capture is the honest outcome. The
    /// cache is only advanced after a write that succeeded.
    func savePendingScope(_ destination: String) throws {
        guard destination != cachedPendingScope else { return }
        try ensurePrepared()
        let data = try encoder.encode(destination)
        try atomicWrite(data, to: pendingScopeURL)
        cachedPendingScope = destination
    }

    func clearPendingScope() {
        cachedPendingScope = nil
        try? FileManager.default.removeItem(at: pendingScopeURL)
    }

    // MARK: - Receiver datastore generation

    private var receiverGenerationURL: URL {
        directory.appendingPathComponent("receiver-generation.json")
    }

    /// Destination -> the datastore generation that destination last
    /// synchronized with. Keyed by destination so switching between
    /// destinations and back does not read as "the datastore was reset".
    /// A legacy single-binding file (or any undecodable content) decodes as
    /// empty, which degrades to the safe self-healing rebuild.
    private func loadReceiverGenerationBindings() -> [String: UUID] {
        guard let data = try? Data(contentsOf: receiverGenerationURL),
              let bindings = try? decoder.decode([String: UUID].self, from: data) else {
            return [:]
        }
        return bindings
    }

    /// The generation this device last synchronized with for the
    /// destination, or nil when there is none (fresh setup, a cleared
    /// binding, or a binding written only for other destinations).
    func loadReceiverGeneration(destination: String) -> UUID? {
        loadReceiverGenerationBindings()[destination]
    }

    /// Commits one destination's binding, preserving every other
    /// destination's. The production commit path is
    /// `reconcileGeneration(destination:generation:)`, which calls this as
    /// its final step; it is also the seeding primitive for tests.
    func saveReceiverGeneration(destination: String, storeGeneration: UUID) throws {
        try ensurePrepared()
        var bindings = loadReceiverGenerationBindings()
        bindings[destination] = storeGeneration
        try atomicWrite(try encoder.encode(bindings), to: receiverGenerationURL)
    }

    /// Forgets ONE destination's binding (the "Rebuild sync history"
    /// action): the next reconciliation for that destination adopts whatever
    /// the receiver reports and, with progress cleared, re-bootstraps from
    /// the configured window. Other destinations' bindings survive, so
    /// switching destinations and back still does not read as a reset.
    func clearReceiverGeneration(destination: String) {
        var bindings = loadReceiverGenerationBindings()
        guard bindings.removeValue(forKey: destination) != nil else { return }
        do {
            try ensurePrepared()
            try atomicWrite(try encoder.encode(bindings), to: receiverGenerationURL)
        } catch {
            // Advisory: failing to forget a binding is self-healing — the
            // next reconciliation still compares against the receiver and
            // rebuilds on any mismatch.
        }
    }

    /// True when any destination-bound delivery progress exists. The legacy
    /// upgrade case (no remembered generation, but pre-generation cursors/
    /// checkpoints on disk) is detected with this: old state cannot prove
    /// compatibility with a generation-aware receiver, so it must be
    /// invalidated and the history re-sent rather than trusted.
    func hasDeliveryProgress(destination: String) -> Bool {
        if loadManualCursors().values.contains(where: { $0.destination == destination }) {
            return true
        }
        if loadManualWindows().contains(where: { key, _ in
            ManualExportCursor.destination(fromWindowKey: key) == destination
        }) {
            return true
        }
        for metric in MetricCatalog.metrics.map(\.metric) {
            if let checkpoint = loadCheckpoint(for: metric),
               checkpoint.scope.destination == destination {
                return true
            }
        }
        return false
    }

    /// The reconciliation decision and commit, as one actor-isolated,
    /// non-`async` step: load, compare, invalidate, and commit run to
    /// completion with no suspension point, so no concurrent reconciliation
    /// or capture can interleave between this one's decision and its commit.
    ///
    /// Crash-safety ordering: the invalidation's removals are atomic file
    /// operations and the NEW binding is written strictly last. A crash at
    /// any earlier point leaves the old (or absent) binding in place, and
    /// the stale-or-absent binding is exactly what re-triggers this
    /// reconciliation idempotently. The forbidden state - a committed new
    /// generation coexisting with progress earned against the old
    /// datastore - is therefore unreachable.
    ///
    /// Deliberately untouched by the invalidation: the outbox and its
    /// pending scope (queued events remain valid HealthKit facts for this
    /// destination - queued deletions in particular cannot be re-derived
    /// from HealthKit, and re-read additions dedupe at the receiver), the
    /// endpoint, credential, metric selection, backfill depth, and HealthKit
    /// authorization. Retry bookkeeping is a single destination-agnostic
    /// file; clearing it here resets the backoff whenever a rebuild happens
    /// (a reset or legacy state), not on the no-op same-generation path.
    func reconcileGeneration(destination: String, generation: UUID) throws -> GenerationReconciliation {
        let remembered = loadReceiverGeneration(destination: destination)
        if remembered == generation {
            return .same
        }
        let hadLegacyProgress = hasDeliveryProgress(destination: destination)
        if remembered != nil || hadLegacyProgress {
            try invalidateDeliveryProgress(destination: destination)
        }
        // The commit, through the same write primitive the map's other
        // writers use.
        try saveReceiverGeneration(destination: destination, storeGeneration: generation)
        if let remembered {
            return .rebuiltAfterReset
        }
        return hadLegacyProgress ? .rebuiltFromLegacyState : .adopted
    }

    /// Clears every piece of destination-bound delivery progress: manual
    /// export cursors and windows, automatic checkpoints, and retry
    /// bookkeeping. Removal failures throw so the caller's commit (the new
    /// binding) never proceeds over state it failed to clear.
    func invalidateDeliveryProgress(destination: String) throws {
        try ensurePrepared()
        var cursors = loadManualCursors()
        cursors = cursors.filter { $0.value.destination != destination }
        try atomicWrite(encoder.encode(cursors), to: manualCursorsURL)

        var windows = loadManualWindows()
        windows = windows.filter { key, _ in
            ManualExportCursor.destination(fromWindowKey: key) != destination
        }
        try atomicWrite(encoder.encode(windows), to: manualWindowsURL)

        for metric in MetricCatalog.metrics.map(\.metric) {
            if let checkpoint = loadCheckpoint(for: metric),
               checkpoint.scope.destination == destination {
                try FileManager.default.removeItem(at: url(for: metric))
            }
        }
        try saveRetryStateThrowing(DeliveryRetryState.initial)
    }

    // MARK: - Files

    private func url(for metric: HealthMetric) -> URL {
        directory.appendingPathComponent("chk-\(metric.rawValue).json")
    }

    private var retryURL: URL {
        directory.appendingPathComponent("retry.json")
    }

    private var pendingScopeURL: URL {
        directory.appendingPathComponent("pending-scope.json")
    }

    /// Write-then-rename so a crash mid-write never truncates prior state.
    /// Overwrites are atomic replaces: a crash leaves either the old or the
    /// new file, never a partial one.
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: temporary.path
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutable.setResourceValues(resourceValues)
    }
}

/// A receiver-datastore reconciliation: the outcome of comparing the
/// receiver's current identity with the generation this device last
/// synchronized against, performed before any destination-bound sync work.
struct SyncGenerationCheck: Equatable, Sendable {
    let outcome: GenerationReconciliation
    let storeGeneration: UUID

    /// True when delivery progress was invalidated and the next reads start
    /// from the configured history window again.
    var didRebuild: Bool {
        outcome == .rebuiltAfterReset || outcome == .rebuiltFromLegacyState
    }
}

enum SyncGenerationReconciliationError: LocalizedError, Equatable {
    /// The receiver answered but reports no usable datastore identity.
    /// Syncing would mean trusting progress under ambiguous identity.
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            "The receiver does not report a datastore identity, so VitalRoute cannot tell whether its stored sync history still matches. Update the receiver to the current revision, then try again."
        }
    }
}

/// The datastore-generation gate both sync paths run before touching
/// destination-bound progress. Case semantics live in
/// `GenerationReconciliation`; the decision+commit is one actor-isolated
/// step, and the network call stays outside the store.
enum SyncGenerationReconciler {
    /// User-facing copy for a reconciliation that invalidated progress.
    /// Reused by both sync paths so the wording cannot drift.
    static let rebuiltHistoryNotice = "Destination was reset — rebuilding sync history."

    /// Checks and reconciles. `knownHealth` lets a caller that just fetched
    /// the health response (the enable flow's capability check) reuse it.
    /// Transport failures propagate untouched — a receiver that cannot be
    /// reached is a delivery failure with the usual retry handling, not an
    /// identity problem.
    static func reconcile(
        endpoint: URL,
        client: DestinationClient,
        authorization: DestinationAuthorization,
        stateStore: SyncStateStore,
        knownHealth: ReceiverHealthResponse? = nil
    ) async throws -> SyncGenerationCheck {
        let health: ReceiverHealthResponse
        if let knownHealth {
            health = knownHealth
        } else {
            health = try await client.testConnection(to: endpoint, authorization: authorization)
        }
        guard let generation = health.canonicalStoreGeneration else {
            throw SyncGenerationReconciliationError.identityUnavailable
        }
        // One actor-isolated step decides and commits; see
        // reconcileGeneration for the crash-safety ordering contract.
        let outcome = try await stateStore.reconcileGeneration(
            destination: endpoint.absoluteString,
            generation: generation
        )
        return SyncGenerationCheck(outcome: outcome, storeGeneration: generation)
    }
}
