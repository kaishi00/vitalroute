#!/usr/bin/env python3
"""Generate and (optionally) send synthetic VitalRoute records.

A dependency-free example client for the receiver contract (API.md). Useful
for trying a receiver without an iOS device and for integration checks.

Examples:
    # Generate and POST 40 synthetic records covering the last 7 days:
    python3 send_synthetic_data.py --url https://localhost:8787/v1/records \
        --token "$VITALROUTE_TOKEN" --count 40

    # Just print an example payload without sending anything:
    python3 send_synthetic_data.py --count 12 --dry-run
"""

import argparse
import datetime
import json
import random
import sys
import urllib.error
import urllib.request
import uuid

METRIC_SPECS = [
    ("steps", "count", 500, 18000, 20),
    ("heartRate", "count/min", 48, 165, 240),
    ("restingHeartRate", "count/min", 48, 72, 12),
    ("heartRateVariability", "ms", 18, 90, 24),
    ("sleep", "s", 4 * 3600, 9 * 3600, 4),
    ("activeEnergy", "kcal", 120, 900, 8),
    ("workouts", "s", 1200, 5400, 2),
]

SLEEP_STAGES = ["asleepCore", "asleepDeep", "asleepREM", "awake"]
WORKOUT_TYPES = ["traditionalStrengthTraining", "running", "cycling", "swimming"]


def _iso8601(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


def generate_records(count, days, seed=1):
    """Deterministically generates `count` synthetic records over `days`."""
    rng = random.Random(seed)
    now = datetime.datetime.now(datetime.timezone.utc)
    records = []
    for index in range(count):
        metric, unit, low, high, _span = METRIC_SPECS[index % len(METRIC_SPECS)]
        value = rng.uniform(low, high)
        end = now - datetime.timedelta(
            seconds=rng.uniform(0, days * 24 * 3600 - 3600)
        )
        duration = 60 if metric not in ("sleep", "workouts") else rng.uniform(600, 5400)
        start = end - datetime.timedelta(seconds=duration)
        metadata = {}
        if metric == "sleep":
            metadata["sleepStage"] = rng.choice(SLEEP_STAGES)
        elif metric == "workouts":
            metadata["activityTypeCode"] = str(
                {"traditionalStrengthTraining": 82, "running": 52, "cycling": 16, "swimming": 5}[
                    rng.choice(WORKOUT_TYPES)
                ]
            )
            metadata["activeEnergyKcal"] = "%.1f" % rng.uniform(150, 700)
            metadata["distanceMeters"] = "%.1f" % rng.uniform(1000, 12000)
        records.append(
            {
                "id": str(uuid.UUID(int=rng.getrandbits(128))),
                "metric": metric,
                "value": round(value, 2),
                "unit": unit,
                "startDate": _iso8601(start),
                "endDate": _iso8601(end),
                "sourceName": "Synthetic Generator",
                "deviceName": "Synthetic Device",
                "metadata": metadata,
            }
        )
    return records


def make_payload(records):
    return {
        "schemaVersion": 1,
        "createdAt": _iso8601(datetime.datetime.now(datetime.timezone.utc)),
        "records": records,
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
    parser.add_argument("--count", type=int, default=12, help="Number of records to generate")
    parser.add_argument("--days", type=int, default=7, help="Window in days")
    parser.add_argument("--seed", type=int, default=1, help="Deterministic seed")
    parser.add_argument(
        "--dry-run", action="store_true", help="Print the payload instead of sending"
    )
    args = parser.parse_args(argv)

    payload = make_payload(generate_records(args.count, args.days, args.seed))
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
        "Accepted: %d new, %d duplicate (of %d sent)"
        % (ack["accepted"], ack["duplicates"], len(payload["records"]))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
