import Foundation

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

/// Persisted retry/backoff bookkeeping. Counts and timestamps only.
struct DeliveryRetryState: Codable, Equatable {
    var consecutiveFailures = 0
    var nextAttemptAt: Date?
    var lastFailureIsActionable = false
    var lastFailureMessage: String?
    var lastSuccessAt: Date?
    var lastCheckAt: Date?

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

    init(directory: URL, protection: FileProtectionType = .completeUntilFirstUserAuthentication) {
        self.directory = directory.appendingPathComponent("state", isDirectory: true)
        self.protection = protection
    }

    /// Prepares the on-disk layout. Call once before use.
    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        excludeFromBackup(directory)
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
        let data = try encoder.encode(checkpoint)
        try atomicWrite(data, to: url(for: metric: checkpoint.scope.metric))
    }

    func clearCheckpoint(for metric: HealthMetric) {
        try? FileManager.default.removeItem(at: url(for: metric))
    }

    func clearAllCheckpoints() {
        for metric in HealthMetric.allCases {
            clearCheckpoint(for: metric)
        }
    }

    func loadRetryState() -> DeliveryRetryState {
        guard let data = try? Data(contentsOf: retryURL) else {
            return .initial
        }
        return (try? decoder.decode(DeliveryRetryState.self, from: data)) ?? .initial
    }

    func saveRetryState(_ state: DeliveryRetryState) {
        if let data = try? encoder.encode(state) {
            try? atomicWrite(data, to: retryURL)
        }
    }

    // MARK: - Files

    private func url(for metric: HealthMetric) -> URL {
        directory.appendingPathComponent("chk-\(metric.rawValue).json")
    }

    private var retryURL: URL {
        directory.appendingPathComponent("retry.json")
    }

    /// Write-then-rename so a crash mid-write never truncates prior state.
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: temporary.path
        )
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutable.setResourceValues(resourceValues)
    }
}
