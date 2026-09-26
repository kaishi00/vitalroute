"""Tests for the VitalRoute reference receiver (contract v3).

Runs a real server on an ephemeral port with a temporary SQLite database and
exercises the full HTTP surface with synthetic records only.
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import receiver  # noqa: E402
import storage  # noqa: E402
import validation  # noqa: E402

TOKEN = "unit-test-token-0123456789abcdef"
HOST = "127.0.0.1"


def make_record(**overrides):
    """A valid schema-3 record envelope with a quantity payload."""
    record = {
        "id": str(uuid.uuid4()),
        "metric": "steps",
        "kind": "quantity",
        "startDate": "2026-09-20T00:00:00.000Z",
        "endDate": "2026-09-20T23:59:59.000Z",
        "sourceName": "Synthetic Source",
        "deviceName": "Synthetic Device",
        "metadata": {"origin": "unit-test"},
        "data": {"type": "quantity", "value": 8000, "unit": "count"},
    }
    record.update(overrides)
    return record


def make_delete(record_id=None, **overrides):
    change = {
        "kind": "delete",
        "id": record_id or str(uuid.uuid4()),
        "metric": "steps",
        "startDate": "2026-09-20T00:00:00.000Z",
        "endDate": "2026-09-20T23:59:59.000Z",
    }
    change.update(overrides)
    return change


def make_changes(*changes):
    return list(changes)


def make_payload(changes):
    return {
        "schemaVersion": 3,
        "createdAt": "2026-09-23T12:00:00.000Z",
        "batchId": str(uuid.uuid4()),
        "changes": changes,
    }


def make_upsert(record):
    return {"kind": "upsert", "record": record}


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
        connection = sqlite3.connect(self.db_path)
        try:
            connection.row_factory = sqlite3.Row
            return [dict(row) for row in connection.execute("SELECT * FROM records")]
        finally:
            connection.close()

    def tombstoned_ids(self):
        return storage.RecordStore(self.db_path).tombstones()

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
        self.assertEqual(body["apiVersion"], 3)
        self.assertEqual(body["capabilities"], ["additions", "deletions"])
        # A connection test must never store anything.
        self.assertEqual(self.stored_count(), 0)

    def test_health_alias(self):
        status, body = self.get("/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_rejects_body(self):
        status, body = self.request(
            "GET", "/v1/records", body=make_payload(make_changes(make_upsert(make_record())))
        )[0:2]
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "connection_test_body_not_allowed")
        self.assertEqual(self.stored_count(), 0)


class AuthenticationTests(ReceiverServerTestCase):
    def test_ingestion_requires_auth(self):
        status, body = self.post(
            "/v1/records", make_payload(make_changes(make_upsert(make_record()))), token=None
        )
        self.assertEqual(status, 401)
        self.assertEqual(self.stored_count(), 0)

    def test_raw_unknown_scheme_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        body = json.dumps(make_payload(make_changes(make_upsert(make_record())))).encode("utf-8")
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
        status, body = self.post(
            "/v1/records", make_payload(make_changes(make_upsert(make_record()))), token=""
        )
        self.assertEqual(status, 401)

    def test_server_refuses_to_start_without_token(self):
        with self.assertRaises(ValueError):
            receiver.make_server(HOST, 0, os.path.join(self.tempdir.name, "a.sqlite3"), "")
        with self.assertRaises(ValueError):
            receiver.make_server(HOST, 0, os.path.join(self.tempdir.name, "b.sqlite3"), "short")


class RecordKindTests(ReceiverServerTestCase):
    """One valid record per contract kind ingests and stores its data JSON."""

    def post_and_expect_accepted(self, changes, accepted):
        status, body = self.post("/v1/records", make_payload(changes))
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "accepted")
        self.assertEqual(body["accepted"], accepted)
        self.assertEqual(body["schemaVersion"], 3)
        return body

    def test_all_kinds_ingest(self):
        series_id = str(uuid.uuid4())
        parent_id = str(uuid.uuid4())
        records = [
            make_record(metric="heartRate", data={"type": "quantity", "value": 61.5, "unit": "count/min"}),
            make_record(metric="sleep", kind="category", data={"type": "category", "value": 3, "name": "asleepREM"}),
            make_record(metric="bloodPressure", kind="correlation", data={
                "type": "correlation",
                "components": [
                    {"metric": "bloodPressureSystolic", "value": 122, "unit": "mmHg"},
                    {"metric": "bloodPressureDiastolic", "value": 78, "unit": "mmHg"},
                ],
            }),
            make_record(metric="workouts", kind="workout", data={
                "type": "workout",
                "activityType": "running",
                "activityTypeRawValue": 52,
                "duration": 1920.0,
                "totalEnergyKilocalories": 331.2,
                "totalDistanceMeters": 5210.5,
            }),
            make_record(metric="activitySummary", kind="activitySummary", data={
                "type": "activitySummary",
                "activeEnergyBurnedKilocalories": 501.0,
                "exerciseTimeMinutes": 32,
                "dateComponentsUTC": "2026-09-20",
            }),
            make_record(metric="workoutRoute", kind="series", data={
                "type": "series",
                "seriesType": "workoutRoute",
                "seriesID": series_id,
                "parentID": parent_id,
                "chunkIndex": 0,
                "channels": ["t", "lat", "lon", "alt", "speed"],
                "points": [[0.0, 47.6, -122.3, 40.0, 3.2], [0.5, 47.61, -122.31, 41.0, 3.5]],
            }),
            make_record(metric="electrocardiogram", kind="electrocardiogram", data={
                "type": "electrocardiogram",
                "classification": "sinusRhythm",
                "classificationRawValue": 2,
                "symptomStatus": "none",
                "averageHeartRate": 62.0,
                "samplingFrequency": 512.0,
                "voltageSeriesID": series_id,
                "voltageChunkCount": 1,
            }),
            make_record(metric="clinicalCondition", kind="clinical", data={
                "type": "clinical",
                "fhirType": "Condition",
                "fhirIdentifier": "example-1",
                "fhirResource": {
                    "resourceType": "Condition",
                    "code": {"text": "Example"},
                    "clinicalStatus": {"coding": [{"code": "active"}]},
                },
            }),
        ]
        self.post_and_expect_accepted(make_changes(*[make_upsert(r) for r in records]), 8)

        rows = self.stored_rows()
        self.assertEqual(len(rows), 8)
        by_kind = {row["kind"]: row for row in rows}
        self.assertEqual(by_kind["quantity"]["data_json"], '{"type":"quantity","unit":"count/min","value":61.5}')
        self.assertEqual(by_kind["category"]["kind"], "category")
        correlation = json.loads(by_kind["correlation"]["data_json"])
        self.assertEqual(len(correlation["components"]), 2)
        workout = json.loads(by_kind["workout"]["data_json"])
        self.assertEqual(workout["activityType"], "running")
        series_row = by_kind["series"]
        self.assertEqual(series_row["parent_id"], parent_id.lower())
        series = json.loads(series_row["data_json"])
        self.assertEqual(series["seriesType"], "workoutRoute")
        self.assertEqual(len(series["points"]), 2)
        clinical = json.loads(by_kind["clinical"]["data_json"])
        self.assertEqual(clinical["fhirResource"]["resourceType"], "Condition")

    def test_unknown_metric_accepted_when_structure_valid(self):
        # The receiver does not know the metric catalog: any well-formed
        # identifier is accepted as long as kind and data shape are valid.
        record = make_record(metric="someFutureMetric.v2", data={"type": "quantity", "value": 1, "unit": "count"})
        self.post_and_expect_accepted(make_changes(make_upsert(record)), 1)

    def test_category_without_name_accepted(self):
        record = make_record(metric="sleep", kind="category", data={"type": "category", "value": 0})
        self.post_and_expect_accepted(make_changes(make_upsert(record)), 1)

    def test_series_parent_is_optional(self):
        record = make_record(metric="heartRateVariability", kind="series", data={
            "type": "series",
            "seriesType": "heartbeatSeries",
            "seriesID": str(uuid.uuid4()),
            "chunkIndex": 0,
            "channels": ["t", "interval"],
            "points": [[0.0, 812.0]],
        })
        self.post_and_expect_accepted(make_changes(make_upsert(record)), 1)
        self.assertIsNone(self.stored_rows()[0]["parent_id"])


class TypedDataValidationTests(ReceiverServerTestCase):
    """Malformed typed payloads are rejected loudly; nothing is stored."""

    def post_expect(self, code, payload=None, raw=None, status=400):
        body = raw if raw is not None else json.dumps(payload or make_payload(make_changes(make_upsert(make_record()))))
        result_status, result_body = self.post("/v1/records", body)
        self.assertEqual(result_status, status)
        self.assertEqual(result_body["error"]["code"], code)
        self.assertEqual(self.stored_count(), 0)

    def test_rejects_malformed_json(self):
        self.post_expect("invalid_json", raw=b"{not json")

    def test_rejects_non_finite_constant(self):
        raw = json.dumps(make_payload(make_changes(make_upsert(make_record())))).replace("8000", "NaN").encode("utf-8")
        self.post_expect("invalid_json", raw=raw)

    def test_rejects_overflowing_number_literal(self):
        # json.loads maps 1e999 to float('inf') without parse_constant; the
        # finite-number check must still catch it.
        raw = json.dumps(make_payload(make_changes(make_upsert(make_record())))).replace("8000", "1e999").encode("utf-8")
        self.post_expect("invalid_record_data", raw=raw)

    def test_rejects_unknown_data_type(self):
        self.post_expect(
            "unknown_record_data_type",
            make_payload(make_changes(make_upsert(make_record(data={"type": "mystery", "value": 1, "unit": "count"})))),
        )

    def test_rejects_data_type_not_matching_kind(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="category", data={"type": "quantity", "value": 1, "unit": "count"})))),
        )

    def test_rejects_non_object_data(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(data=[1, 2, 3])))),
        )

    def test_rejects_unknown_fields_inside_data(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(data={"type": "quantity", "value": 1, "unit": "count", "note": "x"})))),
        )

    def test_rejects_quantity_without_unit(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(data={"type": "quantity", "value": 1})))),
        )

    def test_rejects_quantity_boolean_value(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(data={"type": "quantity", "value": True, "unit": "count"})))),
        )

    def test_rejects_correlation_with_zero_components(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="correlation", data={"type": "correlation", "components": []})))),
        )

    def test_rejects_correlation_with_bad_component_metric(self):
        self.post_expect(
            "invalid_metric",
            make_payload(make_changes(make_upsert(make_record(kind="correlation", data={
                "type": "correlation",
                "components": [{"metric": "bad metric!", "value": 1, "unit": "mmHg"}],
            })))),
        )

    def test_rejects_workout_negative_duration(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="workout", data={
                "type": "workout", "activityType": "running", "activityTypeRawValue": 52, "duration": -1,
            })))),
        )

    def test_rejects_series_with_too_many_points(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="series", data={
                "type": "series",
                "seriesType": "workoutRoute",
                "seriesID": str(uuid.uuid4()),
                "chunkIndex": 0,
                "channels": ["t", "lat"],
                "points": [[0.0, 1.0]] * (validation._MAX_SERIES_POINTS_PER_CHUNK + 1),
            })))),
        )

    def test_rejects_series_with_ragged_row(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="series", data={
                "type": "series",
                "seriesType": "workoutRoute",
                "seriesID": str(uuid.uuid4()),
                "chunkIndex": 0,
                "channels": ["t", "lat", "lon"],
                "points": [[0.0, 1.0]],
            })))),
        )

    def test_rejects_series_with_invalid_channel_name(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="series", data={
                "type": "series",
                "seriesType": "workoutRoute",
                "seriesID": str(uuid.uuid4()),
                "chunkIndex": 0,
                "channels": ["t", "bad channel!"],
                "points": [[0.0, 1.0]],
            })))),
        )

    def test_rejects_series_with_bad_parent_uuid(self):
        self.post_expect(
            "invalid_record",
            make_payload(make_changes(make_upsert(make_record(kind="series", data={
                "type": "series",
                "seriesType": "workoutRoute",
                "seriesID": str(uuid.uuid4()),
                "parentID": "not-a-uuid",
                "chunkIndex": 0,
                "channels": ["t"],
                "points": [[0.0]],
            })))),
        )

    def test_rejects_electrocardiogram_without_classification(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="electrocardiogram", data={
                "type": "electrocardiogram",
            })))),
        )

    def test_rejects_electrocardiogram_nonpositive_sampling_frequency(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="electrocardiogram", data={
                "type": "electrocardiogram", "classification": "sinusRhythm", "samplingFrequency": 0,
            })))),
        )

    def test_rejects_clinical_non_object_fhir_resource(self):
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="clinical", data={
                "type": "clinical", "fhirType": "Condition", "fhirResource": "not-an-object",
            })))),
        )

    def test_rejects_clinical_fhir_exceeding_depth_limit(self):
        deep = {"node": None}
        cursor = deep
        for _ in range(validation._MAX_FHIR_DEPTH + 2):
            cursor["node"] = {"node": None}
            cursor = cursor["node"]
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="clinical", data={
                "type": "clinical", "fhirType": "Condition", "fhirResource": deep,
            })))),
        )

    def test_rejects_clinical_fhir_exceeding_node_budget(self):
        wide = {"k%d" % index: "v" for index in range(validation._MAX_FHIR_NODES + 1)}
        self.post_expect(
            "invalid_record_data",
            make_payload(make_changes(make_upsert(make_record(kind="clinical", data={
                "type": "clinical", "fhirType": "Condition", "fhirResource": wide,
            })))),
        )

    def test_rejects_unknown_metric_string_shapes(self):
        # Not an allowlist: the identifier must merely be a safe token.
        for bad in ("", "has space", "../etc/passwd", "a" * 65, None, 42):
            self.post_expect(
                "invalid_metric",
                make_payload(make_changes(make_upsert(make_record(metric=bad)))),
            )

    def test_rejects_unknown_record_kind(self):
        self.post_expect(
            "unknown_record_kind",
            make_payload(make_changes(make_upsert(make_record(kind="telepathy", data={"type": "quantity", "value": 1, "unit": "count"})))),
        )

    def test_rejects_unknown_record_fields(self):
        record = make_record()
        record["extra"] = "x"
        self.post_expect("invalid_record", make_payload(make_changes(make_upsert(record))))

    def test_rejects_unknown_top_level_fields(self):
        payload = make_payload(make_changes(make_upsert(make_record())))
        payload["extra"] = 1
        self.post_expect("invalid_payload", payload)

    def test_rejects_missing_top_level_fields(self):
        payload = make_payload(make_changes(make_upsert(make_record())))
        del payload["createdAt"]
        self.post_expect("invalid_payload", payload)

    def test_rejects_schema_version_1(self):
        record = make_record()
        legacy = {
            "schemaVersion": 1,
            "createdAt": "2026-09-23T12:00:00.000Z",
            "records": [{
                "id": record["id"], "metric": "steps", "value": 8000, "unit": "count",
                "startDate": record["startDate"], "endDate": record["endDate"],
                "sourceName": record["sourceName"], "deviceName": record["deviceName"],
                "metadata": {},
            }],
        }
        self.post_expect("unsupported_schema_version", legacy)

    def test_rejects_schema_version_2(self):
        record = make_record()
        legacy = {
            "schemaVersion": 2,
            "createdAt": "2026-09-23T12:00:00.000Z",
            "batchId": str(uuid.uuid4()),
            "changes": [{"kind": "upsert", "record": record}],
        }
        self.post_expect("unsupported_schema_version", legacy)

    def test_rejects_empty_batch(self):
        self.post_expect("empty_batch", make_payload([]))

    def test_rejects_invalid_uuid(self):
        self.post_expect(
            "invalid_record",
            make_payload(make_changes(make_upsert(make_record(id="6f9619ff-8b86-xxxx-b42d-00c04fc964ff")))),
        )

    def test_rejects_naive_dates(self):
        self.post_expect(
            "invalid_record",
            make_payload(make_changes(make_upsert(make_record(startDate="2026-09-20T00:00:00")))),
        )

    def test_rejects_end_before_start(self):
        self.post_expect(
            "invalid_record",
            make_payload(make_changes(make_upsert(make_record(
                startDate="2026-09-21T00:00:00.000Z",
                endDate="2026-09-20T00:00:00.000Z",
            )))),
        )

    def test_rejects_non_string_metadata_value(self):
        record = make_record()
        record["metadata"] = {"count": 5}
        self.post_expect("invalid_record", make_payload(make_changes(make_upsert(record))))

    def test_whole_second_timestamps_accepted(self):
        record = make_record(
            startDate="2026-09-20T00:00:00Z", endDate="2026-09-20T03:00:00+02:00"
        )
        status, body = self.post("/v1/records", make_payload(make_changes(make_upsert(record))))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)

    def test_swift_spelling_without_optional_fields_accepted(self):
        # Swift's synthesized Codable omits nil optionals rather than writing
        # null, so the wire format the iOS client actually produces omits
        # sourceName/deviceName entirely.
        record = {key: value for key, value in make_record().items()
                  if key not in ("sourceName", "deviceName")}
        status, body = self.post("/v1/records", make_payload(make_changes(make_upsert(record))))
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)
        rows = self.stored_rows()
        self.assertIsNone(rows[0]["source_name"])
        self.assertIsNone(rows[0]["device_name"])


class IngestionTests(ReceiverServerTestCase):
    def test_valid_batch_persists_and_acks(self):
        records = [
            make_record(),
            make_record(
                metric="heartRateVariability",
                data={"type": "quantity", "value": 48.2, "unit": "ms"},
                startDate="2026-09-21T08:00:00.123Z",
                endDate="2026-09-21T08:00:00.123Z",
                sourceName=None,
                deviceName=None,
                metadata={},
            ),
            make_record(
                metric="sleep",
                kind="category",
                data={"type": "category", "value": 2, "name": "asleepCore"},
                startDate="2026-09-21T22:00:00.000-05:00",
                endDate="2026-09-22T06:00:00.000-05:00",
            ),
        ]
        status, body = self.post("/v1/records", make_payload(make_changes(*[make_upsert(r) for r in records])))
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "accepted")
        self.assertEqual(body["accepted"], 3)
        self.assertEqual(body["duplicates"], 0)
        self.assertEqual(body["superseded"], 0)
        self.assertEqual(body["appliedDeletions"], 0)
        self.assertEqual(body["duplicateDeletions"], 0)
        self.assertEqual(body["cascadedDeletions"], 0)
        self.assertEqual(body["schemaVersion"], 3)

        rows = self.stored_rows()
        self.assertEqual(len(rows), 3)
        by_id = {row["id"]: row for row in rows}
        self.assertIn(records[0]["id"].lower(), by_id)

        # Dates normalize to UTC milliseconds.
        sleep_row = by_id[records[2]["id"].lower()]
        self.assertEqual(sleep_row["start_date"], "2026-09-22T03:00:00.000Z")
        self.assertEqual(sleep_row["end_date"], "2026-09-22T11:00:00.000Z")
        self.assertEqual(sleep_row["kind"], "category")
        self.assertEqual(json.loads(sleep_row["metadata_json"]), {"origin": "unit-test"})
        self.assertEqual(json.loads(sleep_row["data_json"])["name"], "asleepCore")

    def test_ingestion_is_idempotent_for_full_retry(self):
        changes = make_changes(make_upsert(make_record()), make_upsert(make_record()))
        payload = make_payload(changes)
        status, body = self.post("/v1/records", payload)
        self.assertEqual(body["accepted"], 2)
        # A different batchId, same records: the client retry case.
        status, body = self.post("/v1/records", make_payload(changes))
        self.assertEqual(body["accepted"], 0)
        self.assertEqual(body["duplicates"], 2)
        self.assertEqual(self.stored_count(), 2)

    def test_partial_duplicates_counted(self):
        changes = make_changes(make_upsert(make_record()), make_upsert(make_record()))
        self.post("/v1/records", make_payload(changes))
        status, body = self.post(
            "/v1/records",
            make_payload(changes + make_changes(make_upsert(make_record()))),
        )
        self.assertEqual(body["accepted"], 1)
        self.assertEqual(body["duplicates"], 2)

    def test_first_write_wins_for_same_id(self):
        record = make_record()
        self.post("/v1/records", make_payload(make_changes(make_upsert(record))))
        mutated = dict(record, data={"type": "quantity", "value": 111, "unit": "count"})
        status, body = self.post("/v1/records", make_payload(make_changes(make_upsert(mutated))))
        self.assertEqual(body["duplicates"], 1)
        rows = self.stored_rows()
        self.assertEqual(json.loads(rows[0]["data_json"])["value"], 8000)

    def test_duplicate_ids_within_one_batch(self):
        record = make_record()
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(record), make_upsert(dict(record)))),
        )
        self.assertEqual(body["accepted"], 1)
        self.assertEqual(body["duplicates"], 1)

    def test_batch_is_atomic(self):
        good = make_record()
        bad = make_record(kind="telepathy", data={"type": "quantity", "value": 1, "unit": "count"})
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(good), make_upsert(bad))),
        )
        self.assertEqual(status, 400)
        self.assertEqual(self.stored_count(), 0)

    def test_concurrent_duplicate_ingestion(self):
        record = make_record()
        results = []
        errors = []

        def send():
            try:
                results.append(self.post("/v1/records", make_payload(make_changes(make_upsert(record)))))
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


class IngestionLimitTests(ReceiverServerTestCase):
    max_records = 3

    def test_rejects_too_many_records(self):
        changes = make_changes(*[make_upsert(make_record()) for _ in range(4)])
        status, body = self.post("/v1/records", make_payload(changes))
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "too_many_records")
        self.assertEqual(self.stored_count(), 0)


class IngestionBodySizeTests(ReceiverServerTestCase):
    max_body_bytes = 2048

    def test_rejects_oversized_body(self):
        big_series = make_record(kind="series", data={
            "type": "series",
            "seriesType": "workoutRoute",
            "seriesID": str(uuid.uuid4()),
            "chunkIndex": 0,
            "channels": ["t", "v"],
            "points": [[float(i), 2.5] for i in range(500)],
        })
        status, body = self.post(
            "/v1/records", make_payload(make_changes(make_upsert(big_series)))
        )
        self.assertEqual(status, 413)
        self.assertEqual(body["error"]["code"], "payload_too_large")
        self.assertEqual(self.stored_count(), 0)


class ChangeBatchTests(ReceiverServerTestCase):
    def test_upserts_and_deletions_in_one_batch(self):
        keep = make_record()
        remove = make_record(metric="sleep", kind="category", data={"type": "category", "value": 1})
        delete_change = make_delete(remove["id"], metric="sleep")
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(keep), make_upsert(remove), delete_change)),
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 2)
        self.assertEqual(body["appliedDeletions"], 1)
        self.assertEqual(body["duplicateDeletions"], 0)
        self.assertEqual(body["cascadedDeletions"], 0)
        self.assertEqual(self.stored_count(), 1)
        self.assertEqual(self.tombstoned_ids(), {remove["id"].lower()})

    def test_retried_deletion_is_idempotent(self):
        change = make_delete()
        self.post("/v1/records", make_payload(make_changes(change)))
        status, body = self.post("/v1/records", make_payload(make_changes(dict(change))))
        self.assertEqual(body["appliedDeletions"], 0)
        self.assertEqual(body["duplicateDeletions"], 1)

    def test_tombstone_prevents_resurrection_by_older_addition(self):
        record = make_record()
        self.post("/v1/records", make_payload(make_changes(make_delete(record["id"], metric=record["metric"]))))
        status, body = self.post("/v1/records", make_payload(make_changes(make_upsert(record))))
        self.assertEqual(body["superseded"], 1)
        self.assertEqual(body["accepted"], 0)
        self.assertEqual(self.stored_count(), 0)

    def test_deletion_of_unknown_id_creates_tombstone(self):
        change = make_delete()
        status, body = self.post("/v1/records", make_payload(make_changes(change)))
        self.assertEqual(body["appliedDeletions"], 1)
        self.assertEqual(self.tombstoned_ids(), {change["id"].lower()})

    def test_full_batch_retry_is_idempotent(self):
        record = make_record()
        changes = make_changes(make_upsert(record), make_delete(record["id"], metric=record["metric"]))
        self.post("/v1/records", make_payload(changes))
        status, body = self.post("/v1/records", make_payload(changes))
        # On replay the addition is tombstone-suppressed and the deletion
        # is a duplicate: the stored state is unchanged either way.
        self.assertEqual(body["accepted"], 0)
        self.assertEqual(body["superseded"], 1)
        self.assertEqual(body["appliedDeletions"], 0)
        self.assertEqual(body["duplicateDeletions"], 1)
        self.assertEqual(self.stored_count(), 0)

    def test_bad_change_rolls_back_whole_batch(self):
        good = make_record()
        bad = make_record(data={"type": "quantity", "value": float("inf"), "unit": "count"})
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(good), make_upsert(bad))),
        )
        self.assertEqual(status, 400)
        self.assertEqual(self.stored_count(), 0)

    def test_unknown_change_kind_rejected(self):
        record = make_record()
        payload = make_payload([{"kind": "purge", "record": record}])
        status, body = self.post("/v1/records", payload)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_record")

    def test_delete_requires_metric_shape(self):
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_delete(metric="bad metric!"))),
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_metric")

    def test_cascade_delete_removes_and_tombstones_series_children(self):
        parent = make_record(metric="workouts", kind="workout", data={
            "type": "workout", "activityType": "running", "activityTypeRawValue": 52, "duration": 600.0,
        })
        parent_id = parent["id"]
        chunk_a = make_record(metric="workoutRoute", kind="series", data={
            "type": "series", "seriesType": "workoutRoute", "seriesID": str(uuid.uuid4()),
            "parentID": parent_id, "chunkIndex": 0, "channels": ["t", "lat"],
            "points": [[0.0, 1.0]],
        })
        chunk_b = make_record(metric="workoutRoute", kind="series", data={
            "type": "series", "seriesType": "workoutRoute", "seriesID": str(uuid.uuid4()),
            "parentID": parent_id, "chunkIndex": 1, "channels": ["t", "lat"],
            "points": [[1.0, 2.0]],
        })
        self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(parent), make_upsert(chunk_a), make_upsert(chunk_b))),
        )
        self.assertEqual(self.stored_count(), 3)

        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_delete(parent_id, metric="workouts"))),
        )
        self.assertEqual(body["appliedDeletions"], 1)
        self.assertEqual(body["cascadedDeletions"], 2)
        self.assertEqual(self.stored_count(), 0)

        # Cascaded children are tombstoned too: a replayed chunk cannot
        # resurrect an orphan.
        self.assertEqual(
            self.tombstoned_ids(),
            {parent_id.lower(), chunk_a["id"].lower(), chunk_b["id"].lower()},
        )

        # Retrying the delete is still idempotent and reports no cascade.
        status, body = self.post(
            "/v1/records",
            make_payload(make_changes(make_delete(parent_id, metric="workouts"))),
        )
        self.assertEqual(body["duplicateDeletions"], 1)
        self.assertEqual(body["cascadedDeletions"], 0)

    def test_series_chunk_resurrection_suppressed_after_parent_delete(self):
        parent = make_record()
        chunk = make_record(metric="workoutRoute", kind="series", data={
            "type": "series", "seriesType": "workoutRoute", "seriesID": str(uuid.uuid4()),
            "parentID": parent["id"], "chunkIndex": 0, "channels": ["t"], "points": [[0.0]],
        })
        self.post(
            "/v1/records",
            make_payload(make_changes(make_upsert(parent), make_upsert(chunk))),
        )
        self.post(
            "/v1/records",
            make_payload(make_changes(make_delete(parent["id"], metric=parent["metric"]))),
        )
        # A late replay of the chunk (stale outbox event) is suppressed.
        status, body = self.post("/v1/records", make_payload(make_changes(make_upsert(chunk))))
        self.assertEqual(body["superseded"], 1)
        self.assertEqual(self.stored_count(), 0)


class SchemaResetTests(unittest.TestCase):
    """Schema policy: an incompatible database is recreated, not migrated."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.db_path = os.path.join(self.tempdir.name, "records.sqlite3")

    def _write_legacy_database(self, schema_version):
        connection = sqlite3.connect(self.db_path)
        try:
            connection.executescript(
                """
                CREATE TABLE records (
                    id TEXT PRIMARY KEY, metric TEXT NOT NULL, value REAL NOT NULL,
                    unit TEXT NOT NULL, start_date TEXT NOT NULL, end_date TEXT NOT NULL,
                    source_name TEXT, device_name TEXT, metadata TEXT NOT NULL,
                    batch_created_at TEXT NOT NULL, first_seen_at TEXT NOT NULL
                );
                CREATE TABLE deleted_ids (
                    id TEXT PRIMARY KEY, metric TEXT NOT NULL, start_date TEXT NOT NULL,
                    end_date TEXT NOT NULL, batch_created_at TEXT NOT NULL,
                    first_seen_at TEXT NOT NULL
                );
                CREATE TABLE schema_info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO records VALUES ('legacy-id', 'steps', 1.0, 'count',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', NULL, NULL,
                    '{}', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
                """
            )
            connection.execute(
                "INSERT INTO schema_info VALUES ('schema_version', ?)",
                (str(schema_version),),
            )
            connection.commit()
        finally:
            connection.close()

    def test_legacy_database_is_reset_for_v3(self):
        self._write_legacy_database(1)
        store = storage.RecordStore(self.db_path)
        self.assertEqual(store.schema_version(), "3")
        self.assertEqual(store.record_count(), 0)
        # The new schema is fully usable afterwards.
        record = make_record()
        prepared = validation.PreparedChange(
            "upsert",
            record["id"].lower(),
            record["metric"],
            record_tuple=(
                record["id"].lower(), record["metric"], record["kind"],
                "2026-09-20T00:00:00.000Z", "2026-09-20T23:59:59.000Z",
                "source", "device", "{}", '{"type":"quantity","unit":"count","value":1}', None,
            ),
        )
        counts = store.apply([prepared], "2026-09-23T00:00:00.000Z")
        self.assertEqual(counts.accepted, 1)

    def test_matching_schema_is_untouched(self):
        store = storage.RecordStore(self.db_path)
        record = make_record()
        prepared = validation.PreparedChange(
            "upsert",
            record["id"].lower(),
            record["metric"],
            record_tuple=(
                record["id"].lower(), record["metric"], record["kind"],
                "2026-09-20T00:00:00.000Z", "2026-09-20T23:59:59.000Z",
                None, None, "{}", '{"type":"quantity","unit":"count","value":1}', None,
            ),
        )
        store.apply([prepared], "2026-09-23T00:00:00.000Z")
        # Reopen: same version, data preserved.
        reopened = storage.RecordStore(self.db_path)
        self.assertEqual(reopened.record_count(), 1)
        self.assertEqual(reopened.schema_version(), "3")


