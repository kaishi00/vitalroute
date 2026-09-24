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
mechanism; iOS throttles wake-ups and never guarantees immediacy), and
Apple's observer-processing contract (the observer's completion handler must
be called when the app has finished the work the notification triggered).
Background delivery additionally requires the
`com.apple.developer.healthkit.background-delivery` entitlement: on iOS 15
and later `enableBackgroundDelivery` fails without it. Both HealthKit
entitlements are declared in `project.yml` and generated into
`VitalRoute/VitalRoute.entitlements`.

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
  Restoration deliberately trusts the destination that was verified when
  automatic sync was enabled: it does not re-run the capability check, so a
  launch without network still arms observation and captures locally. A
  receiver downgraded in place is then reported at delivery time as an
  actionable pause — the trade-off taken to keep background capture working
  offline.
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
| Credential replaced (same destination) | State kept; pending work stays; the next attempt uses the new credential (the credential store publishes a nonsecret revision so a same-endpoint replacement reaches the engine). |
| Category disabled | That category's observers stop, the in-flight pass is cancelled and awaited, its queued events are removed and its checkpoint cleared; other categories continue. A batch already committed to the wire cannot be recalled, so — as with the destination purge — what is *not* uploaded is the queued work that had not yet been sent. |
| Category re-enabled | A **new scope generation** is minted: fresh bootstrap at the configured backfill depth (never a silent gap; lifetime history only when the user chose All records). |
| Queue at capacity | Query passes stop (backpressure); state surfaces pending work; delivery resumes draining first. |
| Destination changed while automatic sync is **off** | The queue bound to the previous destination is discarded with a visible notice — queued health data must never become deliverable to an endpoint it was not captured for. |
| Configuration (destination, credential, or selection) changes while an operation is suspended | The newer decision wins. A generation counter is claimed before the first suspension of every user decision; a resumed enable, registration, or restore finds itself superseded, unwinds, and mutates nothing. |

## 2. Scopes, checkpoints, and query invariants

A **scope** binds a checkpoint to everything it depends on:

```swift
SyncScopeID = destinationIdentity + category + scopeGeneration(UUID)
```

- `destinationIdentity` is the canonical saved endpoint string (same identity
  the credential Keychain namespace uses).
- A new `scopeGeneration` is minted on: initial enable, category re-enable,
  a deepened backfill depth, and any destination change (which disables and
  requires re-enabling).
- Each scope fixes its query definition at creation:
  `predicate = startDate >= (bootstrapMoment − backfillDepth)` — **fixed, not
  moving**. The backfill depth is user-configurable (7 days default; 30/90
  days, 1 year, or the entire history), so "how far back the first sync of a
  category reaches" is an explicit choice made in Settings. Per Apple's
  anchor semantics (anchor = last object *received* by that query), an anchor
  is only ever reused with the exact predicate it was produced with.
  Incremental queries for a scope always use the scope's fixed predicate.
  Deepening the depth mints a fresh scope generation whose window reaches
  further back (a deliberate re-bootstrap that captures the older history);
  making it shallower never discards an existing deeper scope — everything
  from enablement forward is captured regardless of this setting. Documented
  trade-off: samples older than a scope's fixed window are only captured by
  deepening the depth (which re-bootstraps that category).
- A stored checkpoint whose scope ID no longer matches the current scope for
  that category is invalid → the category re-bootstraps (fresh generation,
  window from the configured backfill depth).
- Known limitation, documented: deletions of samples that predate the scope
  window are not reported (predicate-filtered), matching the windowed scope.

**Checkpoint advance rule**: a checkpoint (serialized `HKQueryAnchor`) is
persisted only *after* the additions and deletions of the pages it covers are
durably recorded in the outbox (or already acknowledged) — written in that
order, so a crash always produces replay, never loss.

## 3. Durable outbox

