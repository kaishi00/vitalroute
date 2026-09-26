# VitalRoute

VitalRoute is a native iOS app for routing the Apple Health data a person chooses to an HTTPS endpoint they control. The repository holds the iOS client and a reference receiving server together.

## What works today (manual sync milestone)

- **Explicit export selection** — the seven categories (steps, heart rate, resting heart rate, heart rate variability, sleep, active energy, workouts) are opt-in toggles; nothing is selected by default, and VitalRoute requests HealthKit read access only for the categories you enable.
- **Secure destination + credential** — the HTTPS endpoint and its API key are stored separately in the device Keychain. Keys are namespaced per destination, so changing endpoints never reuses the previous destination's key. "Test connection" checks reachability, TLS, and the key without sending health records.
- **Manual sync** — "Sync Now" reads every record in the configured history window (7 days by default; configurable up to all records) for the selected categories (not the dashboard's 20-sample preview), uploads in bounded batches over HTTPS with normal certificate validation and no redirects, and reports acknowledged counts, partial failures, truncation, and cancellation honestly. Retrying is safe: the receiver stores each record once.
- **Automatic background sync** — after you explicitly turn it on (Settings), VitalRoute observes the selected categories with HealthKit observers and background delivery (the app carries the `com.apple.developer.healthkit.background-delivery` entitlement, which iOS 15 and later require for `enableBackgroundDelivery`), captures additions **and deletions** incrementally through per-category anchored checkpoints, and delivers them from a durable outbox that survives network failure, suspension, and relaunch. Each HealthKit notification is answered once the captured changes are durable on disk, not when the network accepts them. Deletions propagate to tombstones on the receiver so replayed additions can never resurrect deleted samples. iOS throttles background delivery — it is never guaranteed immediate, and stops until the next launch after a force-quit; opening the app catches up right away.
- **Reference receiver** — `server/` contains a dependency-free Python receiver with Bearer-token auth, strict validation, transactional SQLite persistence, idempotent ingestion, and (contract v2) deletion events with tombstones. See `server/README.md`, the contract in `server/API.md`, and the background-sync design in `docs/BACKGROUND-SYNC-DESIGN.md`.

Manual sync never runs on its own: saving configuration, opening the app, or refreshing the dashboard never uploads data. Automatic sync only works after an explicit opt-in, and only against a receiver that advertises deletion support (contract v2).

## Project structure

- `VitalRoute/App/` — app entry point, shared app state, and dependency wiring
- `VitalRoute/Features/` — Overview, Health Data, Destination, and Settings screens
- `VitalRoute/Health/` — HealthKit service boundary, record mapping, and paged export queries
- `VitalRoute/Models/` — health records, metrics, payload, and receiver acknowledgments
- `VitalRoute/Networking/` — destination validation and the HTTPS transport client
- `VitalRoute/Persistence/` — Keychain-backed destination and credential stores, export selection
- `VitalRoute/Sync/` — the manual sync coordinator
- `VitalRouteTests/` — unit tests (mocked transport) plus an env-gated live receiver integration test
- `server/` — reference receiving server, its tests, contract, and synthetic-data tooling
- `.github/workflows/` — iOS + receiver CI and the additional OpenCode pull request review

The Xcode project is `VitalRoute.xcodeproj`. `project.yml` is its XcodeGen source specification. The shared Xcode scheme is named `VitalRoute`.

## Health data and privacy

VitalRoute requests read-only access, only to the categories you enable, and never writes to Apple Health. Apple does not tell apps whether read permission was granted, so an empty query is shown as "no samples returned" rather than as proof of denial or consent.

The app has no analytics, advertising, accounts, or vendor-cloud integration. Manual sync holds records in memory only for the operation you started. Automatic sync, once you turn it on, is the one feature that keeps health data on the device: captured changes wait in a data-protected outbox under Application Support until the receiver acknowledges them, alongside sync metadata (checkpoints, retry bookkeeping, and the identity of the destination the queue belongs to). Those files are protected with the device's own data protection, excluded from backups, and removed as soon as they are acknowledged. Turning automatic sync off keeps the queue so re-enabling resumes where it left off; changing the destination discards it, with a visible notice. The destination endpoint and its API key live in the Keychain. The destination URL must be HTTPS without credentials, query strings, or fragments; requests follow no redirects.

The reference receiver may hold real health records: treat its SQLite database, token, and certificates as sensitive, keep them out of the repository, and read `server/README.md` before deploying it.

## Build and test

Open `VitalRoute.xcodeproj` in Xcode and select an iOS Simulator. The app targets iOS 18.0 and uses bundle identifier `com.milim.vitalroute`.

To regenerate the Xcode project after changing `project.yml`, install XcodeGen and run:

```sh
xcodegen generate
```

To build and run the unit tests from the repository root:

```sh
xcodebuild -project VitalRoute.xcodeproj -scheme VitalRoute -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project VitalRoute.xcodeproj -scheme VitalRoute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
```

To run the receiver tests:

```sh
cd server
python3 -m unittest discover -s tests -v
```

### Live receiver integration (optional)

The XCTest target includes `ReceiverIntegrationTests`, which runs the production
HTTP client against a real receiver. It is skipped unless both environment
variables are set when running tests:

```sh
VITALROUTE_INTEGRATION_URL='https://localhost:8787/v1/records' \
VITALROUTE_INTEGRATION_TOKEN='<receiver token>' \
xcodebuild ... test
```

The URL must be HTTPS with a certificate the host trusts; production TLS
validation is never weakened for these tests. See `server/README.md` for
running the receiver, including with direct TLS.

## CI and review

The iOS workflow validates the repository and shared scheme, builds for the iOS Simulator, and runs XCTest; a separate workflow runs the receiver tests on Linux. OpenCode runs as an additional pull request review. To enable it, add these GitHub Actions repository secrets:

- `OPENCODE_GO_API_KEY`
- `OPENCODE_GH_PAT`

## Roadmap boundaries

Automatic background synchronization (observers, anchored incremental delivery of additions and deletions) is implemented; physical-device validation of HealthKit background delivery is still outstanding (see `docs/DEVICE-VALIDATION-CHECKLIST.md`; the design notes are in `docs/BACKGROUND-SYNC-DESIGN.md`). The constrained read-only query/MCP interface for downstream consumers remains future work.