class RoutingAndFramingTests(ReceiverServerTestCase):
    def test_unknown_path_is_404(self):
        status, body = self.get("/v2/records")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")

    def test_query_string_is_not_part_of_the_contract(self):
        status, body = self.get("/v1/records?verbose=1")
        self.assertEqual(status, 404)

    def test_unsupported_method_is_405(self):
        status, body, _ = self.request("PUT", "/v1/records", body=make_payload(make_changes(make_upsert(make_record()))))
        self.assertEqual(status, 405)

    def test_head_and_options_get_safe_json_errors(self):
        for method in ("HEAD", "OPTIONS"):
            status, body, _ = self.request(method, "/v1/records")
            self.assertIn(status, (405, 200))

    def test_post_to_health_path_is_405(self):
        status, body = self.post("/v1/health", make_payload(make_changes(make_upsert(make_record()))))
        self.assertEqual(status, 405)

    def test_negative_content_length_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", "-5")
        connection.endheaders()
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 400)

    def test_transfer_encoding_rejected_on_ingestion(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        body = json.dumps(make_payload(make_changes(make_upsert(make_record())))).encode("utf-8")
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        connection.send(b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body))
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 400)

    def test_missing_content_length_rejected(self):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=10)
        connection.putrequest("POST", "/v1/records")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Type", "application/json")
        connection.endheaders()
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 411)

    def test_error_responses_have_safe_shape(self):
        status, body = self.post("/v1/records", "{not json")
        self.assertEqual(body["error"]["code"], "invalid_json")
        self.assertNotIn(TOKEN, json.dumps(body))


