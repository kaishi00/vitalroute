"""SQLite persistence for the VitalRoute receiver.

One database file, one table of health-record envelopes keyed by the
client-side record UUID. Each row keeps common, searchable envelope
columns (metric, kind, dates, source) plus the record's typed ``data``
payload as canonical JSON — the receiver stores structure, it does not
flatten it into per-metric columns.

Schema policy (pre-release, documented in DEPLOYMENT.md): there is no
migration machinery. A database that does not match this module's schema
generation blocks startup unless the caller explicitly allows the reset,
in which case it is dropped and recreated empty; the receiver logs a
single line (never any data).

Ingestion runs inside a single transaction per batch; the ack is only
issued after a successful commit. Duplicate ids are ignored (first write
wins), which makes client retries safe. Deleting a record tombstones its
id and cascades to live child rows (series chunks) that reference it as
parent, so a deleted parent can never leave orphaned chunks behind.
"""

import datetime
import os
import sqlite3

_SCHEMA_VERSION = 3

_SCHEMA = """
CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY,
    metric TEXT NOT NULL,
    kind TEXT NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    source_name TEXT,
    device_name TEXT,
    metadata_json TEXT NOT NULL,
    data_json TEXT NOT NULL,
    parent_id TEXT,
    batch_created_at TEXT NOT NULL,
    first_seen_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_records_metric_start ON records (metric, start_date);
CREATE INDEX IF NOT EXISTS idx_records_parent ON records (parent_id);
CREATE TABLE IF NOT EXISTS deleted_ids (
    id TEXT PRIMARY KEY,
    metric TEXT NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    batch_created_at TEXT NOT NULL,
    first_seen_at TEXT NOT NULL
);
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


class IncompatibleSchema(StorageError):
    """The on-disk database does not match the supported schema generation.

    Raised instead of silently discarding health data. Converting it to a
    clean startup failure (and opting into the reset) is the caller's
    decision.
    """


class ChangeCounts:
    """Per-batch application counts for the acknowledgment.

    ``cascaded_deletions`` counts live child rows (series chunks) removed
    as a consequence of a deleted parent. They are NOT part of the ack
    reconciliation sums: the client only verifies that the counts for the
    changes it sent add up.
    """

    def __init__(
        self,
        accepted,
        duplicates,
        superseded,
        applied_deletions,
        duplicate_deletions,
        cascaded_deletions,
    ):
        self.accepted = accepted
        self.duplicates = duplicates
        self.superseded = superseded
        self.applied_deletions = applied_deletions
        self.duplicate_deletions = duplicate_deletions
        self.cascaded_deletions = cascaded_deletions


class RecordStore:
    """Owns the SQLite file. One instance per server; connections per call.

    Reset policy (pre-release, documented in DEPLOYMENT.md): there is no
    migration machinery. When the on-disk database does not match this
    module's schema generation — a different declared version, or record
    tables with no declared version — the store refuses to touch it unless
    ``allow_schema_reset`` is set, in which case it drops and recreates the
    tables empty. Health data is never destroyed as a side effect of an
    ordinary start.
    """

    def __init__(self, db_path, logger=None, allow_schema_reset=False):
        self.db_path = db_path
        self._logger = logger
        self._allow_schema_reset = allow_schema_reset
        directory = os.path.dirname(os.path.abspath(db_path))
        os.makedirs(directory, exist_ok=True)
        self._initialize()

    def _connect(self):
        connection = sqlite3.connect(self.db_path, timeout=10.0)
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def _read_schema_version(self, connection):
        try:
            row = connection.execute(
                "SELECT value FROM schema_info WHERE key = 'schema_version'"
            ).fetchone()
        except sqlite3.OperationalError:
            return None
        return row[0] if row else None

    def _initialize(self):
        connection = self._connect()
        try:
            existing = self._read_schema_version(connection)
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                ).fetchall()
            }
            version_mismatch = (
                existing is not None and str(existing) != str(_SCHEMA_VERSION)
            )
            # Record tables with no declared version are a partial or
            # pre-versioning database: the same incompatible-generation
            # treatment, because their shape cannot be trusted.
            unversioned_tables = existing is None and bool(
                tables & {"records", "deleted_ids"}
            )
            if (version_mismatch or unversioned_tables) and not self._allow_schema_reset:
                raise IncompatibleSchema(
                    "The database at %s is not schema version %s; refusing to "
                    "start rather than discard health data. Re-sync from the "
                    "device or restore a backup, or explicitly allow the "
                    "reset by setting VITALROUTE_ALLOW_SCHEMA_RESET=1 "
                    "(the database will be recreated empty)."
                    % (self.db_path, _SCHEMA_VERSION)
                )
            if version_mismatch or unversioned_tables:
                # Documented development reset policy: an incompatible
                # database is recreated, never migrated. Nothing is logged
                # but the fact. VACUUM afterwards so the dropped rows do
                # not linger as recoverable free pages.
                if self._logger is not None:
                    self._logger.warning(
                        "Database schema version %s is incompatible with the "
                        "supported version %s; recreating the database empty.",
                        existing,
                        _SCHEMA_VERSION,
                    )
                connection.executescript(
                    """
                    DROP TABLE IF EXISTS records;
                    DROP TABLE IF EXISTS deleted_ids;
                    DROP TABLE IF EXISTS schema_info;
                    """
                )
            connection.executescript(_SCHEMA)
            connection.execute(
                "INSERT OR REPLACE INTO schema_info (key, value) VALUES ('schema_version', ?)",
                (str(_SCHEMA_VERSION),),
            )
            connection.commit()
            if version_mismatch or unversioned_tables:
                connection.execute("VACUUM")
        finally:
            connection.close()

    def apply(self, prepared_changes, batch_created_at_text):
        """Applies one change batch atomically with tombstone semantics.

        - upsert: INSERT OR IGNORE, first-write-wins — unless a tombstone
          exists for the id, or for an id the record references as parent
          (a series chunk of a deleted workout/route/ECG must not
          resurrect as an orphan), in which case the addition is counted
          as superseded and ignored. An older queued or retried addition
          can therefore never resurrect a deleted sample or leave its
          chunks behind.
        - delete: upserts a tombstone, removes any live row, and cascades
          to live rows whose parent_id references the deleted id (their
          ids are tombstoned too, so a replayed chunk cannot resurrect).

        Retrying the batch is idempotent.
        """
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
                    # Chunks whose parent (or series head) was deleted are
                    # suppressed the same way as the parent itself, even
                    # when the chunk row itself was never stored.
                    parent_refs = {
                        c.record.parent_id for c in upserts if c.record.parent_id
                    }
                    if parent_refs:
                        ref_placeholders = ",".join("?" * len(parent_refs))
                        tombstoned |= {
                            row[0]
                            for row in connection.execute(
                                "SELECT id FROM deleted_ids WHERE id IN (%s)" % ref_placeholders,
                                list(parent_refs),
                            ).fetchall()
                        }

                accepted = 0
                duplicates = 0
                superseded = 0
                if upserts:
                    fresh = [
                        (
                            c.record_id,
                            c.record.metric,
                            c.record.kind,
                            c.record.start_date,
                            c.record.end_date,
                            c.record.source_name,
                            c.record.device_name,
                            c.record.metadata_json,
                            c.record.data_json,
                            c.record.parent_id,
                            batch_created_at_text,
                            now_text,
                        )
                        for c in upserts
                        if c.record_id not in tombstoned
                        and c.record.parent_id not in tombstoned
                    ]
                    before = connection.total_changes
                    connection.executemany(
                        """
                        INSERT OR IGNORE INTO records (
                            id, metric, kind, start_date, end_date,
                            source_name, device_name, metadata_json,
                            data_json, parent_id, batch_created_at, first_seen_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        fresh,
                    )
                    accepted = connection.total_changes - before
                    duplicates = len(fresh) - accepted
                    superseded = len(upserts) - len(fresh)

                applied_deletions = 0
                duplicate_deletions = 0
                cascaded_deletions = 0
                for change in deletes:
                    # Cascade first: live children of this id are removed
                    # and tombstoned so a replayed chunk cannot resurrect.
                    # Child tombstone rows carry the parent delete's metric
                    # and interval: tombstones are consulted by id only,
                    # and the deleted object's own dates are the audit
                    # truth for the whole cascade.
                    children = [
                        row[0]
                        for row in connection.execute(
                            "SELECT id FROM records WHERE parent_id = ?",
                            (change.record_id,),
                        ).fetchall()
                    ]
                    if children:
                        connection.execute(
                            "DELETE FROM records WHERE parent_id = ?",
                            (change.record_id,),
                        )
                        connection.executemany(
                            """
                            INSERT OR IGNORE INTO deleted_ids (
                                id, metric, start_date, end_date,
                                batch_created_at, first_seen_at
                            ) VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            [
                                (
                                    child_id,
                                    change.metric,
                                    change.dates[0],
                                    change.dates[1],
                                    batch_created_at_text,
                                    now_text,
                                )
                                for child_id in children
                            ],
                        )
                        cascaded_deletions += len(children)

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
            accepted,
            duplicates,
            superseded,
            applied_deletions,
            duplicate_deletions,
            cascaded_deletions,
        )

    def record_count(self):
        connection = self._connect()
        try:
            row = connection.execute("SELECT COUNT(*) FROM records").fetchone()
            return int(row[0])
        finally:
            connection.close()

    def tombstones(self):
        connection = self._connect()
        try:
            rows = connection.execute("SELECT id FROM deleted_ids").fetchall()
            return {row[0] for row in rows}
        finally:
            connection.close()

    def schema_version(self):
        """The database's declared schema version, or None when absent."""
        connection = self._connect()
        try:
            return self._read_schema_version(connection)
        finally:
            connection.close()
