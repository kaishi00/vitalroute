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
        for metric in HealthMetric.allCases {
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
            try ensurePrepared()
            let data = try encoder.encode(state)
            try atomicWrite(data, to: retryURL)
        } catch {
            // Counts and timestamps only: nothing payload-bearing, and the
            // reason alone.
            Self.logger.info("Retry state not persisted: \(String(describing: error), privacy: .public)")
        }
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
