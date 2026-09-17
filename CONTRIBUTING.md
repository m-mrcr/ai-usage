# Contributing to AI Usage

Thank you for helping improve AI Usage. Focused bug reports, documentation fixes, tests, and pull requests are welcome.

## Before opening an issue

- Use the existing bug-report template for reproducible app problems.
- Include the AI Usage version/build and macOS version.
- Describe the smallest set of steps that reproduces the problem.
- Do not attach OAuth tokens, Keychain contents, complete JSONL logs, snapshots, raw debug logs, or unredacted personal paths.
- Report vulnerabilities privately through [GitHub Private Vulnerability Reporting](https://github.com/moritouch/ai-usage/security/advisories/new), following [SECURITY.md](SECURITY.md).

## Development setup

The project requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
```

The checked-in configuration uses the maintainer's Developer Team, bundle identifiers, and App Group. You can run the test suite without those signing assets:

```bash
xcodebuild \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -configuration Debug \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  test
```

To launch your own local build, configure your Developer Team, bundle identifiers, and App Group consistently in `project.yml`, `App/AIUsage.entitlements`, `Widget/AIUsageWidget.entitlements`, and `Shared/SnapshotStore.swift`, then regenerate the Xcode project.

## Pull requests

Keep each pull request narrow and explain the user-visible behavior it changes. Before submitting:

1. Run `xcodegen generate` and review any generated `AIUsage.xcodeproj` changes.
2. Run the unsigned test command above.
3. Run `bash scripts/check-localizations.sh`.
4. Keep Japanese and English strings in sync.
5. Add or update tests for collector, parsing, credential, and formatting changes.
6. Check both the menu bar app and widget when changing shared models or display behavior.
7. Do not include personal data, credentials, signing material, notarization credentials, or raw provider logs.

Release signing, notarization, immutable GitHub Releases, and production appcast deployment remain maintainer operations. Do not include release credentials or generated release artifacts in a pull request.

## Design and behavior

- Display usage consistently as the percentage **used**.
- Preserve reset times and give shorter usage windows appropriate visual priority.
- Treat provider formats and the Claude OAuth usage endpoint as changeable inputs; validate data and fail safely.
- Do not broaden local-file, Keychain, network, or snapshot access without documenting the privacy impact.
- Keep the widget sandboxed and limited to the minimal shared display snapshot.

## License

By contributing, you agree that your contribution will be licensed under the repository's [MIT License](LICENSE).
