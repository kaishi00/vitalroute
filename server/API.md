# VitalRoute Receiver API — Contract v3

This document defines the HTTP contract between the VitalRoute iOS client and any
receiving backend. The reference implementation in `server/receiver.py` conforms
to it exactly. Another user-controlled backend can implement the same contract
without referencing the reference implementation.

Conventions:

- All requests and responses are `application/json; charset=UTF-8`.
- All timestamps in requests are ISO 8601 with an explicit UTC offset (`Z` or
  `±HH:MM`). Fractional seconds are optional; the client sends millisecond
  precision (`2026-09-23T12:34:56.789Z`).
- Authentication is a Bearer token in the `Authorization` header on every
  request, including the connection test.
- HTTP status codes are authoritative. A 2xx alone is *not* sufficient evidence
  of successful ingestion — clients must also parse and validate the
  acknowledgment body (see below).

The URL path segment `/v1/records` is a stable endpoint location, not a
protocol version. The protocol version lives in the payload's
`schemaVersion` field and in the health response's `apiVersion`.

## Operations

### Ingest a change batch — `POST` to the configured endpoint URL

The endpoint URL the user configures in the app **is** the ingestion URL, for
example `https://health.example.org/v1/records`. One request carries one
batch. `GET` on the same URL performs the connection test (below). This keeps
client configuration to a single URL regardless of where a backend mounts the
API.

Request headers:

```
Authorization: Bearer <token>
Content-Type: application/json
Accept: application/json
```

Request body — schema version 3:

```json
{
  "schemaVersion": 3,
  "createdAt": "2026-09-26T12:00:00.000Z",
  "batchId": "7f6c1a2e-9b34-4d05-8c11-2f0a54d7b901",
  "changes": [
    {
      "kind": "upsert",
      "record": {
        "id": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
        "metric": "heartRate",
        "kind": "quantity",
        "startDate": "2026-09-25T08:00:00.000Z",
        "endDate": "2026-09-25T08:00:05.000Z",
        "sourceName": "Apple Watch",
        "deviceName": "Watch",
        "metadata": {},
        "data": { "type": "quantity", "value": 61.5, "unit": "count/min" }
      }
    },
    {
      "kind": "delete",
      "id": "151e2d20-1b0f-4a9e-9b2a-2d4c6f8a0b12",
      "metric": "steps",
      "startDate": "2026-09-25T09:00:00.000Z",
      "endDate": "2026-09-25T09:00:00.000Z"
    }
  ]
}
```

## Record model

A record is an **envelope** plus a **typed `data` payload**:

- The envelope answers *what health information this is* (`metric`), *how it
  is structurally represented* (`kind`), *when* (`startDate`/`endDate`),
  *where it came from* (`sourceName`, `deviceName`), and free-form string
  annotations (`metadata`).
- `data` is a JSON object discriminated by its `type` field, which must equal
  the envelope `kind`. The payload carries all structured content of the
  record.

### Envelope fields

| Field | Rule |
|---|---|
| `id` | Canonical UUID (the Apple Health sample UUID). Stable record identity. |
| `metric` | Client-owned identifier: 1–64 characters, `[A-Za-z0-9]` first, then `[A-Za-z0-9._-]`. **No receiver-side allowlist** — the iOS client owns the metric catalog, and unknown metrics are accepted. |
| `kind` | One of the eight record kinds below. An unknown kind is rejected. |
| `startDate` / `endDate` | ISO 8601 with offset; `endDate` ≥ `startDate`. |
| `sourceName` / `deviceName` | Optional: absent, null, or a string ≤ 256 characters. |
| `metadata` | Object with ≤ 32 string keys (≤ 64 chars) and string values (≤ 512 chars). |
| `data` | Object whose `type` matches `kind` and whose shape validates for that kind (below). |

### Record kinds and their `data` payloads

All numeric values must be finite (NaN/Infinity are rejected anywhere they
can appear, including overflow literals such as `1e999`). Unknown fields
inside `data` are rejected rather than ignored, so contract drift fails
loudly.

**`quantity`** — a scalar sample.

```json
{ "type": "quantity", "value": 8432, "unit": "count" }
```

`value`: finite number. `unit`: non-empty string ≤ 64 characters.

**`category`** — a categorical sample (e.g. a sleep stage).

```json
{ "type": "category", "value": 3, "name": "asleepREM" }
```

