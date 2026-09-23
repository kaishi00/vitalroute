"""Tests for the VitalRoute reference receiver.

Runs a real server on an ephemeral port with a temporary SQLite database and
exercises the full HTTP surface with synthetic records only.
"""

import http.client
import json
import os
import pathlib
import sys
import tempfile
import threading
import time
import unittest
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import receiver  # noqa: E402
import storage  # noqa: E402
import validation  # noqa: E402

TOKEN = "unit-test-token-0123456789abcdef"
HOST = "127.0.0.1"


def make_record(**overrides):
    record = {
        "id": str(uuid.uuid4()),
        "metric": "steps",
        "value": 8000,
        "unit": "count",
        "startDate": "2026-09-20T00:00:00.000Z",
        "endDate": "2026-09-20T23:59:59.000Z",
        "sourceName": "Synthetic Source",
        "deviceName": "Synthetic Device",
        "metadata": {"origin": "unit-test"},
    }
    record.update(overrides)
    return record


def make_payload(records):
    return {
        "schemaVersion": 1,
        "createdAt": "2026-09-23T12:00:00.000Z",
        "records": records,
    }


class ReceiverServerTestCase(unittest.TestCase):
    """Base fixture: one server per test, isolated temp database."""

    max_body_bytes = validation.DEFAULT_MAX_BODY_BYTES
    max_records = validation.DEFAULT_MAX_RECORDS_PER_BATCH

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tempdir.name, "records.sqlite3")
        self.server = receiver.make_server(
            HOST,
            0,
            self.db_path,
            TOKEN,
            max_body_bytes=self.max_body_bytes,
            max_records_per_batch=self.max_records,
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop_server)

    def _stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.tempdir.cleanup()

    def request(self, method, path, body=None, token=TOKEN, content_type="application/json"):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        headers = {"Accept": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            headers["Content-Type"] = content_type
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        response_body = response.read()
        connection.close()
        parsed = None
        if response_body:
            try:
                parsed = json.loads(response_body.decode("utf-8"))
            except ValueError:
                parsed = response_body
        return response.status, parsed, response

    def get(self, path, **kwargs):
        status, body, _ = self.request("GET", path, **kwargs)
        return status, body

    def post(self, path, body=None, **kwargs):
        status, parsed, _ = self.request("POST", path, body=body, **kwargs)
        return status, parsed

    def stored_count(self):
        return storage.RecordStore(self.db_path).record_count()

    def stored_rows(self):
        import sqlite3

        connection = sqlite3.connect(self.db_path)
        try:
            connection.row_factory = sqlite3.Row
            return [dict(row) for row in connection.execute("SELECT * FROM records")]
        finally:
            connection.close()

    def assertErrorCode(self, status, body, code):
        self.assertEqual(body.get("error", {}).get("code"), code)
        # Error responses must not echo payloads or credentials.
        self.assertNotIn(TOKEN, json.dumps(body))


class ConnectionTestTests(ReceiverServerTestCase):
    def test_requires_auth(self):
        status, body = self.get("/v1/records", token=None)
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

        status, body = self.get("/v1/records", token="wrong-token-aaaaaaaaaaaa")
        self.assertEqual(status, 401)

    def test_www_authenticate_header_present(self):
        _, _, response = self.request("GET", "/v1/records", token=None)
        self.assertEqual(response.getheader("WWW-Authenticate"), "Bearer")

    def test_success_shape(self):
        status, body = self.get("/v1/records")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["service"], "vitalroute-receiver")
        self.assertEqual(body["apiVersion"], 2)
        self.assertEqual(body["capabilities"], ["additions", "deletions"])
        # A connection test must never store anything.
        self.assertEqual(self.stored_count(), 0)

    def test_health_alias(self):
        status, body = self.get("/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_rejects_body(self):
        status, body = self.request(
            "GET", "/v1/records", body=make_payload([make_record()])
        )[0:2]
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "connection_test_body_not_allowed")
        self.assertEqual(self.stored_count(), 0)


