#!/usr/bin/env python3
"""Generate and (optionally) send synthetic VitalRoute change batches.

A dependency-free example client for the receiver contract (API.md,
schemaVersion 3). Useful for trying a receiver without an iOS device and
for integration checks. Records are synthetic end to end — no HealthKit
data is ever involved.

Each batch covers the receiver's record kinds with one record each:
quantity, category, correlation, workout, activitySummary,
electrocardiogram (plus its voltage series chunks), clinical, and series.
Data values are deterministic for a given seed.

Examples:
    # Generate and POST 2 full kind cycles against a local receiver:
    python3 send_synthetic_data.py --url https://localhost:8787/v1/records \
        --token "$VITALROUTE_TOKEN" --cycles 2

    # Just print an example batch without sending anything:
    python3 send_synthetic_data.py --cycles 1 --dry-run
"""

import argparse
import datetime
import hashlib
import json
import random
import sys
import urllib.error
import urllib.request
import uuid

SCHEMA_VERSION = 3


def _iso8601(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


def deterministic_chunk_id(series_id, chunk_index):
    """A stable chunk UUID derived from (seriesID, chunkIndex).

    Mirrors the client: retries derive the same id, so series chunks stay
    idempotent even though HealthKit does not assign them identities.
    """
    digest = hashlib.sha256(
        ("series:" + str(series_id).lower() + ":" + str(chunk_index)).encode("utf-8")
    ).digest()[:16]
    variant = bytearray(digest)
    variant[6] = (variant[6] & 0x0F) | 0x40
    variant[8] = (variant[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(variant)))


def _record(rng, metric, kind, start, end, data):
    return {
        "id": str(uuid.UUID(int=rng.getrandbits(128))),
        "metric": metric,
        "kind": kind,
        "startDate": _iso8601(start),
        "endDate": _iso8601(end),
        "sourceName": "Synthetic Generator",
        "deviceName": "Synthetic Device",
        "metadata": {},
        "data": data,
    }


def _series_records(rng, metric, series_type, series_id, parent_id, start, end, chunks, points_per_chunk):
    """Chunked series records: channels t/voltage or t/lat/lon/alt/speed."""
    span = (end - start).total_seconds()
    records = []
    for chunk_index in range(chunks):
        chunk_start = start + datetime.timedelta(
            seconds=span * chunk_index / max(chunks, 1)
        )
        chunk_end = start + datetime.timedelta(
            seconds=span * (chunk_index + 1) / max(chunks, 1)
        )
        if series_type == "electrocardiogramVoltage":
            channels = ["t", "v"]
            points = [
                [
                    round(0.512 * index / 512.0, 6),
                    round(rng.uniform(-2.5, 2.5), 4),
                ]
                for index in range(points_per_chunk)
            ]
        else:
            channels = ["t", "lat", "lon", "alt", "speed"]
            base_lat, base_lon = 47.6062, -122.3321
            points = [
                [
                    round(span * index / max(points_per_chunk, 1), 3),
                    round(base_lat + rng.uniform(-0.01, 0.01), 6),
                    round(base_lon + rng.uniform(-0.01, 0.01), 6),
                    round(rng.uniform(0, 100), 1),
                    round(rng.uniform(0, 6), 2),
                ]
                for index in range(points_per_chunk)
            ]
        records.append(
            {
                "id": deterministic_chunk_id(series_id, chunk_index),
                "metric": metric,
                "kind": "series",
                "startDate": _iso8601(chunk_start),
                "endDate": _iso8601(chunk_end),
                "sourceName": "Synthetic Generator",
                "deviceName": "Synthetic Device",
                "metadata": {},
                "data": {
                    "type": "series",
                    "seriesType": series_type,
                    "seriesID": str(series_id),
                    "parentID": str(parent_id),
                    "chunkIndex": chunk_index,
                    "channels": channels,
                    "points": points,
                },
            }
        )
    return records


def generate_changes(cycles, seed=1):
    """Deterministically generates `cycles` rounds of one record per kind."""
    rng = random.Random(seed)
    now = datetime.datetime.now(datetime.timezone.utc)
    changes = []

    for cycle in range(cycles):
        hour = cycle * 24
        def at(offset_seconds):
            return now - datetime.timedelta(
                seconds=hour * 3600 + 3600 + offset_seconds
            )

        # quantity
        moment = at(rng.uniform(0, 600))
        changes.append({"kind": "upsert", "record": _record(
            rng, "heartRate", "quantity", moment, moment + datetime.timedelta(seconds=30),
            {"type": "quantity", "value": round(rng.uniform(50, 160), 1), "unit": "count/min"},
        )})
        # category (sleep stage)
        moment = at(rng.uniform(600, 1200))
        changes.append({"kind": "upsert", "record": _record(
            rng, "sleep", "category", moment, moment + datetime.timedelta(seconds=1800),
            {"type": "category", "value": 3, "name": "asleepREM"},
        )})
        # correlation (blood pressure)
        moment = at(rng.uniform(1200, 1800))
        changes.append({"kind": "upsert", "record": _record(
            rng, "bloodPressure", "correlation", moment, moment,
            {"type": "correlation", "components": [
                {"metric": "bloodPressureSystolic", "value": round(rng.uniform(105, 140), 0), "unit": "mmHg"},
                {"metric": "bloodPressureDiastolic", "value": round(rng.uniform(65, 90), 0), "unit": "mmHg"},
            ]},
        )})
        # workout + its route series
        start = at(rng.uniform(1800, 2400))
        end = start + datetime.timedelta(minutes=32)
        workout_id = uuid.UUID(int=rng.getrandbits(128))
        changes.append({"kind": "upsert", "record": _record(
            rng, "workouts", "workout", start, end,
            {
                "type": "workout",
                "activityType": "running",
                "activityTypeRawValue": 52,
                "duration": 1920.0,
                "totalEnergyKilocalories": round(rng.uniform(200, 500), 1),
                "totalDistanceMeters": round(rng.uniform(4000, 9000), 1),
            },
        )})
        route_id = uuid.UUID(int=rng.getrandbits(128))
        changes.extend(
            {"kind": "upsert", "record": chunk}
            for chunk in _series_records(
                rng, "workoutRoute", "workoutRoute", route_id, workout_id,
                start, end, chunks=2, points_per_chunk=64,
            )
        )
        # activity summary
        day_start = (now - datetime.timedelta(days=cycle + 1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        changes.append({"kind": "upsert", "record": _record(
            rng, "activitySummary", "activitySummary", day_start, day_start + datetime.timedelta(days=1),
            {
                "type": "activitySummary",
                "activeEnergyBurnedKilocalories": round(rng.uniform(300, 800), 1),
                "exerciseTimeMinutes": round(rng.uniform(15, 90), 0),
                "standHours": 12.0,
                "distanceWalkingRunningMeters": round(rng.uniform(4000, 12000), 1),
                "dateComponentsUTC": day_start.strftime("%Y-%m-%d"),
            },
        )})
        # electrocardiogram + voltage series
        start = at(rng.uniform(2400, 3000))
        end = start + datetime.timedelta(seconds=30)
        ecg_id = uuid.UUID(int=rng.getrandbits(128))
        changes.append({"kind": "upsert", "record": _record(
            rng, "electrocardiogram", "electrocardiogram", start, end,
            {
                "type": "electrocardiogram",
                "classification": "sinusRhythm",
                "classificationRawValue": 2,
                "symptomStatus": "none",
                "averageHeartRate": round(rng.uniform(52, 80), 1),
                "samplingFrequency": 512.0,
                "voltageSeriesID": str(ecg_id),
                "voltageChunkCount": 1,
            },
        )})
        changes.extend(
            {"kind": "upsert", "record": chunk}
            for chunk in _series_records(
                rng, "electrocardiogram", "electrocardiogramVoltage", ecg_id, ecg_id,
                start, end, chunks=1, points_per_chunk=128,
            )
        )
        # clinical (structured FHIR, preserved verbatim)
        moment = at(rng.uniform(3000, 3600))
        changes.append({"kind": "upsert", "record": _record(
            rng, "clinicalCondition", "clinical", moment, moment,
            {
                "type": "clinical",
                "fhirType": "Condition",
                "fhirIdentifier": "synthetic-condition-%d" % cycle,
                "fhirResource": {
                    "resourceType": "Condition",
                    "id": "synthetic-%d" % cycle,
                    "clinicalStatus": {
                        "coding": [{"system": "http://terminology.hl7.org/CodeSystem/condition-clinical", "code": "active"}]
                    },
                    "code": {"text": "Synthetic example condition"},
                    "onsetDateTime": _iso8601(moment),
                    "note": [{"text": "Generated for receiver exercise; not health data."}],
                },
            },
        )})

    return changes


def make_payload(changes):
    return {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": _iso8601(datetime.datetime.now(datetime.timezone.utc)),
        "batchId": str(uuid.uuid4()),
        "changes": changes,
    }


def send(url, token, payload):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", help="Ingestion endpoint, e.g. https://host/v1/records")
    parser.add_argument("--token", default="", help="Bearer token")
    parser.add_argument("--cycles", type=int, default=1,
                        help="Number of full kind cycles to generate")
    parser.add_argument("--seed", type=int, default=1, help="Deterministic seed")
    parser.add_argument(
        "--dry-run", action="store_true", help="Print the payload instead of sending"
    )
    args = parser.parse_args(argv)

    payload = make_payload(generate_changes(args.cycles, args.seed))
    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return 0
    if not args.url or not args.token:
        parser.error("--url and --token are required unless --dry-run is set.")

    try:
        ack = send(args.url, args.token, payload)
    except urllib.error.HTTPError as error:
        print("Rejected: HTTP %d %s" % (error.code, error.read().decode("utf-8", "replace")))
        return 1
    except urllib.error.URLError as error:
        print("Request failed: %s" % error.reason)
        return 1

    if ack.get("status") != "accepted":
        print("Unexpected acknowledgment: %s" % json.dumps(ack))
        return 1
    print(
        "Accepted: %d new, %d duplicate, %d superseded (of %d changes sent)"
        % (
            ack["accepted"],
            ack["duplicates"],
            ack["superseded"],
            len(payload["changes"]),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
