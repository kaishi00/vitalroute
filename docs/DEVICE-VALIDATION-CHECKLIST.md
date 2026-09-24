# Physical-Device Validation Checklist — Automatic Background Sync

Simulator integration (real TLS, real receiver) proves the wire protocol,
checkpoints, outbox recovery, and tombstone semantics. It cannot prove
HealthKit background delivery, which only iOS on hardware exercises. Before
relying on automatic sync for real data, validate on a physical iPhone:

0. **Entitlement and signing** — build with a provisioning profile for
   `com.milim.vitalroute` that has the HealthKit capability, then confirm the
   *signed* app carries both `com.apple.developer.healthkit` and
   `com.apple.developer.healthkit.background-delivery` (for example
   `codesign -d --entitlements - VitalRoute.app`). Simulator builds strip
   these device-only entitlements, so simulator evidence cannot cover this
   step. Without the profile and entitlement, `enableBackgroundDelivery`
   fails on iOS 15+ and observer-driven background work silently never
   arrives.
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
9. **Destination change while off** — with automatic sync off and work still
   queued, change the destination, then re-enable: the queued changes are
   discarded with a notice and only newly captured data reaches the new
   endpoint. Repeat with the app force-quit between the destination change
   and the relaunch.
10. **Turn-off while degraded** — clear the category selection (or remove
   the API key) while automatic sync is on, then confirm the Settings toggle
   can still be turned **off**.

Limitation statement: until this checklist is executed on hardware,
background-delivery behavior (throttling frequency, wake reliability,
locked-state deferral) is validated only at the API-contract and
architecture level, not end-to-end.

## Device-validation status — 2026-09-23 (tested commit `9b2fa52`)

Attempted on the build Mac (Xcode 27.0 / 27A266a, team `U2TH557QA8`,
ASC API key `4K2295KL5Q`, tested commit `9b2fa52`):

| Case | Status | Observed |
|---|---|---|
| 0 Entitlement and signing | **BLOCKED** | See breakdown below. |
| 1 Authorization prompt path | **BLOCKED** | No physical device available. |
| 2 Watch-written samples | **BLOCKED** | No physical device or paired Watch available. |
| 3 Deletion propagation | **BLOCKED** | No physical device available. |
| 4 Locked device deferral | **BLOCKED** | No physical device available. |
| 5 Force-quit and relaunch | **BLOCKED** | No physical device available. |
| 6 Network failure recovery | **BLOCKED** | No physical device available. |
| 7 Background budget | **BLOCKED** | No physical device available. |
| 8 Destination change | **BLOCKED** | No physical device available. |
| 9 Destination change while off | **BLOCKED** | No physical device available. |
| 10 Turn-off while degraded | **BLOCKED** | No physical device available. |

Case 0 evidence, split by class (source inspection and portal state are
not signed-app evidence):

- Source and packaging (verified at this commit): `project.yml`,
  `VitalRoute/VitalRoute.entitlements`, and the generated project
  (which wires the entitlements file in via `CODE_SIGN_ENTITLEMENTS`)
  all declare both `com.apple.developer.healthkit` and
  `com.apple.developer.healthkit.background-delivery`; simulator builds
  strip them into the sidecar `app-Simulated.xcent`, so simulator
  artifacts cannot satisfy this step.
- Portal (read via the App Store Connect API): bundle ID
  `com.milim.vitalroute` is registered (id `NK93X58H2Z`) with the
  HealthKit capability enabled. An Apple Distribution certificate
  matching the Mac keychain identity exists (expires 2027-05), but a
  distribution certificate alone cannot satisfy Case 0 — installing
  the app on the validation iPhone still requires a development (or
  ad hoc) profile that includes a registered device.
- Blockers (each independently sufficient): Xcode on the build Mac has
  **no signed-in Apple ID account** (`-allowProvisioningUpdates` fails
  with "No Accounts"); the team has **zero registered devices**, so
  Apple refuses to generate a development profile ("Your team has no
  devices from which to generate a provisioning profile"); the ASC API
  key can read the portal but is **not permitted to create profiles**
  (HTTP 403 `FORBIDDEN_ERROR` — role below App Manager).

To unblock, the account owner must: connect the physical iPhone to the
build Mac (or register its UDID in Certificates, Identifiers &
Profiles), provide a profile source (sign in to Xcode → Settings →
Accounts for team `U2TH557QA8`, or issue an API key with the App
Manager role or above, or create the profile manually in the portal),
and pair the Apple Watch for case 2. Cases 3–7 additionally require
on-device gestures (Health-app deletion, lock/unlock, force-quit,
airplane mode) that only the device holder can perform.
