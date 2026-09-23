# Automatic Background Sync — Design

Scope: after the user explicitly enables automatic sync, VitalRoute observes
changes to selected Apple Health categories and reliably delivers additions
**and deletions** to the configured receiver, resuming safely after
interruptions. Out of scope: MCP/agent access, dashboards, new categories,
subscriptions, vendor services.

Sources followed: Apple's `HKAnchoredObjectQuery` documentation (the anchor
corresponds to the last sample **or deleted object received by that query**;
pass it back to get subsequent changes), `HKObserverQuery` +
`enableBackgroundDelivery(for:frequency:)` (the only background-update
mechanism; iOS throttles wake-ups and never guarantees immediacy).

## 1. State model

```
                     enable (foreground user action)
  Disabled ──────────────────────────────────────────────► Active
     ▲                                                      │
     │ disable                                              │ pause(reason)
     │                                                      ▼
     └──────────── disable ◄───────────────────────────  Paused(reason)
                                                                  │
                             reason resolved + next opportunity   │
                             (foreground catch-up / observer wake /
                              BG task)                            │
                                                                  └──► Active
```

- **Disabled** (default; existing installs stay here): no observers, no
  background tasks, no network work.
- **Active**: observers registered for every selected category; observers are
  restored at every supported app launch (app-level, not screen-level).
- **Paused(reason)**: automatic work stops, queued work and checkpoints are
  kept. Reasons: destination or credential missing/changed, receiver
  incompatible (auth/protocol/ack failures), queue at capacity, category
  selection empty, protected data unavailable (locked device).
- Enabling requires: saved destination + credential + non-empty selection +
  a foreground receiver capability check (see §5) + HealthKit authorization
  requested through the foreground action that enables. Background work never
  presents an authorization sheet; if authorization is missing at run time the
  pass defers.

### Lifecycle rules

| Event | Behavior |
|---|---|
| Destination changed / removed | Automatic sync **disables**; pending events and checkpoints bound to the previous destination identity are discarded with a visible notice. Nothing is ever re-pointed to a different recipient. |
| Credential replaced (same destination) | State kept; pending work stays; the next attempt uses the new credential. |
| Category disabled | That category's observers stop, its queued events are removed (never uploaded), and its checkpoint is cleared. Other categories continue. |
| Category re-enabled | A **new scope generation** is minted: fresh 7-day bootstrap (never silently lifetime history, never a silent gap). |
| Queue at capacity | Query passes stop (backpressure); state surfaces pending work; delivery resumes draining first. |

## 2. Scopes, checkpoints, and query invariants

A **scope** binds a checkpoint to everything it depends on:

```swift
SyncScopeID = destinationIdentity + category + scopeGeneration(UUID)
```

- `destinationIdentity` is the canonical saved endpoint string (same identity
  the credential Keychain namespace uses).
- A new `scopeGeneration` is minted on: initial enable, category re-enable,
  and any destination change (which disables and requires re-enabling).
- Each scope fixes its query definition at creation:
  `predicate = startDate >= (bootstrapMoment − 7 days)` — **fixed, not
  moving**. Per Apple's anchor semantics (anchor = last object *received* by
  that query), an anchor is only ever reused with the exact predicate it was
  produced with. Incremental queries for a scope always use the scope's fixed
  predicate. Documented trade-off: backdated samples whose start date is
  older than the scope window are not captured (same window semantics as
  manual sync).
- A stored checkpoint whose scope ID no longer matches the current scope for
  that category is invalid → the category re-bootstraps (fresh generation,
  7-day window).
- Known limitation, documented: deletions of samples that predate the scope
  window are not reported (predicate-filtered), matching the windowed scope.

**Checkpoint advance rule**: a checkpoint (serialized `HKQueryAnchor`) is
persisted only *after* the additions and deletions of the pages it covers are
durably recorded in the outbox (or already acknowledged) — written in that
order, so a crash always produces replay, never loss.

## 3. Durable outbox

Location: `Application Support/VitalRouteSync/` containing per-event files
(`evt-<id>.json`), per-category checkpoint files (`chk-<category>.json`), and
retry state (`retry.json`). Writes are temp-file + rename (atomic); the
directory uses `.completeUntilFirstUserAuthentication` file protection
(available for background delivery after first unlock; still encrypted at
rest otherwise) and `isExcludedFromBackup = true`. Contents are health
records — retained only until acknowledged, then deleted.

- **Event kinds**: `upsert` (full v1 record) and `delete` (id + metric + last
  known dates). Event identity: sample UUID for upserts, `del-<uuid>` for
  deletions. Loading dedupes by event id, so crash-replays are harmless.
- **Capture→deliver split**: query passes append events and advance
  checkpoints; delivery drains events in batches. Cancellation or budget
  expiry during delivery leaves events pending.
