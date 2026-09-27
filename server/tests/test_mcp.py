"""Tests for the read-only MCP query layer and server.

Runs a real query server on an ephemeral port against a temporary SQLite
database filled through the receiver's own storage layer (synthetic
records only), then drives the MCP JSON-RPC surface over HTTP. Also covers
tombstone exclusion and the bounded-query validation directly.
"""

import http.client
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import uuid
from contextlib import closing
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import mcp_server  # noqa: E402
import queries  # noqa: E402
import storage  # noqa: E402

TOKEN = "query-test-token-0123456789abcdef"
HOST = "127.0.0.1"


def make_record(**overrides):
    record = {
        "id": str(uuid.uuid4()),
        "metric": "steps",
        "kind": "quantity",
        "startDate": "2026-09-20T10:00:00.000Z",
        "endDate": "2026-09-20T10:01:00.000Z",
        "sourceName": "Synthetic Source",
        "deviceName": "Synthetic Device",
        "metadata": {},
        "data": {"type": "quantity", "value": 1000, "unit": "count"},
    }
    record.update(overrides)
    return record


def prepared(record):
    from validation import validate_change_payload

    payload = {
        "schemaVersion": 3,
        "createdAt": "2026-09-23T12:00:00.000Z",
        "batchId": str(uuid.uuid4()),
        "changes": [{"kind": "upsert", "record": record}],
    }
    batch_created_at, prepared_changes = validate_change_payload(payload, 500)
    return batch_created_at, prepared_changes


