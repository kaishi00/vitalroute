# VitalRoute Receiver API — Contract v1

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

## Operations

### Ingest a batch — `POST` to the configured endpoint URL

The endpoint URL the user configures in the app **is** the ingestion URL, for
example `https://health.example.org/v1/records`. One request carries one batch.

Request headers:

```
Authorization: Bearer <token>
Content-Type: application/json
Accept: application/json
```

Request body — the VitalRoute sync payload, schema version 1:

```json
{
  "schemaVersion": 1,
  "createdAt": "2026-09-23T12:00:00.000Z",
  "records": [
    {
      "id": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
      "metric": "steps",
      "value": 8432,
      "unit": "count",
      "startDate": "2026-09-22T00:00:00.000Z",
      "endDate": "2026-09-22T23:59:59.000Z",
      "sourceName": "Apple Watch",
      "deviceName": "Watch",
      "metadata": {}
    }
  ]
}
```

`GET` on the same URL performs the connection test (below). This keeps client
configuration to a single URL regardless of where a backend mounts the API.

## Version 2: additions and deletions — `schemaVersion: 2`

Contract v2 extends the same endpoint with a change-batch payload. The
version selects the schema: a v1-only receiver rejects `schemaVersion: 2`
with `unsupported_schema_version` (its existing behavior), and a v2 receiver
never reinterprets a v1 body as v2 or vice versa — `schemaVersion` must match
the body shape (`records` for v1, `changes` for v2).

```json
{
  "schemaVersion": 2,
  "createdAt": "2026-09-24T12:00:00.000Z",
  "batchId": "7f6c1a2e-9b34-4d05-8c11-2f0a54d7b901",
  "changes": [
    { "kind": "upsert", "record": { "...": "a full v1 record object" } },
    {
      "kind": "delete",
      "id": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
      "metric": "steps",
      "startDate": "2026-09-22T00:00:00.000Z",
      "endDate": "2026-09-22T23:59:59.000Z"
    }
  ]
}
```

- `batchId` is a canonical UUID chosen by the client per batch attempt.
- `upsert.record` must satisfy every v1 record validation rule.
- `delete` identifies the deleted sample by its id (the Apple Health sample
  UUID), with its category and last known interval. Validation rules mirror
  v1 (`unknown_metric`, ISO 8601 dates, `endDate` ≥ `startDate`).
- Limits and framing match v1 (≤ 500 changes per batch, 10 MiB body,
  Content-Length required, transfer encoding refused).
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

Acknowledgment (after commit):

```json
{
  "status": "accepted",
  "accepted": 8,
  "duplicates": 1,
  "superseded": 1,
  "appliedDeletions": 2,
  "duplicateDeletions": 0,
  "schemaVersion": 2
}
```

Clients validate that `accepted + duplicates + superseded` equals the number
of upserts sent and `appliedDeletions + duplicateDeletions` equals the number
of deletes sent; anything else is a delivery failure (safe to retry).

Migration: opening a v1 database with a v2 receiver adds the `deleted_ids`
table via `CREATE TABLE IF NOT EXISTS`. Existing rows are never rewritten
and v1 ingestion behavior is unchanged.

### Connection test — `GET` to the configured endpoint URL

Verifies reachability, TLS, and the credential — without sending or returning
any health records.

- Requires the same Bearer authentication as ingestion.
- Accepts no request body. A non-empty body is rejected with
  `400 connection_test_body_not_allowed`.
- Never returns stored records.

`GET /v1/health` is an alias for the same behavior. The iOS client always uses
`GET` on the exact configured endpoint URL.

## Success responses

Both operations respond `200` with a JSON body the client must validate:

Connection test:

```json
{
  "status": "ok",
  "service": "vitalroute-receiver",
  "apiVersion": 2,
  "capabilities": ["additions", "deletions"]
}
```

Clients that only need v1 (records-only manual sync) may ignore
`capabilities`; clients that synchronize deletions must see `apiVersion >= 2`
and `"deletions"` in `capabilities` before enabling that mode.

Ingestion acknowledgment (sent only after the batch has been committed):

```json
{
  "status": "accepted",
  "accepted": 12,
  "duplicates": 3,
  "schemaVersion": 1
}
```

- `accepted` — records newly persisted by this request.
- `duplicates` — records in the batch whose `id` already existed (see
  idempotency below); they are not stored again and are not an error.
- `accepted + duplicates` equals the number of records in the batch.

A client treats a 2xx whose body does not match the shape above (missing
`status`, wrong `status` value, missing counts) as a **failure**, not as
successful ingestion.

## Idempotency and record identity

The record `id` (the Apple Health sample UUID generated on-device) is the
stable record identity. The receiver persists each `id` once: retries, replays,
and repeated manual syncs never duplicate stored records. If the same `id` is
ingested again — even with different field values — the first stored version
wins and the repeat is counted in `duplicates`. Clients may therefore retry any
failed batch safely.

## Validation rules

A batch is atomic: it is either fully persisted or not at all. Any validation
failure rejects the entire request with a 4xx and nothing is stored.

| Rule | Failure code (HTTP 400 unless noted) |
|---|---|
| Valid JSON body required | `invalid_json` |
| `Content-Type: application/json` required | `invalid_content_type` |
| `Content-Length` required; any `Transfer-Encoding` is refused | `411 length_required` / `invalid_transfer_encoding` |
| `Content-Length` must be a non-negative integer when present | `invalid_content_length` |
| Body size ≤ 10 MiB (configurable) | `413 payload_too_large` |
| ≤ 500 records per batch (configurable) | `too_many_records` |
| Non-empty `records` array | `empty_batch` |
| Top-level keys exactly `schemaVersion`, `createdAt`, `records` | `invalid_payload` |
| `schemaVersion` must be `1` | `unsupported_schema_version` |
| `createdAt` ISO 8601 with offset | `invalid_payload` |
| Record keys limited to the nine contract fields | `invalid_record` |
| `id` a canonical UUID string | `invalid_record` |
| `metric` one of the seven supported values below | `unknown_metric` |
| `value` a finite number | `invalid_record` |
| `unit` non-empty, ≤ 64 characters | `invalid_record` |
| `startDate` / `endDate` ISO 8601 with offset; `endDate` ≥ `startDate` | `invalid_record` |
| `sourceName` / `deviceName` optional: absent, null, or a string ≤ 256 characters | `invalid_record` |
| `metadata` object with ≤ 32 string keys (≤ 64 chars each) and string values (≤ 512 chars each) | `invalid_record` |

Supported `metric` values: `steps`, `heartRate`, `restingHeartRate`,
`heartRateVariability`, `sleep`, `activeEnergy`, `workouts`.

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

`schemaVersion: 1` is the current payload schema. Backward-incompatible
changes bump the schema version and `apiVersion`; receivers reject unknown
schema versions with `unsupported_schema_version` rather than guessing.

## Operational guarantees

- The receiver acknowledges only after a successful database commit.
- Operational logging records method, path, status, duration, and byte counts —
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