class AuthenticationTests(ReceiverServerTestCase):
    def test_ingestion_requires_auth(self):
        status, body = self.post("/v1/records", make_payload([make_record()]), token=None)
        self.assertEqual(status, 401)
        self.assertEqual(self.stored_count(), 0)

    def test_raw_unknown_scheme_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        body = json.dumps(make_payload([make_record()])).encode("utf-8")
        headers = {
            "Authorization": "Basic dXNlcjpwYXNz",
            "Content-Type": "application/json",
        }
        connection.request("POST", "/v1/records", body=body, headers=headers)
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 401)

    def test_empty_token_rejected(self):
        status, body = self.post("/v1/records", make_payload([make_record()]), token="")
        self.assertEqual(status, 401)

    def test_server_refuses_to_start_without_token(self):
        with self.assertRaises(ValueError):
            receiver.make_server(HOST, 0, ":memory:", "")
        with self.assertRaises(ValueError):
            receiver.make_server(HOST, 0, ":memory:", "short")


class IngestionTests(ReceiverServerTestCase):
    def test_valid_batch_persists_and_acks(self):
        records = [
            make_record(),
            make_record(
                metric="heartRateVariability",
                value=48.2,
                unit="ms",
                startDate="2026-09-21T08:00:00.123Z",
                endDate="2026-09-21T08:00:00.123Z",
                sourceName=None,
                deviceName=None,
                metadata={},
            ),
            make_record(
                metric="sleep",
                value=28800,
                unit="s",
                startDate="2026-09-21T22:00:00.000-05:00",
                endDate="2026-09-22T06:00:00.000-05:00",
                metadata={"sleepStage": "asleepCore"},
            ),
        ]
        status, body = self.post("/v1/records", make_payload(records))
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "accepted")
        self.assertEqual(body["accepted"], 3)
        self.assertEqual(body["duplicates"], 0)
        self.assertEqual(body["schemaVersion"], 1)

        rows = self.stored_rows()
        self.assertEqual(len(rows), 3)
        by_id = {row["id"]: row for row in rows}
        self.assertIn(records[0]["id"].lower(), by_id)

        # Dates normalize to UTC milliseconds.
        sleep_row = by_id[records[2]["id"].lower()]
        self.assertEqual(sleep_row["start_date"], "2026-09-22T03:00:00.000Z")
        self.assertEqual(sleep_row["end_date"], "2026-09-22T11:00:00.000Z")
        self.assertEqual(json.loads(sleep_row["metadata"]), {"sleepStage": "asleepCore"})
        self.assertIsNone(by_id[records[1]["id"].lower()]["source_name"])

    def test_ingestion_is_idempotent_for_full_retry(self):
        records = [make_record(), make_record()]
        status, first = self.post("/v1/records", make_payload(records))
        self.assertEqual(status, 200)
        status, second = self.post("/v1/records", make_payload(records))
        self.assertEqual(status, 200)
        self.assertEqual(second["accepted"], 0)
        self.assertEqual(second["duplicates"], 2)
        self.assertEqual(self.stored_count(), 2)

    def test_partial_duplicates_counted(self):
        existing = make_record()
        self.post("/v1/records", make_payload([existing]))
        fresh = make_record()
        status, body = self.post("/v1/records", make_payload([existing, fresh]))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)
        self.assertEqual(body["duplicates"], 1)
        self.assertEqual(self.stored_count(), 2)

    def test_first_write_wins_for_same_id(self):
        record = make_record(value=100)
        self.post("/v1/records", make_payload([record]))
        status, body = self.post(
            "/v1/records", make_payload([make_record(id=record["id"], value=999)])
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["duplicates"], 1)
        rows = [row for row in self.stored_rows() if row["id"] == record["id"].lower()]
        self.assertEqual(rows[0]["value"], 100)

    def test_duplicate_ids_within_one_batch(self):
        record = make_record()
        status, body = self.post("/v1/records", make_payload([record, dict(record)]))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)
        self.assertEqual(body["duplicates"], 1)

    def test_batch_is_atomic(self):
        good = make_record()
        bad = make_record(id="not-a-uuid")
        status, body = self.post("/v1/records", make_payload([good, bad]))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_record")
        self.assertEqual(self.stored_count(), 0)

    def test_concurrent_duplicate_ingestion(self):
        record = make_record()
        results = []
        errors = []

        def send():
            try:
                results.append(self.post("/v1/records", make_payload([record])))
            except Exception as error:  # pragma: no cover - surfaced via assert
                errors.append(error)

        threads = [threading.Thread(target=send) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
        self.assertEqual(errors, [])
        self.assertEqual(self.stored_count(), 1)
        total_accepted = sum(body["accepted"] for _, body in results)
        self.assertEqual(total_accepted, 1)


class IngestionValidationTests(ReceiverServerTestCase):
    def post_expect(self, code, payload=None, raw=None, status=400):
        body = raw if raw is not None else json.dumps(payload or make_payload([make_record()]))
        result_status, result_body = self.post("/v1/records", body)
        self.assertEqual(result_status, status)
        self.assertEqual(result_body["error"]["code"], code)
        self.assertEqual(self.stored_count(), 0)

    def test_rejects_malformed_json(self):
        self.post_expect("invalid_json", raw=b"{not json")

    def test_rejects_wrong_content_type(self):
        status, body = self.post(
            "/v1/records", make_payload([make_record()]), content_type="text/plain"
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_content_type")

    def test_rejects_unknown_top_level_fields(self):
        payload = make_payload([make_record()])
        payload["extra"] = 1
        self.post_expect("invalid_payload", payload)

    def test_rejects_missing_top_level_fields(self):
        payload = make_payload([make_record()])
        del payload["createdAt"]
        self.post_expect("invalid_payload", payload)

    def test_rejects_unsupported_schema_version(self):
        payload = make_payload([make_record()])
        payload["schemaVersion"] = 3
        self.post_expect("unsupported_schema_version", payload)

    def test_v1_shape_with_v2_version_is_invalid_payload(self):
        # The version selects the schema; a v1-shaped body claiming version 2
        # is a shape violation, not a version problem.
        payload = make_payload([make_record()])
        payload["schemaVersion"] = 2
        self.post_expect("invalid_payload", payload)

    def test_rejects_empty_batch(self):
        self.post_expect("empty_batch", make_payload([]))

    def test_rejects_unknown_metric(self):
        self.post_expect("unknown_metric", make_payload([make_record(metric="bloodPressure")]))

    def test_rejects_invalid_uuid(self):
        self.post_expect("invalid_record", make_payload([make_record(id="6f9619ff-8b86-xxxx-b42d-00c04fc964ff")]))

    def test_rejects_naive_dates(self):
        self.post_expect(
            "invalid_record",
            make_payload([make_record(startDate="2026-09-20T00:00:00")]),
        )

    def test_rejects_end_before_start(self):
        self.post_expect(
            "invalid_record",
            make_payload(
                [
                    make_record(
                        startDate="2026-09-21T00:00:00.000Z",
                        endDate="2026-09-20T00:00:00.000Z",
                    )
                ]
            ),
        )

    def test_rejects_non_finite_values(self):
        raw = json.dumps(make_payload([make_record()])).replace("8000", "NaN").encode("utf-8")
        self.post_expect("invalid_record", raw=raw)

    def test_rejects_boolean_value(self):
        self.post_expect("invalid_record", make_payload([make_record(value=True)]))

    def test_rejects_unknown_record_fields(self):
        record = make_record()
        record["extra"] = "x"
        self.post_expect("invalid_record", make_payload([record]))

    def test_rejects_non_string_metadata_value(self):
        record = make_record()
        record["metadata"] = {"count": 5}
        self.post_expect("invalid_record", make_payload([record]))

    def test_rejects_empty_unit(self):
        self.post_expect("invalid_record", make_payload([make_record(unit="")]))

    def test_whole_second_timestamps_accepted(self):
        record = make_record(
            startDate="2026-09-20T00:00:00Z", endDate="2026-09-20T03:00:00+02:00"
        )
        status, body = self.post("/v1/records", make_payload([record]))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)

    def test_swift_spelling_without_optional_fields_accepted(self):
        # Swift's synthesized Codable omits nil optionals rather than writing
        # null, so the wire format the iOS client actually produces has seven
        # keys per record.
        record = {key: value for key, value in make_record().items()
                  if key not in ("sourceName", "deviceName")}
        status, body = self.post("/v1/records", make_payload([record]))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)
        rows = self.stored_rows()
        self.assertIsNone(rows[0]["source_name"])
        self.assertIsNone(rows[0]["device_name"])


