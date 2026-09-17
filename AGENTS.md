# AI Usage

A macOS menu bar app and WidgetKit extension. `App/` is the UI, `Widget/` is the extension, `Shared/` is collection/storage/shared display, `Tests/` is verification.

- For development and PRs, read [CONTRIBUTING.md](CONTRIBUTING.md); for releases, read the relevant stage in [docs/RELEASE.md](docs/RELEASE.md). Do not replace Developer ID signing, notarization, DMG, and Sparkle distribution with TestFlight steps.
- Do not include auth values, personal paths, or raw logs/snapshots in public source, issues, or distributed artifacts. Use generic placeholders in examples. See [SECURITY.md](SECURITY.md) for details.
- Usage is expressed as "percent consumed". Keep the user's local device data separate from credentials, and pass only a minimal display snapshot to the Widget.
- When changing the UI, keep the Japanese and English strings in sync. `project.yml` is the source of truth for build settings, generated via XcodeGen.
- The official name is `AI Usage`. Do not append a version number to the expanded `.app` name. Preserve existing collaborators' authorship and Git history.
- Before repairing Keychain or auth, check the connection source and current settings. Do not make deleting credentials or re-authenticating the first step in diagnosis.