`value`: integer 0…2³¹−1 (the client's raw category value). `name`: optional
stable value name ≤ 64 characters, when the client can map one.

**`correlation`** — one sample structurally tying several measurements
together (e.g. blood pressure).

```json
{
  "type": "correlation",
  "components": [
    { "metric": "bloodPressureSystolic", "value": 122, "unit": "mmHg" },
    { "metric": "bloodPressureDiastolic", "value": 78, "unit": "mmHg" }
  ]
}
```

`components`: array of 1–8 entries, each a metric identifier (same rules as
envelope `metric`), a finite number, and a unit.

**`workout`** — a workout with structured details.

```json
{
  "type": "workout",
  "activityType": "running",
  "activityTypeRawValue": 52,
  "duration": 1920.0,
  "totalEnergyKilocalories": 331.2,
  "totalDistanceMeters": 5210.5
}
```

`activityType`: non-empty string ≤ 64 chars. `activityTypeRawValue`: integer.
`duration`: finite number ≥ 0. The energy/distance fields are optional finite
numbers ≥ 0.

**`activitySummary`** — a daily activity summary. All fields optional except
`type`; every numeric field is a finite number ≥ 0.

```json
{
  "type": "activitySummary",
  "activeEnergyBurnedKilocalories": 501.0,
  "activeEnergyBurnedGoalKilocalories": 400.0,
  "exerciseTimeMinutes": 32,
  "exerciseTimeGoalMinutes": 30,
  "standHours": 12,
  "standHoursGoal": 12,
  "distanceWalkingRunningMeters": 8500.5,
  "distanceWalkingRunningGoalMeters": 6000.0,
  "dateComponentsUTC": "2026-09-25"
}
```

**`series`** — one chunk of a larger series (workout routes, ECG voltage,
heartbeat intervals). A logical series is transported as multiple independent
records, one per chunk; see "Large records and series" below.

```json
{
  "type": "series",
  "seriesType": "workoutRoute",
  "seriesID": "0a0b0c0d-1112-2324-3536-4758697a8b9c",
  "parentID": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
  "chunkIndex": 0,
  "channels": ["t", "lat", "lon", "alt", "speed"],
  "points": [[0.0, 47.61, -122.33, 40.0, 3.2], [0.5, 47.62, -122.34, 41.0, 3.5]]
}
```

`seriesType`: non-empty string ≤ 64 chars (e.g. `workoutRoute`,
`electrocardiogramVoltage`, `heartbeatSeries`). `seriesID`: UUID of the
HealthKit series. `parentID`: optional UUID of the owning record (the workout
or ECG); required in practice so deletions cascade — see below.
`chunkIndex`: integer 0…1,000,000. `channels`: array of 1–16 names, each
matching the metric-identifier pattern ≤ 32 chars. `points`: array of at most
2048 rows, each row exactly `len(channels)` finite numbers.

**`electrocardiogram`** — an ECG sample's structured facts. Voltage data
travels as `series` chunks whose `parentID`/`seriesID` reference this record.

```json
{
  "type": "electrocardiogram",
  "classification": "sinusRhythm",
  "classificationRawValue": 2,
  "symptomStatus": "none",
  "symptomStatusRawValue": 1,
  "averageHeartRate": 62.0,
  "samplingFrequency": 512.0,
  "voltageSeriesID": "0a0b0c0d-1112-2324-3536-4758697a8b9c",
  "voltageChunkCount": 2
}
```

`classification`: non-empty string ≤ 64 chars. `symptomStatus`: optional
string ≤ 64 chars. `averageHeartRate`: optional finite ≥ 0 (count/min).
`samplingFrequency`: optional finite > 0 (Hz). `voltageSeriesID`: optional
UUID. `voltageChunkCount`: optional integer ≥ 0. The `*RawValue` fields are
optional integers carrying the client's raw enum values alongside the names.

**`clinical`** — a clinical record whose FHIR resource is preserved
structurally, never flattened into strings.

```json
{
  "type": "clinical",
  "fhirType": "Condition",
  "fhirIdentifier": "example-1",
  "fhirResource": {
    "resourceType": "Condition",
    "code": { "text": "Example" },
    "clinicalStatus": { "coding": [{ "code": "active" }] }
  }
}
```

`fhirType`: non-empty string ≤ 64 chars (the FHIR resource type).
`fhirIdentifier`: optional string ≤ 256 chars. `fhirResource`: a JSON object,
preserved verbatim, bounded by a structural budget of ≤ 4096 nodes and ≤ 32
nesting levels.

### Per-record size limit

The canonicalized `data` payload of one record is at most 1 MiB
(`record_too_large`, HTTP 400, otherwise). Series chunking bounds typical
payloads far below this.

## Version 3 replaces versions 1 and 2

Versions 1 (records-only payloads) and 2 (the original change-batch shape)
are **removed**. A body whose `schemaVersion` is not `3` is rejected with
`unsupported_schema_version`, whatever its shape. There is no fallback: a
receiver that refuses v3-era bodies is incompatible with the current client,
and a pre-3 client cannot talk to this receiver.

Change `kind` (`upsert` / `delete`) is a different concept from record
`kind` (`quantity`, `workout`, …): the first selects the change operation,
the second the record's structure.

- `batchId` is a canonical UUID chosen by the client per batch attempt.
- `upsert.record` must satisfy every envelope and typed-data rule above.
- `delete` identifies the deleted sample by its id (the Apple Health sample
  UUID), with its metric and interval. Apple's deleted-object results do not
  expose the original sample dates, so clients send the capture time; the
  receiver stores it on the tombstone for audit.
- Limits and framing: ≤ 500 changes per batch, 10 MiB body,
  Content-Length required, transfer encoding refused.
- The whole batch applies in one transaction; any validation failure stores
  nothing.

Server semantics with tombstones:

- **upsert**: first-write-wins `INSERT OR IGNORE` — *unless a tombstone
  exists for the id*, in which case the addition is ignored and counted as
  `superseded`. An older queued or retried addition can therefore never
  resurrect a deleted sample.
- **delete**: removes any live row and upserts a tombstone (`deleted_ids`
  table). Retrying a deletion is idempotent and counted as
  `duplicateDeletions`. Deletions of ids never seen before still create
  tombstones, so a late-arriving addition is suppressed too.
- **cascade**: deleting an id also removes live rows whose `parent_id`
  references it (series chunks of a deleted workout, route, or ECG),
  tombstoning their ids as well, and reports the count as
  `cascadedDeletions`. The cascade never counts toward the reconciliation
  sums below.

**Retention**: tombstones are kept indefinitely and are consulted on every
upsert. That is deliberate — pruning an old tombstone would let a
sufficiently stale replayed addition resurrect a deleted sample — but it
means `deleted_ids` grows without bound on a long-running receiver and must
be planned for operationally (size the volume for it, and monitor table
growth). If a deployment needs pruning, the retention window must be longer
than any batch that could still be replayed — and note that this horizon is
effectively unbounded, because a restored device backup can replay
arbitrarily old batches. Any pruning is therefore accepting resurrection
risk for whatever it prunes, not merely a batch-age bound.

Acknowledgment (after commit):

```json
{
  "status": "accepted",
  "accepted": 8,
  "duplicates": 1,
  "superseded": 1,
  "appliedDeletions": 2,
  "duplicateDeletions": 0,
  "cascadedDeletions": 3,
  "schemaVersion": 3
}
```

Clients validate that `accepted + duplicates + superseded` equals the number
of upserts sent and `appliedDeletions + duplicateDeletions` equals the number
of deletes sent; anything else is a delivery failure (safe to retry).
`cascadedDeletions` is informational and not part of reconciliation.

## Large records and series

Series-shaped data (ECG voltage, workout routes, heartbeat intervals) is
chunked at the source: each record carries at most 2048 points, and chunk
identity is deterministic — a chunk's `id` is derived from
`(seriesID, chunkIndex)`, so a retried batch re-derives the same ids and the
receiver's idempotency applies unchanged. Deleting a parent (workout, route,
ECG) cascades to its chunk rows as described above. Receivers therefore need
no special large-record handling beyond the body, batch-count, and per-record
data limits stated here.

