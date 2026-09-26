# VitalRoute record architecture (contract v3)

This document describes the health-record model introduced before any
broad HealthKit metric expansion: a common record **envelope** plus a
strongly typed **data payload**, a static client-side **metric catalog**,
and a chunked strategy for **large series**. The wire contract lives in
`server/API.md`; the reliability machinery that moves these records lives
in `docs/BACKGROUND-SYNC-DESIGN.md`.

## Design rules

1. **`metric` answers WHAT, `kind` answers HOW.** A record's metric
   identifies the health information ("heart rate", "blood pressure");
   its kind identifies the structure ("a scalar quantity", "a workout",
   "a clinical document"). The two are independent axes — a metric whose
   data continues into a series emits parent records of its own kind plus
   chunk records of kind `series` under the same metric.
2. **No `Any`.** Every payload is an explicit `Codable` struct; the one
   open-ended leaf (clinical FHIR) is an explicit recursive JSON value,
   not type erasure. Unknown or mismatched payload types fail decoding —
   on the client (outbox quarantine) and in the receiver (HTTP 400).
3. **The client owns the metric catalog.** The receiver validates schema,
   envelope, kind, payload shape, and size — it never needs an update
   when a new metric appears. Unknown *kinds* still fail there, because a
   kind is a structural contract both sides must understand.
4. **Identity is stable.** Record `id` is the Apple Health sample UUID,
   or a deterministic UUID derived from `(seriesID, chunkIndex)` for
   series chunks. First-write-wins storage plus stable identity is what
   makes every retry safe.

## The envelope

```
HealthRecord
  id          UUID     Apple Health sample UUID (or derived chunk UUID)
  metric      String   catalog-owned metric identifier ("heartRate")
  kind        Kind     structural type, equal to data.type
  startDate   Date
  endDate     Date
  sourceName  String?  Apple Health provenance
  deviceName  String?
  metadata    [String: String]  small annotations (not a payload drawer)
  data        RecordData        the typed payload, discriminated by type
```

The envelope is what the receiver indexes and queries; `data` is what it
preserves verbatim.

## Record kinds and payloads

| Kind | Payload (after `data.type`) | Represents |
|---|---|---|
| `quantity` | `{value, unit}` | scalar samples (steps, heart rate, …) |
| `category` | `{value, name?}` | categorical samples (sleep stages) |
| `correlation` | `{components: [{metric, value, unit}]}` | blood pressure and friends |
| `workout` | `{activityType, activityTypeRawValue, duration, totalEnergyKilocalories?, totalDistanceMeters?}` | workouts with structured details |
| `activitySummary` | fixed optional daily fields | daily activity summaries |
| `series` | `{seriesType, seriesID, parentID?, chunkIndex, channels, points}` | chunked series (ECG voltage, routes) |
| `electrocardiogram` | `{classification, symptomStatus?, averageHeartRate?, samplingFrequency?, voltageSeriesID?…}` | ECG facts; voltage rides in `series` chunks |
| `clinical` | `{fhirType, fhirIdentifier?, fhirResource}` | clinical records with structurally preserved FHIR |

Units are canonicalized at the extractor: a quantity row's `unit` is the
wire spelling ("count/min", "ms", "kcal", "count", "mmHg"); workout and
summary quantities are pre-converted to their canonical units so
consumers never re-derive unit semantics.

## The metric catalog

`MetricCatalog.metrics` is the single static list of
`MetricDescriptor` values — display name, symbol, UI group, HealthKit
identifiers (own type + correlation component types), record kind /
extraction plan, and `userSelectable`. `HealthMetric` is a string-backed
identifier that only the catalog can mint, so unknown metrics fail at
the edge (decode, selection, persistence) instead of drifting through
the system.

Adding an ordinary quantity or category metric means adding one
descriptor entry — no other switch in the app changes. The extraction
switches are per-*plan* (`CanonicalUnit`, `CategoryNaming`) and
per-*kind*, shared by every metric of that structure. Component metrics
(e.g. systolic/diastolic) exist in the catalog with
`userSelectable: false` so correlation records can attribute them while
they stay invisible to selection and export.

## HealthKit extraction

`HealthKitRecordMapper` maps samples by extraction plan:

- quantity/category/correlation/workout extraction reads the typed
  HealthKit object and produces the payload; every part that touches a
  constructible HK object is unit-tested.
- ECG facts come from `HKElectrocardiogram` properties; the voltage
  measurements load through the `SeriesFetching` seam
  (`ECGVoltageSeriesFetcher`, `HKElectrocardiogramQuery`) and are chunked
  by the shared, tested chunker. The HK-object shells are thin because
  `HKElectrocardiogram` cannot be constructed in unit tests.
- Clinical records decode `HKFHIRResource.data` into `FHIRJSON` —
  structure preserved, never stringified.

The current visible catalog is deliberately unchanged (the seven
selectable metrics). The model, wire format, receiver validation, and
extraction seams already carry the families above; expanding the catalog
is descriptor + (for series kinds) loader wiring, not another protocol or
database redesign.

## Large series

Series data is chunked at the source (`SeriesLimits.pointsPerChunk = 2048`,
≤ 16 channels). Chunk identity is deterministic — SHA-256 of
`series:<seriesID>:<chunkIndex>` formatted as a UUID — so retries re-derive
the same records and idempotency holds. Chunk records reference their
parent via `parentID`; deleting a parent cascades server-side to child
rows (which are tombstoned too), so orphan cleanup never depends on the
client remembering chunk ids. The outbox enforces a byte budget (8 MiB)
on batch assembly alongside the 200-event count, keeping chunk-heavy
batches inside the receiver's 10 MiB body limit; a single oversized event
still ships as a legal batch of one.

## Storage and compatibility

Receiver rows are envelopes too: searchable envelope columns (`metric`,
`kind`, dates, source) plus `metadata_json`, `data_json`, and `parent_id`
(the cascade index). Quantity aggregation reads `data.value` through
`json_extract`; other kinds are counted, never averaged.

There is no migration machinery between schema generations: a database
whose declared `schema_version` differs from the receiver's is recreated
empty (one log line, no data exposure). This is a deliberate pre-release
policy — it trades a disposable development database for a clean
contract.
