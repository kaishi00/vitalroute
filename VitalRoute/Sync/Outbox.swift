import Foundation

/// Durable outbox of captured health changes.
///
/// One JSON file per event under a data-protected directory (atomic writes,
/// excluded from backups). Event identity (`SyncChangeEvent.eventID`) makes
/// crash-replay harmless: reloading dedupes, and the receiver's idempotent
/// acknowledgments make re-sends safe. Events are removed only after a
/// reconciled acknowledgment.
///
/// Events carry a lane (`live` or `backfill`). Live lanes hold changes read
/// at the head of a category's stream — the records HealthKit just wrote —
/// and are always delivered first; backfill lanes hold a category's
/// historical catch-up, so new health data never waits behind years of
/// history. The lane is encoded in the file name, which keeps the event
/// payload (also the wire format) untouched; files written before lanes
/// existed read as backfill.
///
/// Order comes from a monotonic sequence prefix in the file name, so
/// delivery order is insertion order within a lane. A pending index is kept
/// in memory and rebuilt from disk on `prepare()`; with the index, counting
/// and batching a five-figure backlog costs the same per pass as a small
/// one, which matters inside a short background execution window.
actor Outbox {
    struct PendingSnapshot: Equatable {
        let events: [SyncChangeEvent]
        let totalPending: Int
        /// Files moved to quarantine by this read; surfaced so the user can
        /// learn that some captured changes were undeliverable.
        var quarantinedCount: Int = 0
    }

    /// Delivery priority of a pending event.
    enum Lane: Sendable, Equatable {
        case live
        case backfill

        /// Single-character mark for the lane in the file name. The
        /// disambiguation from legacy names rests on group shape, not the
        /// alphabet: a legacy name's third hyphen-group is always an 8-char
        /// UUID group or "del", never exactly "l" or "b".
        var fileMark: String {
            switch self {
            case .live: "l"
            case .backfill: "b"
            }
        }

        static func from(fileMark: some StringProtocol) -> Lane {
            fileMark == "l" ? .live : .backfill
        }
    }

    static let capacityLimit = 10_000
    static let deliveryBatchSize = 200
    /// Byte budget for one delivery batch. Event files are exactly the
    /// encoded wire changes, so file size is the wire contribution; the
    /// budget keeps series-chunk batches (whose records are far larger than
    /// ordinary samples) from exceeding the receiver's body limit. Headroom
    /// covers batch framing and per-change wrappers.
    static let deliveryBatchByteLimit = 8 * 1024 * 1024

    private struct Entry {
        let sequence: UInt64
        let eventID: String
        let lane: Lane
        let fileName: String
        let fileSize: Int
    }

    private let directory: URL
    private let protection: FileProtectionType
    private let capacityLimit: Int
    private let deliveryByteLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextSequence: UInt64 = 0
    private var loaded = false
    /// Pending events, sorted by sequence. Rebuilt from the directory in
    /// `prepare()` and maintained by every mutation afterwards.
    private var index: [Entry] = []
    private var knownIDs: Set<String> = []

    init(
        directory: URL,
        protection: FileProtectionType = .completeUntilFirstUserAuthentication,
        capacityLimit: Int = Outbox.capacityLimit,
        deliveryByteLimit: Int = Outbox.deliveryBatchByteLimit
    ) {
        self.directory = directory.appendingPathComponent("outbox", isDirectory: true)
        self.protection = protection
        self.capacityLimit = capacityLimit
        self.deliveryByteLimit = deliveryByteLimit
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
        excludeFromBackup(directory)
        sweepTemporaryFiles()
        rebuildIndex()
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

    private func rebuildIndex() {
        var entries: [Entry] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                guard let parsed = Self.parse(fileName: name) else { continue }
                entries.append(Entry(
                    sequence: parsed.sequence,
                    eventID: parsed.eventID,
                    lane: parsed.lane,
                    fileName: name,
                    fileSize: Self.fileSize(of: directory.appendingPathComponent(name))
                ))
            }
        }
        // Deterministic on collision (which crash-replay prevents anyway):
        // keep the earliest-sequence file for an eventID.
        entries.sort { $0.sequence < $1.sequence }
        var deduped: [Entry] = []
        var ids = Set<String>()
        for entry in entries {
            guard ids.insert(entry.eventID).inserted else {
                // The earliest-sequence file wins; the loser is dead bytes
                // that would otherwise resurrect on the next rebuild.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
                continue
            }
            deduped.append(entry)
        }
        index = deduped
        knownIDs = ids
        nextSequence = deduped.last?.sequence ?? 0
    }

    /// Appends events, deduplicating against pending events already present.
    /// Returns the number of new files written.
    ///
    /// A failed write must leave no dedup trace: the engine replays the same
    /// page after a storage failure, and the replay must be able to re-append
    /// the event whose write failed, or its checkpoint would advance over
    /// health data that was never persisted. The ID is therefore claimed only
    /// after the write succeeds. A sequence number burned by a failed write
    /// stays burned — names never collide, so the gap is harmless.
    @discardableResult
    func append(_ events: [SyncChangeEvent], lane: Lane) throws -> Int {
        try ensurePrepared()
        var written = 0
        for event in events {
            guard !knownIDs.contains(event.eventID) else { continue }
            let data = try encoder.encode(event)
            nextSequence += 1
            let name = Self.fileName(sequence: nextSequence, lane: lane, eventID: event.eventID)
            try atomicWrite(data, to: directory.appendingPathComponent(name))
            // nextSequence only grows, so appending keeps the index sorted.
            knownIDs.insert(event.eventID)
            index.append(Entry(
                sequence: nextSequence,
                eventID: event.eventID,
                lane: lane,
                fileName: name,
                fileSize: data.count
            ))
            written += 1
        }
        return written
    }

    /// The next delivery batch plus the total number of pending events.
    ///
    /// Live events are always taken before backfill events (insertion order
    /// within each lane), so fresh samples ride in the first batches of a
    /// pass while a historical catch-up is still draining. Undecodable event
    /// files are quarantined (moved to `quarantine/`) so one corrupt file
    /// cannot stall delivery forever; the count is reported for surfacing.
    func nextBatch() throws -> PendingSnapshot {
        try ensurePrepared()
        let chosen = pickBatchEntries()
        var events: [SyncChangeEvent] = []
        var quarantined = 0
        for entry in chosen {
            let url = directory.appendingPathComponent(entry.fileName)
            if let data = try? Data(contentsOf: url),
               let event = try? decoder.decode(SyncChangeEvent.self, from: data) {
                events.append(event)
            } else {
                quarantine(url)
                knownIDs.remove(entry.eventID)
                index.removeAll { $0.eventID == entry.eventID }
                quarantined += 1
            }
        }
        return PendingSnapshot(events: events, totalPending: index.count, quarantinedCount: quarantined)
    }

    /// Live events first, topped up with backfill events to a full batch,
    /// bounded by both the event count and the byte budget. Scans the index
    /// once and stops as soon as a limit is reached; a single oversized
    /// event still ships alone (a legal batch of one).
    private func pickBatchEntries() -> [Entry] {
        var chosen: [Entry] = []
        var bytes = 0
        func admit(_ entry: Entry) -> Bool {
            if chosen.count == Self.deliveryBatchSize {
                return false
            }
            if !chosen.isEmpty, bytes + entry.fileSize > deliveryByteLimit {
                return false
            }
            chosen.append(entry)
            bytes += entry.fileSize
            return true
        }
        for entry in index where entry.lane == .live {
            if !admit(entry) { return chosen }
        }
        for entry in index where entry.lane == .backfill {
            if !admit(entry) { break }
        }
        return chosen
    }

    private static func fileSize(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
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
        return index.count
    }

    /// Pending counts per lane: `(live, backfill)`.
    func laneCounts() throws -> (live: Int, backfill: Int) {
        try ensurePrepared()
        var live = 0
        var backfill = 0
        for entry in index {
            if entry.lane == .live {
                live += 1
            } else {
                backfill += 1
            }
        }
        return (live, backfill)
    }

    /// The capacity this outbox applies. The engine reads it rather than the
    /// static default so tests can exercise the backpressure paths with a
    /// small queue.
    func capacityLimitValue() -> Int {
        capacityLimit
    }

    /// Removes acknowledged events. A crash before removal is safe: the
    /// event is re-sent and the receiver answers idempotently.
    func remove(eventIDs: [String]) {
        try? ensurePrepared()
        let targets = Set(eventIDs)
        guard !targets.isEmpty else { return }
        index.removeAll { entry in
            guard targets.contains(entry.eventID) else { return false }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            knownIDs.remove(entry.eventID)
            return true
        }
    }

    /// Drops a category's queued events (they must never be uploaded) —
    /// used when a category is disabled.
    func removeCategory(_ metric: HealthMetric) {
        removeWhere { $0.metric == metric }
    }

    func removeAll() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        // Quarantined files are health data too: a full clear discards them.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("quarantine", isDirectory: true)
        )
        // Re-derive from disk rather than assuming the empty state: if the
        // enumeration above failed, surviving files must stay counted, and
        // the sequence must not restart over them.
        rebuildIndex()
    }

    /// True when the queue has reached its capacity and capture must stop
    /// applying backpressure instead of discarding changes.
    func isAtCapacity() throws -> Bool {
        try pendingCount() >= capacityLimit
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
        var removed = false
        for name in names {
            guard Self.parse(fileName: name) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let event = try? decoder.decode(SyncChangeEvent.self, from: data) else {
                // Undecodable: unattributable to any category, so a purge
                // must not leave its bytes behind counted and undeliverable.
                quarantine(url)
                removed = true
                continue
            }
            guard predicate(event) else { continue }
            try? FileManager.default.removeItem(at: url)
            removed = true
        }
        // A category purge is a rare configuration event; one rescan keeps
        // the index exact without tracking metrics per entry.
        if removed {
            rebuildIndex()
        }
    }

    static func fileName(sequence: UInt64, lane: Lane, eventID: String) -> String {
        // Fixed-width sequence keeps lexicographic == numeric order.
        "evt-\(String(format: "%016llX", sequence))-\(lane.fileMark)-\(eventID).json"
    }

    /// Parses `evt-<sequence>-<lane>-<id>.json`. Files written before lanes
    /// existed (`evt-<sequence>-<id>.json`) read as backfill — they predate
    /// live prioritization, so classifying them as history keeps them behind
    /// every live capture. The lane mark is never a hex digit, so the two
    /// layouts are distinguishable.
    static func parse(fileName name: String) -> (sequence: UInt64, eventID: String, lane: Lane)? {
        guard name.hasPrefix("evt-") else { return nil }
        let probe = name.split(separator: "-", maxSplits: 3)
        guard probe.count >= 3, let sequence = UInt64(probe[1], radix: 16) else {
            return nil
        }
        if probe.count == 4, probe[2] == "l" || probe[2] == "b" {
            let id = Self.stripJSONSuffix(String(probe[3]))
            return (sequence, id, Lane.from(fileMark: probe[2]))
        }
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let id = Self.stripJSONSuffix(String(parts[2]))
        return (sequence, id, .backfill)
    }

    private static func stripJSONSuffix(_ name: String) -> String {
        name.hasSuffix(".json") ? String(name.dropLast(5)) : name
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