## Connection test — `GET` to the configured endpoint URL

Verifies reachability, TLS, and the credential — without sending or returning
any health records.

- Requires the same Bearer authentication as ingestion.
- Accepts no request body. A non-empty body is rejected with
  `400 connection_test_body_not_allowed`.
- Never returns stored records.

`GET /v1/health` is an alias for the same behavior. The iOS client always uses
`GET` on the exact configured endpoint URL.

Response:

```json
{
  "status": "ok",
  "service": "vitalroute-receiver",
  "apiVersion": 3,
  "capabilities": ["additions", "deletions"]
}
```

Clients that only need additions may ignore `capabilities`; clients that
synchronize deletions must see `apiVersion >= 3` and `"deletions"` in
`capabilities` before enabling that mode.

## Idempotency and record identity

The record `id` (the Apple Health sample UUID generated on-device, or the
client-derived deterministic id of a series chunk) is the stable record
identity. The receiver persists each `id` once: retries, replays, and
repeated syncs never duplicate stored records. If the same `id` is ingested
again — even with different field values — the first stored version wins and
the repeat is counted in `duplicates`. Clients may therefore retry any
failed batch safely.

## Validation rules

A batch is atomic: it is either fully persisted or not at all. Any validation
failure rejects the entire request with a 4xx and nothing is stored.