class IngestionLimitTests(ReceiverServerTestCase):
    max_records = 3

    def test_rejects_too_many_records(self):
        records = [make_record() for _ in range(4)]
        status, body = self.post("/v1/records", make_payload(records))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "too_many_records")


class IngestionBodySizeTests(ReceiverServerTestCase):
    max_body_bytes = 2048

    def test_rejects_oversized_body(self):
        # Pad a metadata value to push the body over the configured limit.
        record = make_record()
        record["metadata"] = {"padding": "x" * 4096}
        status, body = self.post("/v1/records", make_payload([record]))
        self.assertEqual(status, 413)
        self.assertEqual(body["error"]["code"], "payload_too_large")
        self.assertEqual(self.stored_count(), 0)


class RoutingTests(ReceiverServerTestCase):
    def test_unknown_path_is_404(self):
        status, body = self.post("/v1/other", make_payload([make_record()]))
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")

        status, body = self.get("/admin")
        self.assertEqual(status, 404)

    def test_query_string_is_not_part_of_the_contract(self):
        status, body = self.get("/v1/records?token=" + TOKEN)
        self.assertEqual(status, 404)

    def test_unsupported_method_is_405(self):
        status, _, response = self.request("PUT", "/v1/records", body=b"{}")
        self.assertEqual(status, 405)
        self.assertIn("GET", response.getheader("Allow") or "")

        status, _, _ = self.request("DELETE", "/v1/records")
        self.assertEqual(status, 405)

    def test_head_and_options_get_safe_json_errors(self):
        status, body = self.request("HEAD", "/v1/records")[0:2]
        self.assertEqual(status, 405)
        # HEAD responses carry no body; the code is visible via the log line.
        status, body = self.request("OPTIONS", "/v1/records")[0:2]
        self.assertEqual(status, 405)
        self.assertEqual(body["error"]["code"], "method_not_allowed")

    def test_post_to_health_path_is_405(self):
        status, body = self.post("/v1/health", make_payload([make_record()]))
        self.assertEqual(status, 405)
        self.assertEqual(body["error"]["code"], "method_not_allowed")
        self.assertEqual(self.stored_count(), 0)

    def test_negative_content_length_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", "-5")
        connection.endheaders()
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        self.assertEqual(response.status, 400)
        self.assertEqual(body["error"]["code"], "invalid_content_length")

    def test_transfer_encoding_rejected_on_ingestion(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        connection.send(b"2\r\n{}\r\n0\r\n\r\n")
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        self.assertEqual(response.status, 400)
        self.assertEqual(body["error"]["code"], "invalid_transfer_encoding")
        self.assertEqual(self.stored_count(), 0)

    def test_error_responses_have_safe_shape(self):
        status, body = self.get("/v1/records", token=None)
        self.assertEqual(set(body.keys()), {"error"})
        self.assertEqual(set(body["error"].keys()), {"code", "message"})

    def test_missing_content_length_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        connection.send(b"2\r\n{}\r\n0\r\n\r\n")
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 400)

    def test_connection_is_reusable_after_errors_that_did_read_the_body(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        try:
            # 1) A valid request primes the connection.
            connection.request(
                "GET", "/v1/records", headers={"Authorization": "Bearer " + TOKEN}
            )
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200)

            # 2) An error whose body was fully read must not poison framing.
            bad = json.dumps(make_payload([make_record(id="not-a-uuid")])).encode("utf-8")
            connection.request(
                "POST",
                "/v1/records",
                body=bad,
                headers={
                    "Authorization": "Bearer " + TOKEN,
                    "Content-Type": "application/json",
                },
            )
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 400)

            # 3) The same connection still serves the next request.
            connection.request(
                "GET", "/v1/records", headers={"Authorization": "Bearer " + TOKEN}
            )
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200)
        finally:
            connection.close()

    def test_error_before_body_read_closes_the_connection(self):
        # Unauthorized POST with a body: the server must close the
        # connection rather than leave the unread body to be parsed as a
        # subsequent request (request-smuggling framing).
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        body = json.dumps(make_payload([make_record()])).encode("utf-8")
        connection.request(
            "POST",
            "/v1/records",
            body=body,
            headers={
                "Authorization": "Bearer wrong-token-aaaaaaaaa",
                "Content-Type": "application/json",
            },
        )
        response = connection.getresponse()
        response.read()
        self.assertEqual(response.status, 401)
        self.assertEqual(response.getheader("Connection"), "close")
        connection.close()


