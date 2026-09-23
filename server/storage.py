"""SQLite persistence for the VitalRoute receiver.

One database file, one table of health records keyed by the client-side record
UUID. Ingestion runs inside a single transaction per batch; the ack is only
issued after a successful commit. Duplicate ids are ignored (first write wins),
which makes client retries safe.
"""

import datetime
import json
import os
import sqlite3

_SCHEMA_VERSION = 1

_TOMBSTONE_SCHEMA = """
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
CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY,
    metric TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    source_name TEXT,
    device_name TEXT,
    metadata TEXT NOT NULL,
    batch_created_at TEXT NOT NULL,
    first_seen_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_records_metric_start ON records (metric, start_date);
CREATE TABLE IF NOT EXISTS schema_info (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def _utc_now_text():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000)


class StorageError(Exception):
    pass


class RecordStore:
    """Owns the SQLite file. One instance per server; connections per call."""

    def __init__(self, db_path):
        self.db_path = db_path
        directory = os.path.dirname(os.path.abspath(db_path))
        os.makedirs(directory, exist_ok=True)
        self._initialize()

    def _connect(self):
        connection = sqlite3.connect(self.db_path, timeout=10.0)
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def _initialize(self):
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
            connection.close()

    def ingest(self, prepared_records, batch_created_at_text):
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
                before = connection.total_changes
                connection.executemany(
                    """
                    INSERT OR IGNORE INTO records (
                        id, metric, value, unit, start_date, end_date,
                        source_name, device_name, metadata,
                        batch_created_at, first_seen_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        (
                            record_id,
                            metric,
                            value,
                            unit,
                            start_date,
                            end_date,
                            source_name,
                            device_name,
                            json.dumps(metadata, sort_keys=True, separators=(",", ":")),
                            batch_created_at_text,
                            now_text,
                        )
                        for (
                            record_id,
                            metric,
                            value,
                            unit,
                            start_date,
                            end_date,
                            source_name,
                            device_name,
                            metadata,
                        ) in deliverable
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
        return inserted, len(prepared_records) - inserted

    def record_count(self):
        connection = self._connect()
        try:
            row = connection.execute("SELECT COUNT(*) FROM records").fetchone()
            return int(row[0])
        finally:
            connection.close()

    def record_ids(self):
        connection = self._connect()
        try:
            rows = connection.execute("SELECT id FROM records").fetchall()
            return {row[0] for row in rows}
        finally:
            connection.close()


class ChangeCounts:
    """Per-batch application counts for the v2 acknowledgment."""

    def __init__(self, accepted, duplicates, superseded, applied_deletions, duplicate_deletions):
        self.accepted = accepted
        self.duplicates = duplicates
        self.superseded = superseded
        self.applied_deletions = applied_deletions
        self.duplicate_deletions = duplicate_deletions


class ChangeApplier:
    """Applies one v2 batch atomically with tombstone semantics.

    - upsert: INSERT OR IGNORE, first-write-wins — unless a tombstone exists
      for the id, in which case the addition is counted as superseded and
      ignored (an older queued addition can never resurrect a deleted
      sample).
    - delete: upserts a tombstone and removes any live row. Retrying a
      deletion is idempotent (duplicate_deletions).
    """

    def __init__(self, db_path):
        self.db_path = db_path
        # Additive migration for v1 databases: creates the tombstone table if
        # missing; existing rows are never rewritten.
        connection = self._connect()
        try:
            connection.executescript(_TOMBSTONE_SCHEMA)
            connection.execute(
                "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('v2_tombstones', '1')"
            )
            connection.commit()
        finally:
            connection.close()

    def _connect(self):
        connection = sqlite3.connect(self.db_path, timeout=10.0)
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def apply(self, prepared_changes, batch_created_at_text):
        now_text = _utc_now_text()
        upserts = [c for c in prepared_changes if c.kind == "upsert"]
        deletes = [c for c in prepared_changes if c.kind == "delete"]

        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            try:
                tombstoned = set()
                if upserts:
                    upsert_ids = [c.record_id for c in upserts]
                    placeholders = ",".join("?" * len(upsert_ids))
                    tombstoned = {
                        row[0]
                        for row in connection.execute(
                            "SELECT id FROM deleted_ids WHERE id IN (%s)" % placeholders,
                            upsert_ids,
                        ).fetchall()
                    }

                accepted = 0
                duplicates = 0
                superseded = 0
                if upserts:
                    fresh = [
                        (
                            c.record_id, c.metric, c.record_tuple[2], c.record_tuple[3],
                            c.record_tuple[4], c.record_tuple[5], c.record_tuple[6],
                            c.record_tuple[7],
                            json.dumps(c.record_tuple[8], sort_keys=True, separators=(",", ":")),
                            batch_created_at_text, now_text,
                        )
                        for c in upserts
                        if c.record_id not in tombstoned
                    ]
                    before = connection.total_changes
                    connection.executemany(
                        """
                        INSERT OR IGNORE INTO records (
                            id, metric, value, unit, start_date, end_date,
                            source_name, device_name, metadata,
                            batch_created_at, first_seen_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        fresh,
                    )
                    accepted = connection.total_changes - before
                    duplicates = len(fresh) - accepted
                    superseded = len(upserts) - len(fresh)

                applied_deletions = 0
                duplicate_deletions = 0
                for change in deletes:
                    connection.execute(
                        "DELETE FROM records WHERE id = ?", (change.record_id,)
                    )
                    cursor = connection.execute(
                        """
                        INSERT OR IGNORE INTO deleted_ids (
                            id, metric, start_date, end_date, batch_created_at, first_seen_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            change.record_id,
                            change.metric,
                            change.dates[0],
                            change.dates[1],
                            batch_created_at_text,
                            now_text,
                        ),
                    )
                    if cursor.rowcount > 0:
                        applied_deletions += 1
                    else:
                        duplicate_deletions += 1

                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        finally:
            connection.close()

        return ChangeCounts(
            accepted, duplicates, superseded, applied_deletions, duplicate_deletions
        )

    def tombstones(self):
        connection = self._connect()
        try:
            rows = connection.execute("SELECT id FROM deleted_ids").fetchall()
            return {row[0] for row in rows}
        finally:
            connection.close()