- **Backpressure**: when pending events ≥ cap (10,000), query passes stop and
  the state surfaces pending work. Changes are never discarded by a query
  pass.
- **Recovery boundaries** (all tested):
  - crash after event files, before checkpoint → re-query returns the same
    changes → dedupe → exactly one upload;
  - crash after checkpoint, before upload → events pending, delivered later;
  - server committed but response lost → retry → receiver answers
    idempotently → events removed;
  - crash after ack, before removal → reload re-sends → duplicate ack →
    removed.

Deletion notifications are treated as unrecoverable-later: they are captured
into the outbox at query time and never dropped.

## 4. Execution model

- **One serialization boundary**: an actor (`SyncWorkGate`) guards all sync
  work. The manual coordinator and the background engine acquire it, so
  manual and automatic work can never run concurrently or race checkpoints.
- **Observer callback**: returns immediately after starting a bounded Task;
  the Task does (1) a bounded incremental query pass (page budget, page size
  500, ≤ 20 pages per pass), (2) outbox commit + checkpoint advance, (3) a
  bounded delivery attempt. The observer callback never waits on network
  success. Changes arriving during an active run are handled by the next
  pass (observer re-fires; foreground catch-up; BG task).
- **HealthKit continuations are cancellation-safe** before registration and
  against late callbacks (claim-once guard, as in the existing pager).
- **Background budget**: `BGTaskScheduler` app-refresh task
  (`com.milim.vitalroute.sync`) drives retries when events are pending. Its
  expiration handler cancels the in-flight operation; queries and network
  work check cancellation between pages/batches. Registered in the app
  process before finish-launching (project.yml adds `UIBackgroundModes`
  fetch/processing and `BGTaskSchedulerPermittedIdentifiers`).
- **Retry policy**: persisted consecutive-failure count and next-attempt
  time; exponential backoff 1 min → 2× … capped at 1 day; no busy loops, no
  unlimited timers. Transient failures (timeouts, unreachable, 5xx) retry.
  Actionable failures (401/403, unsupported schema/protocol, malformed
  acknowledgment) pause with a user-visible reason and do not retry.
  Locked-device / protected-data-unavailable states defer (no error storm).
- **Recovery triggers** (documented in-app): HealthKit background delivery
  wake, BGTask retry, app foreground catch-up, manual sync completion.
  Limits: iOS suspends/throttles background wakes; force-quitting the app
  stops background delivery until the next launch; the app never implies
  guaranteed or immediate delivery.

## 5. Receiver contract v2 (deletions)

Same endpoint, explicit new payload version — a v1 receiver rejects
`schemaVersion: 2` with `unsupported_schema_version` (already its behavior),
so nothing is silently reinterpreted.

- **Capability detection**: `GET` the configured endpoint. v2 receivers
  return `"apiVersion": 2` plus `"capabilities": ["additions", "deletions"]`.
  The client requires both before automatic sync can be enabled. v1 health
  responses (no capabilities / apiVersion 1) → automatic sync unavailable
  with guidance to update the receiver; manual v1 sync keeps working.
- **`schemaVersion: 2` body**: `{"schemaVersion": 2, "createdAt", "batchId",
  "changes": [{"kind":"upsert","record":{…v1 record…}} | {"kind":"delete",
  "id","metric","startDate","endDate"}]}` — same per-record validation as v1,
  ≤ 500 changes per batch, 10 MiB cap, one transaction per batch.
- **Server semantics**: upserts are `INSERT OR IGNORE` (first-write-wins)
  **unless a tombstone exists** for the id, in which case the upsert is
  counted as `superseded` and ignored — an older queued or retried addition
  can never resurrect a deleted sample. Deletes upsert a tombstone
  (`deleted_ids` table) and remove any live row. Retrying a deletion is
  idempotent (`duplicateDeletions`).
- **Acknowledgment v2**: `{"status":"accepted","accepted","duplicates",
  "appliedDeletions","duplicateDeletions","superseded","schemaVersion":2}`.
  The client reconciles: upserts + duplicates + superseded == upserts sent;
  appliedDeletions + duplicateDeletions == deletes sent; anything else is
  treated as delivery failure (retry-safe).
- **Migration**: additive schema (`deleted_ids` table + schema_info row) via
  `CREATE TABLE IF NOT EXISTS` on open; existing v1 databases and rows are
  untouched; no data rewrite. v1 ingestion behavior is unchanged.

## 6. Testing strategy

Deterministic iOS tests use injected stores (real file-based outbox/state in
temp directories for crash-window recovery), stubbed health providers and
clients. Receiver tests are real-HTTP against ephemeral ports. The TLS
integration runner gains: addition → retry (idempotency) → deletion → old
addition replay (tombstone prevents resurrection) → final database
inspection. Physical-device validation for real background delivery is a
separate checklist (simulator cannot prove background wakes).