class SlowClientTimeoutTests(unittest.TestCase):
    """A stalling client must lose its worker to the socket timeout."""

    def test_stalled_body_is_cut_off(self):
        import socket
        import subprocess

        with tempfile.TemporaryDirectory() as tempdir:
            db_path = os.path.join(tempdir, "records.sqlite3")
            # Pick a free port instead of hardcoding one.
            probe_listener = socket.socket()
            probe_listener.bind((HOST, 0))
            port = probe_listener.getsockname()[1]
            probe_listener.close()
            environment = dict(os.environ)
            environment["VITALROUTE_TOKEN"] = TOKEN
            environment["VITALROUTE_DB"] = db_path
            environment["VITALROUTE_SOCKET_TIMEOUT"] = "1"
            process = subprocess.Popen(
                [
                    sys.executable,
                    os.path.join(
                        os.path.dirname(os.path.abspath(__file__)),
                        "..",
                        "receiver.py",
                    ),
                    "--host",
                    HOST,
                    "--port",
                    str(port),
                ],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                # Wait for the listener.
                deadline = time.time() + 10
                while time.time() < deadline:
                    try:
                        probe = socket.create_connection((HOST, port), timeout=1)
                        probe.close()
                        break
                    except OSError:
                        time.sleep(0.1)
                else:
                    self.fail("receiver never started")

                connection = socket.create_connection((HOST, port), timeout=10)
                headers = (
                    "POST /v1/records HTTP/1.1\r\n"
                    "Host: %s:%d\r\n"
                    "Authorization: Bearer %s\r\n"
                    "Content-Type: application/json\r\n"
                    "Content-Length: 100\r\n\r\n"
                ) % (HOST, port, TOKEN)
                connection.sendall(headers.encode("utf-8"))
                # Send part of the body, then stall.
                connection.sendall(b'{"schemaVersion":1,')

                closed_within_timeout = False
                stall_deadline = time.time() + 5
                while time.time() < stall_deadline:
                    if connection.recv(1) == b"":
                        closed_within_timeout = True
                        break
                connection.close()
                self.assertTrue(
                    closed_within_timeout, "server left a stalled client connected"
                )
            finally:
                process.terminate()
                process.wait(timeout=5)


def make_change_payload(changes):
    return {
        "schemaVersion": 2,
        "createdAt": "2026-09-24T12:00:00.000Z",
        "batchId": "7f6c1a2e-9b34-4d05-8c11-2f0a54d7b901",
        "changes": changes,
    }


def make_upsert(record=None):
    return {"kind": "upsert", "record": record or make_record()}


def make_delete(record_id=None, metric="steps"):
    return {
        "kind": "delete",
        "id": record_id or str(uuid.uuid4()),
        "metric": metric,
        "startDate": "2026-09-20T00:00:00.000Z",
        "endDate": "2026-09-20T23:59:59.000Z",
    }


class ChangeBatchTests(ReceiverServerTestCase):
    def stored_count(self):
        return storage.RecordStore(self.db_path).record_count()

    def tombstones(self):
        return storage.ChangeApplier(self.db_path).tombstones()

    def test_v2_batch_persists_upserts_and_deletions(self):
        keep = make_record()
        drop = make_record()
        status, body = self.post("/v1/records", make_change_payload([
            make_upsert(keep),
            make_upsert(drop),
        ]))
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "accepted")
        self.assertEqual(body["accepted"], 2)
        self.assertEqual(body["duplicates"], 0)
        self.assertEqual(body["superseded"], 0)
        self.assertEqual(body["appliedDeletions"], 0)
        self.assertEqual(body["duplicateDeletions"], 0)
        self.assertEqual(self.stored_count(), 2)

        status, body = self.post("/v1/records", make_change_payload([
            make_delete(record_id=drop["id"]),
        ]))
        self.assertEqual(status, 200)
        self.assertEqual(body["appliedDeletions"], 1)
        self.assertEqual(body["duplicateDeletions"], 0)
        self.assertEqual(self.stored_count(), 1)
        self.assertIn(drop["id"].lower(), self.tombstones())
        self.assertNotIn(keep["id"].lower(), self.tombstones())

    def test_retried_deletion_is_idempotent(self):
        delete = make_delete()
        self.post("/v1/records", make_change_payload([delete]))
        status, body = self.post("/v1/records", make_change_payload([delete]))
        self.assertEqual(status, 200)
        self.assertEqual(body["appliedDeletions"], 0)
        self.assertEqual(body["duplicateDeletions"], 1)

    def test_tombstone_prevents_resurrection_by_older_addition(self):
        record = make_record()
        self.post("/v1/records", make_change_payload([
            make_upsert(record),
            make_delete(record_id=record["id"]),
        ]))
        self.assertEqual(self.stored_count(), 0)

        # A stale queued addition replayed after the deletion must not
        # resurrect the sample.
        status, body = self.post("/v1/records", make_change_payload([
            make_upsert(record),
        ]))
        self.assertEqual(status, 200)
        self.assertEqual(body["superseded"], 1)
        self.assertEqual(body["accepted"], 0)
        self.assertEqual(self.stored_count(), 0)

    def test_deletion_of_unknown_id_creates_tombstone(self):
        # Deletion-only flow: tombstones must exist even for ids never seen,
        # so a later-arriving addition is suppressed.
        record_id = str(uuid.uuid4())
        status, body = self.post("/v1/records", make_change_payload([
            make_delete(record_id=record_id),
        ]))
        self.assertEqual(body["appliedDeletions"], 1)
        self.assertIn(record_id.lower(), self.tombstones())

        status, body = self.post("/v1/records", make_change_payload([
            make_upsert(make_record(id=record_id)),
        ]))
        self.assertEqual(body["superseded"], 1)
        self.assertEqual(self.stored_count(), 0)

    def test_full_batch_retry_is_idempotent(self):
        changes = [make_upsert(make_record()), make_delete()]
        first = self.post("/v1/records", make_change_payload(changes))[1]
        second = self.post("/v1/records", make_change_payload(changes))[1]
        self.assertEqual(second["accepted"], 0)
        self.assertEqual(second["duplicates"], 1)
        self.assertEqual(second["appliedDeletions"], 0)
        self.assertEqual(second["duplicateDeletions"], 1)

    def test_v1_ingestion_still_works_alongside_v2(self):
        record = make_record()
        status, body = self.post("/v1/records", make_payload([record]))
        self.assertEqual(status, 200)
        self.assertEqual(body["schemaVersion"], 1)
        self.assertEqual(self.stored_count(), 1)

    def test_bad_change_rolls_back_whole_batch(self):
        good = make_upsert()
        bad = {"kind": "delete", "id": "not-a-uuid", "metric": "steps",
               "startDate": "2026-09-20T00:00:00.000Z", "endDate": "2026-09-20T01:00:00.000Z"}
        status, body = self.post("/v1/records", make_change_payload([good, bad]))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_record")
        self.assertEqual(self.stored_count(), 0)
        self.assertEqual(len(self.tombstones()), 0)

    def test_unknown_change_kind_rejected(self):
        payload = make_change_payload([{"kind": "patch", "record": make_record()}])
        status, body = self.post("/v1/records", payload)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_record")

    def test_v2_rejects_empty_changes(self):
        status, body = self.post("/v1/records", make_change_payload([]))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "empty_batch")

    def test_v2_rejects_missing_batch_id(self):
        payload = make_change_payload([make_upsert()])
        del payload["batchId"]
        status, body = self.post("/v1/records", payload)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_payload")

    def test_v2_upsert_record_validation_matches_v1(self):
        record = make_record(unit="")
        status, body = self.post("/v1/records", make_change_payload([make_upsert(record)]))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_record")