class SlowClientTimeoutTests(unittest.TestCase):
    """A client that advertises more body than it sends is cut off."""

    def test_stalled_body_is_cut_off(self):
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        db_path = os.path.join(tempdir.name, "records.sqlite3")
        server = receiver.make_server(HOST, 0, db_path, TOKEN)
        # Shrink the socket timeout so the test stays fast.
        server.RequestHandlerClass.timeout = 1
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)

        import socket

        payload = json.dumps(make_payload(make_changes(make_upsert(make_record()))))
        sock = socket.create_connection((HOST, port), timeout=5)
        self.addCleanup(sock.close)
        request = (
            "POST /v1/records HTTP/1.1\r\n"
            "Host: t\r\n"
            "Authorization: Bearer %s\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %d\r\n\r\n" % (TOKEN, len(payload) + 4096)
        )
        sock.sendall(request.encode("ascii"))
        sock.sendall(payload.encode("utf-8")[:16])
        start = time.monotonic()
        data = sock.recv(256)
        elapsed = time.monotonic() - start
        # The bounded cut-off is an EOF (empty read): the server gives up on
        # the incomplete body instead of pinning the worker. A timeout
        # error response would also be acceptable; stalling is not.
        self.assertLess(elapsed, 10, "the cut-off should be bounded by the socket timeout")
        self.assertEqual(storage.RecordStore(db_path).record_count(), 0)