| Rule | Failure code (HTTP 400 unless noted) |
|---|---|
| Valid JSON body required (NaN/Infinity literals are not valid) | `invalid_json` |
| `Content-Type: application/json` required | `invalid_content_type` |
| `Content-Length` required; any `Transfer-Encoding` is refused | `411 length_required` / `invalid_transfer_encoding` |
| `Content-Length` must be a non-negative integer when present | `invalid_content_length` |
| Body size ≤ 10 MiB (configurable) | `413 payload_too_large` |
| ≤ 500 changes per batch (configurable) | `too_many_records` |
| Non-empty `changes` array | `empty_batch` |
| Top-level keys exactly `schemaVersion`, `createdAt`, `batchId`, `changes` | `invalid_payload` |
| `schemaVersion` must be `3` | `unsupported_schema_version` |
| `createdAt` ISO 8601 with offset; `batchId` canonical UUID | `invalid_payload` / `invalid_record` |
| Change `kind` `upsert` or `delete` with exactly its fields | `invalid_record` |
| Envelope keys exactly the contract fields | `invalid_record` |
| `id` a canonical UUID string | `invalid_record` |
| `metric` a well-formed identifier (no allowlist) | `invalid_metric` |
| `kind` one of the eight supported record kinds | `unknown_record_kind` |
| `startDate` / `endDate` ISO 8601 with offset; `endDate` ≥ `startDate` | `invalid_record` |
| `sourceName` / `deviceName` optional: absent, null, or a string ≤ 256 characters | `invalid_record` |
| `metadata` object with ≤ 32 string keys (≤ 64 chars each) and string values (≤ 512 chars each) | `invalid_record` |
| `data.type` a known type and equal to the envelope `kind` | `unknown_record_data_type` / `invalid_record_data` |
| `data` shape valid for its kind (exact field sets, finiteness, bounds) | `invalid_record_data` |
| Canonical `data` ≤ 1 MiB | `record_too_large` |

The two optional name fields may be omitted entirely — the natural spelling
produced by Swift's `JSONEncoder` for nil optionals — or sent as `null`; both
are stored as absent. Unknown fields are rejected rather than ignored, so
contract drift fails loudly instead of silently dropping data.

## Error responses

Every error uses the same safe shape — no payload echo, no credentials, no
internal details:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "A valid bearer token is required."
  }
}
```

- `401 unauthorized` — missing token, unknown scheme, or wrong token.
  Accompanied by `WWW-Authenticate: Bearer`.
- `404 not_found` — unknown path.
- `405 method_not_allowed` — known path, unsupported method (with `Allow`).
- `429` / `5xx` — a backend may apply rate limits or report internal errors;
  clients treat any non-2xx, and any 2xx without a valid acknowledgment, as
  failure.

## Versioning

`schemaVersion: 3` is the current payload schema and `apiVersion: 3` the
current receiver version. Backward-incompatible changes bump both; receivers
reject other versions with `unsupported_schema_version` rather than guessing.

### Database reset policy (pre-release)

There is no migration machinery from earlier development schemas. When the
receiver opens a database that does not match its schema generation — a
different declared `schema_version`, or record tables with no declared
version — it refuses to start rather than discard health data. Starting it
with `VITALROUTE_ALLOW_SCHEMA_RESET=1` in the environment recreates the
database empty instead, logging a single line (never any
data). Operators upgrading a pre-3 deployment therefore either re-sync from
the device afterwards or restore from a backup taken before the upgrade.

## Operational guarantees

- The receiver acknowledges only after a successful database commit.
- Operational logging records method, path, status, and byte counts —
  never headers, tokens, or record contents.
- The reference receiver binds to `127.0.0.1` by default and has no accounts,
  dashboard, query interface, or outbound connections.
- Paths match exactly: query strings and trailing slashes are not part of the
  contract and return `404`.
- Error responses sent before a request body was consumed close the
  connection (`Connection: close`), so unread body bytes can never be parsed
  as a following request.
- Every socket read is bounded (`VITALROUTE_SOCKET_TIMEOUT`, default 30s): a
  client that stalls mid-request loses its connection rather than pinning a
  worker. Idle keep-alive connections are reaped by the same timeout.
