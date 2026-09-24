#!/usr/bin/env python3
"""Read-only query layer over the VitalRoute receiver database.

Every entry point opens the database with SQLite's read-only URI semantics:
this module can never write and never mutate health data. All queries
exclude tombstoned ids, so a sample deleted on the phone never resurfaces
in an answer.

Intended consumers: the MCP query server (mcp_server.py) and tests. There
is deliberately no arbitrary-SQL entry point — only the fixed, bounded
queries below.
"""

import datetime
import json
import sqlite3

# Grouping and bounds. The date cap keeps one agent question from walking
# the whole database; it is generous for human-scale questions.
MAX_RANGE_DAYS = 366
MAX_RECORDS = 200

KNOWN_METRICS = {
    # metric -> aggregation semantics for documentation/consumers
    "steps": "sum per day (count)",
    "activeEnergy": "sum per day (kcal)",
    "sleep": "sum per day (s)",
    "heartRate": "instantaneous samples (count/min): min/avg/max",
    "restingHeartRate": "daily samples (count/min): avg",
    "heartRateVariability": "samples (ms): avg",
    "workouts": "sum per day (s); 'count' is the number of workout entries",
}


class QueryError(ValueError):
    """Invalid query arguments (surfaced to the caller as a bad request)."""


def _validate_metric(metric):
    if metric is None:
        return None
    if not isinstance(metric, str) or not metric or len(metric) > 64:
        raise QueryError("metric must be a short non-empty string")
    return metric


