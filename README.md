# VitalRoute

VitalRoute is a native iOS app for routing the Apple Health data a person chooses to an endpoint they control. This repository will hold the iOS client and a reference receiving server together.

The repository is at its bootstrap stage: the Xcode project and reference server have not been added yet.

## Planned layout

- `VitalRoute/` — iOS app source
- `VitalRouteTests/` — XCTest targets
- `server/` — reference receiving server
- `.github/workflows/` — build validation and the OpenCode pull request review

## CI and review

The iOS workflow checks the repository and Xcode project, builds for the iOS Simulator, and runs XCTest targets when they exist. Until an Xcode project is added, it reports that build and test steps are not applicable yet.

OpenCode runs as an additional pull request review. To enable it, add these GitHub Actions repository secrets:

- `OPENCODE_GO_API_KEY`
- `OPENCODE_GH_PAT`

## Getting started

When the Xcode project is added, open `VitalRoute.xcodeproj` in Xcode and select an iOS Simulator or device. The reference server will live under `server/` when it is introduced.