class QueryServerTestCase(unittest.TestCase):
    """Base fixture: one query server per test, isolated temp database."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.db_path = os.path.join(self.tempdir.name, "records.sqlite3")
        self.store = storage.RecordStore(self.db_path)

        self.r1 = make_record(id=str(uuid.uuid4()), data={"type": "quantity", "value": 1000, "unit": "count"},
                              startDate="2026-09-20T10:00:00.000Z",
                              endDate="2026-09-20T10:01:00.000Z")
        self.r2 = make_record(id=str(uuid.uuid4()), data={"type": "quantity", "value": 2000, "unit": "count"},
                              startDate="2026-09-21T09:00:00.000Z",
                              endDate="2026-09-21T09:01:00.000Z")
        self.h1 = make_record(id=str(uuid.uuid4()), metric="heartRate",
                              data={"type": "quantity", "value": 60, "unit": "count/min"},
                              startDate="2026-09-21T12:00:00.000Z",
                              endDate="2026-09-21T12:01:00.000Z")
        for record in (self.r1, self.r2, self.h1):
            batch_created_at, prepared_changes = prepared(record)
            self.store.apply(prepared_changes, batch_created_at)

        self.server = mcp_server.make_server(HOST, 0, self.db_path, TOKEN)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    # ---- helpers -----------------------------------------------------------

    def request(self, method, path, body=None, token=TOKEN, headers=None):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            request_headers = dict(headers or {})
            if token is not None:
                request_headers["Authorization"] = "Bearer " + token
            payload = json.dumps(body) if body is not None else None
            connection.request(method, path, body=payload, headers=request_headers)
            response = connection.getresponse()
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
        finally:
            connection.close()

    def rpc(self, method, params=None, msg_id=1, token=TOKEN):
        message = {"jsonrpc": "2.0", "method": method, "id": msg_id}
        if params is not None:
            message["params"] = params
        return self.request("POST", "/", message, token=token)


class DatabaseLifetimeTests(QueryServerTestCase):
    """A running HTTP service must follow replacements at its DB path."""

    def call(self, name, arguments=None):
        status, body = self.rpc("tools/call", {
            "name": name, "arguments": arguments or {},
        })
        self.assertEqual(status, 200)
        return body["result"]

    def assert_inventory(self, metrics, ids):
        result = self.call("list_metrics")
        self.assertNotIn("isError", result)
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual({row["metric"] for row in payload["metrics"]}, metrics)
        result = self.call("recent_records")
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual({row["id"] for row in payload["records"]}, ids)
        result = self.call("daily_stats", {"days": 7})
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual({row["metric"] for row in payload["days"]}, metrics)

    def tracked_connections(self):
        opened = []
        real_connect = queries.connect

        class TrackedConnection:
            def __init__(self, connection):
                self.connection = connection
                self.closed = False

            def execute(self, *args, **kwargs):
                return self.connection.execute(*args, **kwargs)

            def close(self):
                self.closed = True
                self.connection.close()

        def connect(path):
            connection = TrackedConnection(real_connect(path))
            opened.append(connection)
            return connection

        return opened, connect

    def test_startup_validation_closes_connection_on_success_and_failure(self):
        opened, connect = self.tracked_connections()
        with patch.object(queries, "connect", side_effect=connect):
            server = mcp_server.make_server(HOST, 0, self.db_path, TOKEN)
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].closed)
        server.server_close()

        invalid_path = os.path.join(self.tempdir.name, "invalid.sqlite3")
        pathlib.Path(invalid_path).write_bytes(b"not sqlite")
        opened, connect = self.tracked_connections()
        with patch.object(queries, "connect", side_effect=connect):
            with self.assertRaises(ValueError):
                mcp_server.make_server(HOST, 0, invalid_path, TOKEN)
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].closed)

    def test_failed_tool_query_closes_connection(self):
        opened, connect = self.tracked_connections()
        with patch.object(queries, "connect", side_effect=connect), \
                patch.object(queries, "list_metrics", side_effect=RuntimeError("query failure")):
            result = self.call("list_metrics")
        self.assertTrue(result["isError"])
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].closed)

    def test_atomic_replace_and_restore_without_restart(self):
        original_ids = {self.r1["id"], self.r2["id"], self.h1["id"]}
        self.assert_inventory({"steps", "heartRate"}, original_ids)
        backup = os.path.join(self.tempdir.name, "original.sqlite3")
        with closing(sqlite3.connect(self.db_path)) as source:
            with closing(sqlite3.connect(backup)) as target:
                source.backup(target)
        replacement = os.path.join(self.tempdir.name, "replacement.sqlite3")
        store_b = storage.RecordStore(replacement)
        record_b = make_record(metric="distanceWalkingRunning",
                               data={"type": "quantity", "value": 42, "unit": "m"})
        batch_created_at, changes = prepared(record_b)
        store_b.apply(changes, batch_created_at)
        os.replace(replacement, self.db_path)
        self.assert_inventory({"distanceWalkingRunning"}, {record_b["id"]})
        os.replace(backup, self.db_path)
        self.assert_inventory({"steps", "heartRate"}, original_ids)

    def assert_safe_failure(self):
        with self.assertLogs("vitalroute.query", level="ERROR") as logs:
            result = self.call("list_metrics")
        self.assertEqual(result, {
            "content": [{"type": "text", "text": "Query failed."}], "isError": True,
        })
        self.assertNotIn(self.db_path, "\n".join(logs.output))
        self.assertNotIn("Traceback", "\n".join(logs.output))
        self.assertNotIn("private-health-payload-not-a-database", "\n".join(logs.output))
        for record in (self.r1, self.r2, self.h1):
            self.assertNotIn(record["id"], "\n".join(logs.output))
        self.assertEqual(self.request("GET", "/healthz", token=None), (200, {"status": "ok"}))

    def test_missing_database_recovers_on_next_request(self):
        held = self.db_path + ".held"
        os.replace(self.db_path, held)
        try:
            self.assert_safe_failure()
            self.assertFalse(os.path.exists(self.db_path))
        finally:
            os.replace(held, self.db_path)
        self.assert_inventory({"steps", "heartRate"},
                              {self.r1["id"], self.r2["id"], self.h1["id"]})

    def test_incompatible_and_corrupt_database_recovers_on_next_request(self):
        held = self.db_path + ".held"
        os.replace(self.db_path, held)
        try:
            with closing(sqlite3.connect(self.db_path)) as incompatible:
                incompatible.execute("CREATE TABLE unrelated (value TEXT)")
                incompatible.commit()
            self.assert_safe_failure()
            os.remove(self.db_path)
            pathlib.Path(self.db_path).write_bytes(b"private-health-payload-not-a-database")
            self.assert_safe_failure()
        finally:
            os.replace(held, self.db_path)
        self.assert_inventory({"steps", "heartRate"},
                              {self.r1["id"], self.r2["id"], self.h1["id"]})

    def test_one_request_keeps_a_read_only_snapshot_and_closes_connection(self):
        connections = []

        def query_with_concurrent_write(connection):
            connections.append(connection)
            self.assertEqual(connection.execute("PRAGMA query_only").fetchone()[0], 1)
            before = connection.execute("SELECT COUNT(*) FROM records").fetchone()[0]
            with closing(sqlite3.connect(self.db_path)) as writer:
                writer.execute("DELETE FROM records WHERE id = ?", (self.r1["id"],))
                writer.commit()
            after = connection.execute("SELECT COUNT(*) FROM records").fetchone()[0]
            self.assertEqual((before, after), (3, 3))
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM records")
            return {"metrics": []}

        with patch.object(queries, "list_metrics", query_with_concurrent_write):
            self.assertNotIn("isError", self.call("list_metrics"))
        with self.assertRaises(sqlite3.ProgrammingError):
            connections[0].execute("SELECT 1")
        self.assert_inventory({"steps", "heartRate"}, {self.r2["id"], self.h1["id"]})


class ToolTests(QueryServerTestCase):

    def test_initialize_and_tools_list(self):
        status, body = self.rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "unit-tests", "version": "0"},
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(body["result"]["serverInfo"]["name"], "vitalroute-query")
        status, body = self.rpc("tools/list", msg_id=2)
        self.assertEqual(status, 200)
        names = {tool["name"] for tool in body["result"]["tools"]}
        self.assertEqual(names, {"list_metrics", "daily_stats", "recent_records"})

    def test_ping(self):
        status, body = self.rpc("ping", msg_id=7)
        self.assertEqual(status, 200)
        self.assertEqual(body["result"], {})

    def test_unauthorized_rejected(self):
        status, _ = self.rpc("ping", token=None)
        self.assertEqual(status, 401)
        status, _ = self.rpc("ping", token="wrong-token-0123456789abcdef")
        self.assertEqual(status, 401)

    def test_unknown_method_returns_jsonrpc_error(self):
        status, body = self.rpc("resources/list", msg_id=3)
        self.assertEqual(status, 200)
        self.assertEqual(body["error"]["code"], -32601)

    def test_malformed_json_is_parse_error(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            connection.request("POST", "/", body=b"{not json",
                               headers={"Authorization": "Bearer " + TOKEN})
            response = connection.getresponse()
            body = json.loads(response.read())
            self.assertEqual(response.status, 400)
            self.assertEqual(body["error"]["code"], -32700)
        finally:
            connection.close()

    def test_deeply_nested_json_answers_parse_error_not_connection_drop(self):
        # Adversarially deep nesting during json.loads raises RecursionError
        # (not a ValueError); the handler must convert it to the documented
        # parse error instead of letting it escape and drop the socket.
        depth = 100_000
        payload = ("[" * depth + "]" * depth).encode("utf-8")
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            connection.request("POST", "/", body=payload,
                               headers={"Authorization": "Bearer " + TOKEN,
                                        "Content-Type": "application/json"})
            response = connection.getresponse()
            body = json.loads(response.read())
            self.assertEqual(response.status, 400)
            self.assertEqual(body["error"]["code"], -32700)
        finally:
            connection.close()

    def test_get_healthz_and_405(self):
        status, body = self.request("GET", "/healthz", token=None)
        self.assertEqual((status, body["status"]), (200, "ok"))
        status, _ = self.request("GET", "/", token=TOKEN)
        self.assertEqual(status, 405)

    def _call(self, name, arguments=None, msg_id=5):
        _, body = self.rpc("tools/call", {"name": name, "arguments": arguments or {}}, msg_id=msg_id)
        return body["result"]

    def test_list_metrics(self):
        result = self._call("list_metrics")
        payload = json.loads(result["content"][0]["text"])
        by_metric = {m["metric"]: m for m in payload["metrics"]}
        self.assertEqual(by_metric["steps"]["records"], 2)
        self.assertEqual(by_metric["steps"]["kind"], "quantity")
        self.assertEqual(by_metric["steps"]["unit"], "count")
        self.assertEqual(by_metric["heartRate"]["records"], 1)
        self.assertEqual(by_metric["heartRate"]["unit"], "count/min")

    def test_daily_stats_days_and_range(self):
        result = self._call("daily_stats", {"days": 7})
        payload = json.loads(result["content"][0]["text"])
        days = {(d["date"], d["metric"], d["kind"]): d for d in payload["days"]}
        self.assertEqual(days[("2026-09-20", "steps", "quantity")]["sum"], 1000)
        self.assertEqual(days[("2026-09-20", "steps", "quantity")]["unit"], "count")
        self.assertEqual(days[("2026-09-21", "steps", "quantity")]["sum"], 2000)
        self.assertEqual(days[("2026-09-21", "heartRate", "quantity")]["avg"], 60)
        result = self._call("daily_stats", {"metric": "steps", "from": "2026-09-21", "to": "2026-09-21"})
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual([d["sum"] for d in payload["days"]], [2000])

    def test_daily_stats_rejects_bad_arguments(self):
        result = self._call("daily_stats", {"days": 0})
        self.assertTrue(result["isError"])
        result = self._call("daily_stats", {"from": "2026-09-21", "to": "2020-01-01"})
        self.assertTrue(result["isError"])

    def test_recent_records_bounded_and_ordered(self):
        result = self._call("recent_records", {"metric": "steps", "limit": 1})
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(len(payload["records"]), 1)
        # Newest first; the typed payload travels intact.
        record = payload["records"][0]
        self.assertEqual(record["data"]["value"], 2000)
        self.assertEqual(record["kind"], "quantity")

    def test_malformed_jsonrpc_shapes_never_drop_the_connection(self):
        # params as a non-dict must yield a JSON-RPC error, not a closed
        # socket.
        status, body = self.rpc("ping", params="not-a-dict", msg_id=9)
        self.assertEqual(status, 200)
        self.assertEqual(body["error"]["code"], -32602)
        # Batch arrays are rejected per MCP 2025-06-18.
        status, body = self.request("POST", "/", [
            {"jsonrpc": "2.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
        ])
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], -32600)
        # Unknown tool inside tools/call reports isError, not a protocol
        # error.
        result = self._call("no_such_tool", msg_id=10)
        self.assertTrue(result["isError"])

    def test_notifications_get_202_without_body(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            connection.request("POST", "/", body=json.dumps(
                {"jsonrpc": "2.0", "method": "notifications/initialized"}),
                headers={"Authorization": "Bearer " + TOKEN})
            response = connection.getresponse()
            self.assertEqual(response.status, 202)
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

    def test_unauthorized_response_closes_the_connection(self):
        # The 401 is emitted before the body is read; the server must close
        # so leftover bytes cannot poison a reused connection (the receiver
        # enforces the same invariant).
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            connection.request("POST", "/", body=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "ping"}) + " " * 64,
                headers={"Authorization": "Bearer wrong-token-0123456789"})
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            self.assertEqual(response.getheader("Connection"), "close")
            response.read()
            # The client honors the server's close: the socket is gone, so
            # no leftover request bytes can be misparsed on reuse.
            self.assertIsNone(connection.sock)
        finally:
            connection.close()

    def test_scalar_json_bodies_answer_and_keep_the_connection(self):
        for raw in (b"123", b'"hello"', b"null", b"true"):
            connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
            try:
                connection.request("POST", "/", body=raw,
                                   headers={"Authorization": "Bearer " + TOKEN})
                response = connection.getresponse()
                body = json.loads(response.read())
                self.assertEqual(response.status, 200)
                self.assertEqual(body["error"]["code"], -32600)
                # The connection must stay usable (no post-response crash).
                connection.request("POST", "/", body=json.dumps(
                    {"jsonrpc": "2.0", "id": 99, "method": "ping"}),
                    headers={"Authorization": "Bearer " + TOKEN})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())["result"], {})
            finally:
                connection.close()

    def test_explicit_id_null_is_a_request_not_a_notification(self):
        status, body = self.request("POST", "/", {
            "jsonrpc": "2.0", "id": None, "method": "ping",
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["result"], {})

    def test_initialize_without_id_still_answers(self):
        # Deliberate leniency pinned: a notification-shaped initialize
        # would hang a nonconforming client; this server answers it.
        status, body = self.request("POST", "/", {
            "jsonrpc": "2.0", "method": "initialize", "params": {},
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["serverInfo"]["name"], "vitalroute-query")

    def test_short_token_is_rejected_at_startup(self):
        with self.assertRaises(ValueError):
            mcp_server.make_server(HOST, 0, self.db_path, "too-short")

    def test_unknown_post_path_is_404(self):
        status, _ = self.request("POST", "/healthz", {"jsonrpc": "2.0", "id": 1, "method": "ping"})
        self.assertEqual(status, 404)

    def test_concurrent_tool_calls_with_independent_connections(self):
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(self._call, "list_metrics", {}, msg_id=100 + i)
                       for i in range(8)]
            for future in futures:
                result = future.result()
                self.assertNotIn("isError", result)

    def test_deleted_records_are_excluded_from_every_tool(self):
        # Delete r1 through the receiver's own validation + change pipeline,
        # exactly as a schema-3 sync batch would.
        payload = {
            "schemaVersion": 3,
            "createdAt": "2026-09-23T12:00:00.000Z",
            "batchId": str(uuid.uuid4()),
            "changes": [{
                "kind": "delete", "id": self.r1["id"], "metric": "steps",
                "startDate": "2026-09-20T10:00:00.000Z",
                "endDate": "2026-09-20T10:01:00.000Z",
            }],
        }
        from validation import validate_change_payload
        _, prepared = validate_change_payload(payload, 500)
        counts = self.store.apply(prepared, payload["createdAt"])
        self.assertEqual(counts.applied_deletions, 1)

        result = self._call("list_metrics")
        payload = json.loads(result["content"][0]["text"])
        steps = next(m for m in payload["metrics"] if m["metric"] == "steps")
        self.assertEqual(steps["records"], 1)
        self.assertEqual(payload["deletedIdsExcluded"], 1)

        result = self._call("daily_stats", {"metric": "steps", "days": 7})
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual([d["date"] for d in payload["days"]], ["2026-09-21"])

        result = self._call("recent_records", {"metric": "steps"})
        payload = json.loads(result["content"][0]["text"])
        self.assertTrue(all(rec["id"] != self.r1["id"] for rec in payload["records"]))


class QueryLayerTests(unittest.TestCase):
    """Direct tests for the bounded query layer (no HTTP)."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.db_path = os.path.join(self.tempdir.name, "records.sqlite3")
        self.store = storage.RecordStore(self.db_path)
        self.connection = queries.connect(self.db_path)
        self.addCleanup(self.connection.close)

    def test_empty_database_is_queryable(self):
        listing = queries.list_metrics(self.connection)
        self.assertEqual(listing["metrics"], [])
        stats = queries.daily_stats(self.connection, days=7)
        self.assertEqual(stats["days"], [])

    def test_metric_validation(self):
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, metric=123)
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, from_date="2026/09/20")
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, from_date="2026-02-30")  # impossible calendar date
        with self.assertRaises(queries.QueryError):
            queries.recent_records(self.connection, limit=999)

    def test_query_bounds_are_mandatory_and_exclusive(self):
        # Unbounded queries are rejected: this module is bounded by design.
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, metric="steps")
        # days and from/to are mutually exclusive.
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, days=7, from_date="2026-09-01")
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, days=7, to_date="2026-09-01")

    def test_read_only_enforcement(self):
        # mode=ro + query_only: the connection must refuse writes outright.
        with self.assertRaises(sqlite3.Error):
            self.connection.execute("DELETE FROM records")

    def test_recent_records_response_budget_truncates(self):
        # The response budget bounds one answer even when single records
        # carry large typed payloads.
        from validation import PreparedChange, PreparedRecord

        def store_big():
            record = make_record(
                id=str(uuid.uuid4()),
                metric="clinicalNote",
                kind="clinical",
                data={
                    "type": "clinical",
                    "fhirType": "DocumentReference",
                    "fhirResource": {"text": "x" * 900_000},
                },
            )
            prepared = PreparedChange(
                "upsert",
                record["id"],
                record["metric"],
                record=PreparedRecord(
                    id=record["id"], metric=record["metric"], kind=record["kind"],
                    start_date=record["startDate"], end_date=record["endDate"],
                    source_name=None, device_name=None,
                    metadata_json="{}", data_json=json.dumps(record["data"]),
                    parent_id=None,
                ),
            )
            self.store.apply([prepared], "2026-09-23T12:00:00.000Z")

        for _ in range(6):
            store_big()
        original_budget = queries.MAX_RECENT_RESPONSE_BYTES
        try:
            queries.MAX_RECENT_RESPONSE_BYTES = 2_000_000
            result = queries.recent_records(self.connection, limit=200)
            self.assertLess(len(result["records"]), 6)
            self.assertTrue(result["truncated"])
        finally:
            queries.MAX_RECENT_RESPONSE_BYTES = original_budget
        # With the real budget, 6 x ~900 KB records truncate again — and a
        # small result under the budget is not truncated.
        result = queries.recent_records(self.connection, limit=200)
        self.assertEqual(len(result["records"]), 4)
        self.assertTrue(result["truncated"])
        result = queries.recent_records(self.connection, metric="steps")
        self.assertFalse(result["truncated"])

    def test_non_quantity_kinds_are_counted_not_aggregated(self):
        # A workout (kind workout) must never feed a numeric aggregate.
        workout = make_record(
            id=str(uuid.uuid4()),
            metric="workouts",
            kind="workout",
            startDate="2026-09-21T08:00:00.000Z",
            endDate="2026-09-21T08:30:00.000Z",
            data={
                "type": "workout",
                "activityType": "running",
                "activityTypeRawValue": 52,
                "duration": 1800.0,
            },
        )
        batch_created_at, prepared_changes = prepared(workout)
        self.store.apply(prepared_changes, batch_created_at)

        listing = queries.list_metrics(self.connection)
        workout_row = next(m for m in listing["metrics"] if m["metric"] == "workouts")
        self.assertEqual(workout_row["kind"], "workout")
        self.assertIsNone(workout_row["unit"])

        stats = queries.daily_stats(self.connection, metric="workouts", days=7)
        day = stats["days"][0]
        self.assertEqual(day["count"], 1)
        self.assertIsNone(day["sum"])
        self.assertIsNone(day["avg"])

        recent = queries.recent_records(self.connection, metric="workouts")
        self.assertEqual(recent["records"][0]["data"]["activityType"], "running")

    def test_unknown_metrics_surface_without_a_catalog(self):
        # The receiver has no metric catalog: an unknown-but-well-formed
        # metric appears in listings like any other.
        record = make_record(id=str(uuid.uuid4()), metric="someFutureMetric",
                             data={"type": "quantity", "value": 7, "unit": "parrot"})
        batch_created_at, prepared_changes = prepared(record)
        self.store.apply(prepared_changes, batch_created_at)
        listing = queries.list_metrics(self.connection)
        row = next(m for m in listing["metrics"] if m["metric"] == "someFutureMetric")
        self.assertEqual(row["unit"], "parrot")

    def test_range_cap(self):
        with self.assertRaises(queries.QueryError):
            queries.daily_stats(self.connection, from_date="2020-01-01", to_date="2026-01-01")


if __name__ == "__main__":
    unittest.main()