Location: `Application Support/VitalRouteSync/` containing per-event files
(`evt-<id>.json`), per-category checkpoint files (`chk-<category>.json`), and
retry state (`retry.json`), and the queue's owner (`pending-scope.json` —
the destination identity the queued changes were captured for). Writes are temp-file + rename (atomic); the
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
  the state surfaces pending work. The cap is soft: it is checked once before
  the query pass and again between categories, not before each page within a
  category, so one category's whole page budget for that pass (up to 20 pages
  of additions, plus their deletions) can overshoot it before the next check.
  Changes are never discarded by a query pass.
- **Destination binding**: the queue records the destination it was captured
  for, durably. A pass refuses to add to, and delivery refuses to send, a
  queue whose recorded owner differs from the destination in effect —
  discarding it with a visible notice instead. Absent ownership information
  fails closed. This covers a destination change made while the app was not
  running, where no in-session purge could have seen it. A discard notice
  survives later successful deliveries: dropping health data the user chose
  to send is not a transient hiccup.
- **Recovery boundaries** (all tested):
  - crash after event files, before checkpoint → re-query returns the same
    changes → dedupe → exactly one upload;
  - crash after checkpoint, before upload → events pending, delivered later;
  - server committed but response lost → retry → receiver answers
    idempotently → events removed;
  - crash after ack, before removal → reload re-sends → duplicate ack →
    removed.

Deletion notifications are treated as unrecoverable-later: they are captured
into the outbox at query time and never dropped. `HKDeletedObject` exposes
only the sample UUID (not its dates), so deletion events carry the capture
time as their interval; the receiver's tombstone stores it for audit.

## 4. Execution model

- **One serialization boundary**: an actor (`SyncWorkGate`) guards all sync
  work. The manual coordinator and the background engine acquire it, so
  manual and automatic work can never run concurrently or race checkpoints.
- **Ownership by generation**: every asynchronous operation captures the
  configuration generation it belongs to and checks it before mutating the
  mode, arming observers, scheduling successor work, or starting an upload.
  A stale completion unwinds instead of applying, so a cancelled pass can
  never resurrect a pause over a purge, and an enable suspended in the
  authorization prompt or capability check can never activate an endpoint or
  selection the user has already replaced.
- **Observer callback**: the callback returns immediately, but HealthKit's
  completion handler is held until the triggered work is *durable* — the
  capture pass has appended its events and advanced its checkpoints — and is
  released exactly once. Delivery is never allowed to hold it: a parked
  upload must not delay the answer, and a stalled receiver must not look like
  a stalled app. If a capture cannot finish inside the coordinator's deadline
  (25 s) the completion is released anyway, and the next pass resumes from
  the persisted checkpoint — only the notification is lost, never the data.
  Overlapping notifications that arrive during capture share the capture
  that answers them; one that arrives while the pass is delivering is
  answered when the pass settles, and the changes it signalled are captured
  by the next pass from the persisted checkpoint. A notification that
  arrives after teardown is still answered.
- **Transactional observer lifecycle**: registration is all-or-nothing (a
  partial `enableBackgroundDelivery` failure unwinds what it armed), and
  registration and teardown are serialized and generation-fenced, so a
  registration suspended mid-flight cannot install observers after a stop,
  and a stale teardown cannot remove the registration that replaced it.
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

Same endpoint, explicit new payload version. A v1-only receiver rejects a v2
body outright — with `invalid_payload`, because the shape does not match its
contract — so nothing is silently reinterpreted.

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
clients, and a controllable HealthKit observer backend (the live store cannot
be made to fail a second type's enablement, suspend a registration, or
deliver a late callback on demand). Race regressions wait for the state that
must appear rather than sleeping. Receiver tests are real-HTTP against ephemeral ports. The TLS
integration runner gains: addition → retry (idempotency) → deletion → old
addition replay (tombstone prevents resurrection) → final database
inspection. Physical-device validation for real background delivery is a
separate checklist: a simulator cannot prove background wakes, and simulator
builds strip the device-only HealthKit entitlements.