def _validate_date(name, value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise QueryError(f"{name} must be an ISO date string (YYYY-MM-DD)")
    try:
        # Real calendar validation: impossible dates like 2026-13-45 would
        # otherwise slip past the range cap (julianday returns NULL).
        datetime.date.fromisoformat(value)
    except ValueError:
        raise QueryError(f"{name} must be a valid ISO date (YYYY-MM-DD)")
    return value


def connect(db_path):
    """Opens the database read-only; this module can never write.

    mode=ro (not immutable=1): the MCP server reads the LIVE database while
    the receiver may be writing it; immutable caching could serve stale
    data. Read-only WAL access is safe and sees committed data as long as
    the -wal/-shm sidecars are readable or recreatable — the deployment
    mounts the data volume READ-WRITE precisely because the receiver
    deletes the sidecars between write batches and SQLite must be able to
    recreate them. Writes to health data are blocked HERE, at the SQLite
    layer (mode=ro plus PRAGMA query_only), never by the mount.

    check_same_thread=False: one connection is shared by the MCP server's
    worker threads; concurrent use is serialized by
    mcp_server.QueryState.lock.
    """
    connection = sqlite3.connect(
        f"file:{db_path}?mode=ro", uri=True, check_same_thread=False
    )
    connection.row_factory = sqlite3.Row
    # Belt-and-braces with mode=ro: even if the URI were ever loosened,
    # query_only rejects every write on this connection.
    connection.execute("PRAGMA query_only = 1")
    return connection


def _live_only(sql):
    """WHERE fragment excluding tombstoned ids."""
    return sql.replace("__LIVE__", "NOT EXISTS (SELECT 1 FROM deleted_ids d WHERE d.id = r.id)")


def list_metrics(connection):
    rows = connection.execute(_live_only(
        "SELECT r.metric AS metric, COUNT(*) AS n, MIN(r.start_date) AS earliest, MAX(r.end_date) AS latest "
        "FROM records r WHERE __LIVE__ GROUP BY r.metric ORDER BY r.metric"
    )).fetchall()
    tombstones = connection.execute("SELECT COUNT(*) FROM deleted_ids").fetchone()[0]
    return {
        "metrics": [
            {
                "metric": row["metric"],
                "records": row["n"],
                "earliest": row["earliest"],
                "latest": row["latest"],
                "semantics": KNOWN_METRICS.get(row["metric"], "unknown metric; inspect raw records"),
            }
            for row in rows
        ],
        "deletedIdsExcluded": tombstones,
    }


def daily_stats(connection, metric=None, from_date=None, to_date=None, days=None):
    """Per-UTC-day aggregates for one metric (or every metric when None)."""
    metric = _validate_metric(metric)
    from_date = _validate_date("from", from_date)
    to_date = _validate_date("to", to_date)
    if days is not None and (from_date is not None or to_date is not None):
        raise QueryError("pass either days or from/to, not both")
    if from_date is None and to_date is None and days is None:
        raise QueryError("bound the query with 'days' or 'from'/'to'")
    if days is not None:
        if not isinstance(days, int) or isinstance(days, bool) or days < 1 or days > MAX_RANGE_DAYS:
            raise QueryError(f"days must be an integer in 1..{MAX_RANGE_DAYS}")
        # Anchor on the newest data so "last N days" means the most recent
        # window with data, not wall-clock days that may have none. The
        # window start is computed by SQLite, the same engine that compares
        # the dates afterwards.
        newest = connection.execute(
            _live_only("SELECT MAX(r.end_date) FROM records r WHERE __LIVE__")
        ).fetchone()[0]
        if newest is None:
            return {"days": [], "note": "no records"}
        # Anchor on the date part only; a NULL result (unparseable data)
        # must fail loudly, not silently drop the lower bound and return
        # the whole history.
        from_date = connection.execute(
            "SELECT date(substr(?, 1, 10), ?)", (newest, f"-{days - 1} day")
        ).fetchone()[0]
        if from_date is None:
            raise QueryError("could not compute the days window; newest record date is invalid")
    if from_date and to_date and from_date > to_date:
        raise QueryError("from must not be after to")
    if from_date and to_date:
        span = connection.execute(
            "SELECT CAST(julianday(?) - julianday(?) AS INTEGER)", (to_date, from_date)
        ).fetchone()[0]
        if span is None or span > MAX_RANGE_DAYS:
            raise QueryError(f"date range must be at most {MAX_RANGE_DAYS} days")
    clauses = ["__LIVE__"]
    params = []
    if metric:
        clauses.append("r.metric = ?")
        params.append(metric)
    if from_date:
        clauses.append("substr(r.start_date, 1, 10) >= ?")
        params.append(from_date)
    if to_date:
        clauses.append("substr(r.start_date, 1, 10) <= ?")
        params.append(to_date)
    rows = connection.execute(_live_only(
        "SELECT substr(r.start_date, 1, 10) AS day, r.metric AS metric, COUNT(*) AS n, "
        "SUM(r.value) AS total, AVG(r.value) AS avg_value, MIN(r.value) AS min_value, MAX(r.value) AS max_value "
        "FROM records r WHERE " + " AND ".join(clauses) + " "
        "GROUP BY day, r.metric ORDER BY day, r.metric"
    ), params).fetchall()
    return {
        "semantics": {m: KNOWN_METRICS[m] for m in
                      sorted({row["metric"] for row in rows} & set(KNOWN_METRICS))},
        "days": [
            {
                "date": row["day"],
                "metric": row["metric"],
                "count": row["n"],
                "sum": round(row["total"], 2) if row["total"] is not None else None,
                "avg": round(row["avg_value"], 2) if row["avg_value"] is not None else None,
                "min": row["min_value"],
                "max": row["max_value"],
            }
            for row in rows
        ],
    }


def recent_records(connection, metric=None, limit=20, offset=0):
    metric = _validate_metric(metric)
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1 or limit > MAX_RECORDS:
        raise QueryError(f"limit must be an integer in 1..{MAX_RECORDS}")
    if not isinstance(offset, int) or isinstance(offset, bool) or offset < 0 or offset > 100000:
        raise QueryError("offset must be an integer in 0..100000")
    clauses = ["__LIVE__"]
    params = []
    if metric:
        clauses.append("r.metric = ?")
        params.append(metric)
    params.extend([limit, offset])
    rows = connection.execute(_live_only(
        "SELECT r.id, r.metric, r.value, r.unit, r.start_date, r.end_date, r.source_name, r.device_name, r.metadata "
        "FROM records r WHERE " + " AND ".join(clauses) + " "
        "ORDER BY r.start_date DESC, r.id LIMIT ? OFFSET ?"
    ), params).fetchall()
    return {
        "records": [
            {
                "id": row["id"],
                "metric": row["metric"],
                "value": row["value"],
                "unit": row["unit"],
                "start": row["start_date"],
                "end": row["end_date"],
                "source": row["source_name"],
                "device": row["device_name"],
                "metadata": json.loads(row["metadata"] or "null"),
            }
            for row in rows
        ]
    }