class MigrationTests(unittest.TestCase):
    def test_v1_database_migrates_additively(self):
        with tempfile.TemporaryDirectory() as tempdir:
            db_path = os.path.join(tempdir, "records.sqlite3")
            record_store = storage.RecordStore(db_path)
            record = make_record()
            record_tuple = validation._validate_record(record, 0)
            record_store.ingest([record_tuple], "2026-09-23T00:00:00.000Z")

            # Opening the applier migrates: tombstone table added, v1 rows
            # and ingestion behavior untouched.
            applier = storage.ChangeApplier(db_path)
            self.assertEqual(applier.tombstones(), set())
            self.assertEqual(storage.RecordStore(db_path).record_count(), 1)

            change = validation._validate_change(
                {"kind": "delete", "id": record["id"], "metric": record["metric"],
                 "startDate": record["startDate"], "endDate": record["endDate"]}, 0
            )
            counts = applier.apply([change], "2026-09-24T00:00:00.000Z")
            self.assertEqual(counts.applied_deletions, 1)
            self.assertEqual(storage.RecordStore(db_path).record_count(), 0)
            self.assertIn(record["id"].lower(), applier.tombstones())


class ValidationUnitTests(unittest.TestCase):
    def test_timestamp_parser_accepts_contract_forms(self):
        cases = {
            "2026-09-23T12:00:00.000Z": "2026-09-23T12:00:00.000Z",
            "2026-09-23T12:00:00Z": "2026-09-23T12:00:00.000Z",
            "2026-09-23T12:00:00.123456789Z": "2026-09-23T12:00:00.123Z",
            "2026-09-23T14:00:00.500+02:00": "2026-09-23T12:00:00.500Z",
        }
        for raw, expected in cases.items():
            self.assertEqual(
                validation.format_timestamp_utc(validation.parse_timestamp(raw, "test")),
                expected,
            )

    def test_timestamp_parser_rejects_naive_and_garbage(self):
        for bad in ["2026-09-23T12:00:00", "not-a-date", "2026-09-23 12:00:00Z", ""]:
            with self.assertRaises(validation.ValidationError):
                validation.parse_timestamp(bad, "test")


if __name__ == "__main__":
    unittest.main()