class ValidationUnitTests(unittest.TestCase):
    def test_timestamp_parser_accepts_contract_forms(self):
        for value in (
            "2026-09-23T12:00:00.000Z",
            "2026-09-23T12:00:00Z",
            "2026-09-23T12:00:00.123456789Z",
            "2026-09-23T12:00:00+02:00",
        ):
            parsed = validation.parse_timestamp(value, "test")
            self.assertIsNotNone(parsed.tzinfo)

    def test_timestamp_parser_rejects_naive_and_garbage(self):
        for value in ("2026-09-23T12:00:00", "not a date", 12, None, "2026-13-45T00:00:00Z"):
            with self.assertRaises(validation.ValidationError):
                validation.parse_timestamp(value, "test")

    def test_metric_pattern_accepts_catalog_style_identifiers(self):
        for value in ("steps", "heartRate", "bloodPressureSystolic", "someFutureMetric.v2", "a" * 64):
            self.assertEqual(validation.parse_metric(value, "test"), value)

    def test_metric_pattern_rejects_unsafe_identifiers(self):
        for value in ("", "has space", "-leading", "a" * 65, None, 5, "../traversal"):
            with self.assertRaises(validation.ValidationError):
                validation.parse_metric(value, "test")


if __name__ == "__main__":
    unittest.main()
