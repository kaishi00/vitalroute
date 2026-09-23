# Physical-Device Validation Checklist — Automatic Background Sync

Simulator integration (real TLS, real receiver) proves the wire protocol,
checkpoints, outbox recovery, and tombstone semantics. It cannot prove
HealthKit background delivery, which only iOS on hardware exercises. Before
relying on automatic sync for real data, validate on a physical iPhone:

1. **Authorization prompt path** — first enable of automatic sync in the
   foreground shows the HealthKit permission sheet for exactly the selected
   categories; granting produces a successful bootstrap (Settings shows a
   last delivery).
2. **Watch-written samples** — with the app in the background, record
   samples from a paired Apple Watch (workout, heart-rate, steps). Confirm
   the observer wake captures and delivers them (Settings → last check /
   last delivery advance; the receiver database grows).
3. **Deletion propagation** — delete a sample in the Health app; confirm a
   `delete` event reaches the receiver and the row disappears while the
   tombstone exists.
4. **Locked device deferral** — with the phone locked long enough for
   protection to engage, confirm delivery defers (status message) and
   resumes after unlock without data loss.
5. **Force-quit and relaunch** — force-quit the app, add samples, relaunch:
   the launch restoration re-registers observers and the foreground
   catch-up delivers the missed changes.
6. **Network failure recovery** — enable airplane mode, add samples, disable
   airplane mode: pending changes deliver with backoff, exactly once.
7. **Background budget** — confirm the BGTask retry fires over a long idle
   period with pending work (Settings → next retry countdown, then a
   delivery without opening the app).
8. **Destination change** — repoint the destination with work pending:
   automatic sync disables with the discard notice; nothing is sent to the
   new destination from the old queue.

Limitation statement: until this checklist is executed on hardware,
background-delivery behavior (throttling frequency, wake reliability,
locked-state deferral) is validated only at the API-contract and
architecture level, not end-to-end.
