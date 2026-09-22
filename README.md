# VitalRoute

VitalRoute is a native iOS app for routing the Apple Health data a person chooses to an HTTPS endpoint they control. The repository is intended to hold the iOS client and a reference receiving server together.

## Project structure

- `VitalRoute/App/` — app entry point and shared app state
- `VitalRoute/Features/` — Overview, Health Data, Destination, and Settings screens
- `VitalRoute/Health/` — HealthKit service boundary and read queries
- `VitalRoute/Models/` — health records, metrics, and versioned JSON payload
- `VitalRoute/Networking/` — destination validation and future HTTPS transport contract
- `VitalRoute/Persistence/` — local destination endpoint preference
- `VitalRouteTests/` — unit tests for endpoint validation, metric mapping, and JSON serialization
- `server/` — reserved for the reference receiving server; not implemented yet
- `.github/workflows/` — iOS CI and the additional OpenCode pull request review

The Xcode project is `VitalRoute.xcodeproj`. `project.yml` is its XcodeGen source specification. The shared Xcode scheme is named `VitalRoute`.

## Health data and privacy

VitalRoute requests read-only access to seven Apple Health categories: steps, heart rate, resting heart rate, heart rate variability (SDNN), sleep, active energy, and workouts. It does not request write access.

After the user taps the access action, the app queries up to 20 recent samples per category from the preceding seven days and keeps returned records in memory. Apple Health does not tell apps whether read permission was declined, so an empty query is shown as “no samples returned,” not as proof that access was denied or granted.

The app has no analytics, advertising, account, or vendor-cloud integration. Health data is not sent anywhere in this initial build. A validated HTTPS endpoint can be saved on-device; API keys are not stored or sent. Keychain-backed credentials and HTTPS delivery must be implemented before sync is enabled.

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

## CI and review

The existing iOS workflow validates the repository and shared scheme, builds for the iOS Simulator, and runs XCTest when test targets exist. OpenCode runs as an additional pull request review. To enable it, add these GitHub Actions repository secrets:

- `OPENCODE_GO_API_KEY`
- `OPENCODE_GH_PAT`

The reference server, background HealthKit delivery, incremental cursors, retries, deletion handling, secure credential storage, and actual HTTPS synchronization are future work.
