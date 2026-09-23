import io

# --- HealthKitService: delivery enablement before observer registration ---
path = "VitalRoute/Health/HealthKitService.swift"
text = io.open(path, encoding="utf-8").read()
old = """        let store = healthStore
        var registered: [HKObserverQuery] = []
        for metric in HealthMetric.allCases where metrics.contains(metric) {
            guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
                continue
            }
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, _ in
                // The observer callback must complete exactly once, promptly:
                // signal the trigger, let the engine do bounded async work.
                handler()
                completionHandler()
            }
            store.execute(observer)
            registered.append(observer)
        }
        activeObservers = registered
        if !registered.isEmpty {
            // Enables background delivery for each observed type; the system
            // throttles wake-ups and never guarantees immediacy.
            for metric in HealthMetric.allCases where metrics.contains(metric) {
                guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
                    continue
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: HealthKitServiceError.authorizationFailed)
                        }
                    }
                }
            }
            hasEnabledBackgroundDelivery = true
        }
    }"""
new = """        let store = healthStore
        let sampleTypes = HealthMetric.allCases
            .filter { metrics.contains($0) }
            .compactMap { HealthKitRecordMapper.sampleType(for: $0) }

        // Enable background delivery first: if it fails partway, nothing is
        // left registered (a thrown error leaves enablement to be unwound by
        // the next stopObservingChanges).
        for sampleType in sampleTypes {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HealthKitServiceError.authorizationFailed)
                    }
                }
            }
        }
        var registered: [HKObserverQuery] = []
        for sampleType in sampleTypes {
            // The observer callback must complete exactly once, promptly:
            // signal the trigger, let the engine do bounded async work.
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, _ in
                handler()
                completionHandler()
            }
            store.execute(observer)
            registered.append(observer)
        }
        activeObservers = registered
        hasEnabledBackgroundDelivery = !sampleTypes.isEmpty
    }"""
assert old in text, "healthkit observeChanges"
text = text.replace(old, new)
io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("observeChanges reordered")

# --- Receiver storage: tombstones shared, v1 filter, schema marker ---
path = "server/storage.py"
text = io.open(path, encoding="utf-8").read()

old = '_SCHEMA = """\nCREATE TABLE IF NOT EXISTS records ('
new = '''_TOMBSTONE_SCHEMA = """
CREATE TABLE IF NOT EXISTS deleted_ids (
    id TEXT PRIMARY KEY,
    metric TEXT NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    batch_created_at TEXT NOT NULL,
    first_seen_at TEXT NOT NULL
);
"""

_SCHEMA = """
CREATE TABLE IF NOT EXISTS records ('''
assert old in text, "schema prefix"
text = text.replace(old, new, 1)

old = """    def _initialize(self):
        connection = self._connect()
        try:
            connection.executescript(_SCHEMA)
            connection.execute(
                "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('schema_version', ?)",
                (str(_SCHEMA_VERSION),),
            )
            connection.commit()
        finally:
            connection.close()"""
new = """    def _initialize(self):
        connection = self._connect()
        try:
            connection.executescript(_SCHEMA)
            # Additive v2 migration: tombstones exist so v1 ingestion can
            # honor deletions too; existing rows are untouched.
            connection.executescript(_TOMBSTONE_SCHEMA)
            connection.execute(
                "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('schema_version', ?)",
                (str(_SCHEMA_VERSION),),
            )
            connection.execute(
                "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('v2_tombstones', '1')"
            )
            connection.commit()
        finally:
            connection.close()"""
assert old in text, "initialize"
text = text.replace(old, new)

old = '''    def ingest(self, prepared_records, batch_created_at_text):
        """Atomically inserts records; returns (accepted, duplicates)."""
        now_text = _utc_now_text()
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            try:
                before = connection.total_changes'''
new = '''    def ingest(self, prepared_records, batch_created_at_text):
        """Atomically inserts records; returns (accepted, duplicates).

        Ids that already have a tombstone are counted as duplicates and not
        inserted: a stale v1 (manual-sync) batch must not resurrect a sample
        deleted through the v2 change stream.
        """
        now_text = _utc_now_text()
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            try:
                record_ids = [record[0] for record in prepared_records]
                tombstoned = set()
                if record_ids:
                    placeholders = ",".join("?" * len(record_ids))
                    tombstoned = {
                        row[0]
                        for row in connection.execute(
                            "SELECT id FROM deleted_ids WHERE id IN (%s)" % placeholders,
                            record_ids,
                        ).fetchall()
                    }
                deliverable = [
                    record for record in prepared_records if record[0] not in tombstoned
                ]
                before = connection.total_changes'''
assert old in text, "ingest head"
text = text.replace(old, new)

old = """                            ) in prepared_records
                        ],
                    )
                    inserted = connection.total_changes - before
                    connection.commit()
            except BaseException:
                connection.rollback()
                raise
        finally:
            connection.close()
        return inserted, len(prepared_records) - inserted"""
new = """                            ) in deliverable
                        ],
                    )
                    inserted = connection.total_changes - before
                    connection.commit()
            except BaseException:
                connection.rollback()
                raise
        finally:
            connection.close()
        # Tombstone-suppressed ids report as duplicates: the v1 client-side
        # reconciliation expects every sent record to be accounted for.
        return inserted, len(prepared_records) - inserted"""
assert old in text, "ingest tail"
text = text.replace(old, new)

old = """    _TOMBSTONE_SCHEMA = \"\"\"
    CREATE TABLE IF NOT EXISTS deleted_ids (
        id TEXT PRIMARY KEY,
        metric TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        batch_created_at TEXT NOT NULL,
        first_seen_at TEXT NOT NULL
    );
    \"\"\"

    def __init__(self, db_path):"""
new = """    def __init__(self, db_path):"""
assert old in text, "applier ddl"
text = text.replace(old, new)

old = """        connection = self._connect()
        try:
            connection.executescript(self._TOMBSTONE_SCHEMA)
            connection.commit()
        finally:
            connection.close()"""
new = """        connection = self._connect()
        try:
            connection.executescript(_TOMBSTONE_SCHEMA)
            connection.execute(
                "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('v2_tombstones', '1')"
            )
            connection.commit()
        finally:
            connection.close()"""
assert old in text, "applier init"
text = text.replace(old, new)

io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("receiver tombstones enforced for v1")
