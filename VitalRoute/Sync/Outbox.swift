import Foundation

/// Durable outbox of captured health changes.
///
/// One JSON file per event under a data-protected directory (atomic writes,
/// excluded from backups). Event identity (`SyncChangeEvent.eventID`) makes
/// crash-replay harmless: reloading dedupes, and the receiver's idempotent
/// acknowledgments make re-sends safe. Events are removed only after a
/// reconciled acknowledgment.
///
/// Order comes from a monotonic sequence prefix in the file name, so
/// delivery order is insertion order regardless of directory enumeration.
actor Outbox {
    struct PendingSnapshot: Equatable {
        let events: [SyncChangeEvent]
        let totalPending: Int
        /// Files moved to quarantine by this read; surfaced so the user can
        /// learn that some captured changes were undeliverable.
        var quarantinedCount: Int = 0
    }

    static let capacityLimit = 10_000
    static let deliveryBatchSize = 200

    private let directory: URL
    private let protection: FileProtectionType
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextSequence: UInt64
    private var loaded = false

    init(directory: URL, protection: FileProtectionType = .completeUntilFirstUserAuthentication) {
        self.directory = directory.appendingPathComponent("outbox", isDirectory: true)
        self.protection = protection
        self.nextSequence = 0
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        excludeFromBackup(directory)
        sweepTemporaryFiles()
        nextSequence = (try? currentMaxSequence()) ?? 0
        loaded = true
    }

    /// Removes temp files left by writes that crashed between write and
    /// rename; they are never valid events.
    private func sweepTemporaryFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix(".tmp-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Appends events, deduplicating against files already present. Returns
    /// the number of new files written.
    @discardableResult
    func append(_ events: [SyncChangeEvent]) throws -> Int {
        try ensurePrepared()
        var existing = allEventIDs()
        var written = 0
        for event in events where existing.insert(event.eventID).inserted {
            let data = try encoder.encode(event)
            nextSequence += 1
            let name = fileName(sequence: nextSequence, eventID: event.eventID)
            try atomicWrite(data, to: directory.appendingPathComponent(name))
            written += 1
        }
        return written
    }

    /// The next delivery batch plus the total number of pending events.
    /// Undecodable event files are quarantined (moved to `quarantine/`) so
    /// one corrupt file cannot stall delivery forever; the count is
    /// reported for surfacing.
    func nextBatch() throws -> PendingSnapshot {
        try ensurePrepared()
        var files = try sortedEventFiles()
        var events: [SyncChangeEvent] = []
        var quarantined = 0
        for file in files {
            guard events.count < Self.deliveryBatchSize else { break }
            if let data = try? Data(contentsOf: file.url),
               let event = try? decoder.decode(SyncChangeEvent.self, from: data) {
                events.append(event)
            } else {
                quarantine(file.url)
                quarantined += 1
            }
        }
        if quarantined > 0 {
            files = try sortedEventFiles()
        }
        return PendingSnapshot(events: events, totalPending: files.count, quarantinedCount: quarantined)
    }

    /// Keeps a corrupt file for inspection without letting it block the
    /// queue. Contents are health data: same protection, same directory
    /// tree, still excluded from backups.
    private func quarantine(_ url: URL) {
        let directory = self.directory.appendingPathComponent("quarantine", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        try? FileManager.default.moveItem(
            at: url,
            to: directory.appendingPathComponent(url.lastPathComponent)
        )
    }

    func pendingCount() throws -> Int {
        try ensurePrepared()
        return try sortedEventFiles().count
    }

    /// Removes acknowledged events. A crash before removal is safe: the
    /// event is re-sent and the receiver answers idempotently.
    func remove(eventIDs: [String]) {
        let targets = Set(eventIDs)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where targets.contains(eventID(fromFileName: name)) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Drops a category's queued events (they must never be uploaded) —
    /// used when a category is disabled.
    func removeCategory(_ metric: HealthMetric) {
        removeWhere { $0.metric == metric }
    }

    func removeAll() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        nextSequence = 0
    }

    /// True when the queue has reached its capacity and query passes must
    /// stop applying backpressure instead of discarding changes.
    func isAtCapacity() throws -> Bool {
        try pendingCount() >= Self.capacityLimit
    }

    // MARK: - Files

    private func ensurePrepared() throws {
        if !loaded {
            try prepare()
        }
    }

    private func removeWhere(_ predicate: (SyncChangeEvent) -> Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let event = try? decoder.decode(SyncChangeEvent.self, from: data),
               predicate(event) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private struct EventFile {
        let sequence: UInt64
        let url: URL
    }

    private func sortedEventFiles() throws -> [EventFile] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .compactMap { name -> EventFile? in
                guard name.hasPrefix("evt-") else { return nil }
                // Subdirectories never match the file pattern above.
                let url = directory.appendingPathComponent(name)
                let sequence = sequence(fromFileName: name)
                return EventFile(sequence: sequence, url: url)
            }
            .sorted { $0.sequence < $1.sequence }
    }

    private func allEventIDs() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(names.filter { $0.hasPrefix("evt-") }.map(eventID(fromFileName:)))
    }

    private func currentMaxSequence() throws -> UInt64 {
        try sortedEventFiles().last?.sequence ?? 0
    }

    private func fileName(sequence: UInt64, eventID: String) -> String {
        // Fixed-width sequence keeps lexicographic == numeric order.
        "evt-\(String(format: "%016llX", sequence))-\(eventID).json"
    }

    private func sequence(fromFileName name: String) -> UInt64 {
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, let value = UInt64(parts[1], radix: 16) else {
            return 0
        }
        return value
    }

    private func eventID(fromFileName name: String) -> String {
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3 else { return name }
        return String(parts[2]).replacingOccurrences(of: ".json", with: "")
    }

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
