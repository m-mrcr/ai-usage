# Release process

Distribute directly with a Developer ID, outside the App Store. A normal release notarizes the app and DMG,
staples a ticket to both, and confirms the Gatekeeper verdict.

The canonical landing page is `https://moritouch.com/ai-usage`, and the Sparkle feed is
`https://moritouch.com/ai-usage/appcast.xml`; moritouch's Cloudflare delivery is the source of truth.
The public GitHub Release is used as distribution provenance for the source, the same DMG and SHA-256, a fixed tag, and immutable attestation.
The canonical download, appcast, and MIT License for general users are served from Cloudflare Workers Static Assets.

```bash
./scripts/bootstrap-release-tools.sh
./scripts/bootstrap-sparkle-tools.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --help
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh
```

`DEVELOPER_DIR` should point to a stable Xcode's `Contents/Developer`. For a normal notarized release,
preflight rejects a beta distribution where the effective Xcode.app has a `BetaVersion.plist`.
Even if `xcode-select` points to a beta, this environment variable verifies the effective path of `xcrun`/`xcodebuild`,
and the same Developer directory, Xcode.app, and release channel are saved to the release record.

The canonical artifact is `dist/AIUsage-<version>.dmg`, and its public hash is the same-named `.sha256`.
The DMG contains `AI Usage.app` and a symlink to `/Applications`; opening it in Finder shows
the icon layout, fixed positions, a drag arrow, and a bilingual first-launch guide.
If an artifact for the same version already exists, the script stops instead of overwriting it, so bump the version/build or
move the existing artifact somewhere safe. Release and fixed-toolchain preparation are serialized with a shared lock, and
it will not start if another process is running. The DMG is built in a run-specific working path, and only placed
into `dist/` after the layout, signing, notarization, Gatekeeper verdict, and bundled app have all been verified.

## One-time setup

The Team ID for the Apple Developer team used for distribution is `WTKUV8PPM7`. Do not put private keys, app-specific
passwords, or notarization credentials in the repository, chat, or CI logs.

### 1. Create a Developer ID Application certificate

Creating a new local Developer ID certificate can normally only be done by the Account Holder.
If using an Admin, don't confuse this with a setup where Apple has explicitly granted
cloud-managed Developer ID certificate access.

Create it from Xcode > Settings > Accounts > the distribution Apple Developer team > Manage Certificates >
the `+` in the bottom left > **Developer ID Application**.

If you need to receive a `.p12` from another signer, use a strong, temporary passphrase and
an approved secure channel. Hand it off outside the repository, and don't leave the transfer
file behind after importing it into Keychain. If a leak is suspected, stop using it and contact the Account Holder and Apple.

Verify it, including the Team ID:

```bash
security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "(WTKUV8PPM7)"
```

### 2. Issue an app-specific password

From appleid.apple.com > Sign-In and Security > App-Specific Passwords > generate new.
Give it a name that identifies its purpose, such as "AIUsage notarization". Do not use your
regular Apple ID password.

### 3. Store notarization credentials in Keychain

Writing `--password` on the command line can leave it in shell history or the process list.
Omit it and enter the app-specific password at `notarytool`'s secure interactive prompt instead.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool store-credentials "AIUsage" \
  --apple-id <Apple ID> \
  --team-id WTKUV8PPM7
```

The credentials are stored in Keychain, and the release script only references the profile name.
To use a different profile, specify `NOTARY_PROFILE`.

### 4. Prepare the fixed DMG toolchain

The DMG's Finder layout is generated with `dmgbuild`. Dependency versions and distribution file hashes are pinned
in `packaging/dmg/requirements.txt` and are not installed during a release. Run the following once, or after a lockfile update,
to prepare them into `build/release-tools/venv`, which is outside Git.

```bash
./scripts/bootstrap-release-tools.sh
```

The bootstrap verifies installed file hashes from the wheels, and saves the requirements hash, Python, and each package's measured version to
`build/release-tools/toolchain-stamp.txt`. The same content is re-verified during preflight and immediately before/after DMG generation.

### 5. Verify the fixed Sparkle toolchain and signing key

The official distribution's Sparkle `2.9.6` tools are verified against a fixed SHA-256 and prepared into
`build/sparkle-tools/2.9.6/bin/`, which is outside Git.

```bash
./scripts/bootstrap-sparkle-tools.sh
build/sparkle-tools/2.9.6/bin/generate_keys \
  --account jp.co.forestx.aiusage -p
```

The private key is kept only in the login Keychain under the account `jp.co.forestx.aiusage`. `-p` only
displays the public key of the existing key; verify that value matches `SUPublicEDKey` in `App/Info.plist`.
If no existing key is found, do not regenerate one on your own — check with whoever manages the signing key. Do not put the private key in the
repository, release assets, Cloudflare environment variables, or CI secrets.

### 6. Pass preflight

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
```

Preflight checks the stable Xcode/XcodeGen, the pinned version of `dmgbuild` and various distribution commands,
a Developer ID certificate matching the Team ID,
the notarization profile, private keys inside the repository, and collisions with same-version artifacts. It also requires that the
project root itself be a Git repository root, have a valid 40-character HEAD commit, and that the worktree be
clean, including no uncommitted or untracked files. Both a normal `--check` and a notarized release fail if Git information
cannot be retrieved or is dirty. Only an un-notarized local verification can proceed with a warning, but that artifact must not be distributed.
Because verifying the notarization profile involves a read request to Apple, check for both credential problems and
network failures.

If a leftover `build/release.lock` stops things, confirm that no release or bootstrap process is actually running.
Only once you've confirmed it's an empty directory left over from an abnormal exit should you clear it with `rmdir build/release.lock`.

This script does not automatically register App IDs, App Groups, or capabilities with Apple Developer. The
signer must confirm, for every release, that the required identifiers/capabilities match the Apple Developer configuration,
and that the exported app and Widget include the expected entitlements.
On a new Mac, signing in to Xcode and preparing local signing assets may also be needed separately.

## Build the distributable

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh
```

On success, it outputs:

- `dist/AIUsage-<version>.dmg`
- `dist/AIUsage-<version>.dmg.sha256`
- the release record's `provenance.json` and its SHA-256
- the notarization response, submission ID, and notarization log for both the app and DMG
- the source file manifest, Xcode/XcodeGen/SDK, certificate fingerprint, and build/export logs
- Git-commit-derived DMG configuration and background renderer snapshot, the fixed toolchain stamp, and measured versions
- the exported entitlements for the app/Widget, dSYMs and per-file manifests, and the xcarchive's `Info.plist`

The default save location for release records is `build/release-records/<run-id>/`. For production operation requiring
long-term retention, specify an access-controlled absolute path outside the repository.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RELEASE_RECORD_DIR=/absolute/private/release-records \
  ./scripts/release.sh
```

If notarization fails or is interrupted, check the `submissionId` and status in `provenance.json`.
Don't re-run the entire script and submit a duplicate while it's unclear whether Apple already accepted it.
Use the recorded ID to cross-check with `notarytool info` / `notarytool log` before deciding how to proceed.

Before distribution, the release operator should re-confirm that the final DMG's SHA-256, `spctl`, `stapler validate`, the bundle ID of the app inside the DMG,
the version/build, and the Team ID all match the release record. If there are multiple maintainers,
separate the signer and approver roles; for a solo operator, the same owner should record it as a separate verification step.
Also open the final DMG normally from Finder and visually confirm on screen that the icon layout, guide background, the positions of `AI Usage.app` and `Applications`,
the drag arrow, and the bilingual first-launch guide are all legible. Since Finder's "open folders in new tabs" setting and
showing hidden items change the surrounding margins/items, verify against the DMG's specified 800×500 content area as the baseline.
Even with hidden items shown, confirm that the background asset `.background.png` does not appear within this content area.

## Finalize artifacts with a public GitHub Release

Do not start release work unless the Git worktree, the public GitHub repository, the remote, and the default branch are all ready.
Bring this procedure and `.github/workflows/release.yml` into the default branch, and confirm the commit and CI on the remote before proceeding.
The repository name and default branch inside the workflow are fetched from the actual repository context, not hardcoded.

The source of truth for Apple signing and notarization is `./scripts/release.sh`, run on a managed Mac. Do not register the Developer ID private key, `.p8`,
app-specific password, or notary profile as GitHub Actions repository/environment secrets.
`release.yml` only accepts `workflow_dispatch`. Because GitHub only publishes a Draft Release to a token with push permission,
both jobs need a short-lived `GITHUB_TOKEN` with `contents: write`. The first job only inspects the
Draft with GET requests. The post-approval job also re-inspects without checking out the repository, and finally performs a single
PATCH that changes the Release's `draft` to `false`. The workflow does not create the Draft, upload assets, or perform Apple signing/notarization.

### Initial GitHub setup

1. Place an MIT `LICENSE` at the repository root, and confirm the history and distributed artifacts contain no secrets or personally identifying values.
2. Protect the default branch and `v*` tags with a ruleset or branch/tag protection. Don't reuse tags, and
   require CI, annotated tags, and Release approval.
3. Enable **release immutability** under Releases in Repository Settings. This only applies to Releases published
   after it's enabled, so set it before the first Publish.
4. Create a `release-publish` Environment and configure a required reviewer. For a solo operator where the same owner
   both triggers and approves, allow self-review. After confirming release immutability, check the workflow's `publish` checkbox and
   also approve in the Environment, making it two explicit confirmations.
   If another maintainer is added, enable "Prevent self-review" to separate the roles.
5. Do not create Apple-related secrets in Actions. Grant job-level `contents: write` only for viewing the Draft and Publishing,
   don't check out the repository, and don't use external Actions.
6. Enable Dependabot alerts, secret scanning, push protection, and Private Vulnerability Reporting.
7. If GitHub Pages was previously published, unpublish it from Settings > Pages, so the canonical distribution surfaces are only
   Cloudflare's landing page and appcast.

Because the standard `GITHUB_TOKEN` cannot be granted read access to repository administration, the workflow does not itself query the
release immutability setting. Instead of storing a broad, long-lived PAT in Actions, the owner confirms the setting at
launch time via the `publish` checkbox and at Environment approval time. The publish job always verifies that the published Release actually has
`immutable=true` and checks the attestation.

GitHub's immutable release prevents moving/deleting the tag and changing/deleting assets after Publish, and generates
attestation for the finalized tag, commit, and assets. This is provenance for the set of public artifacts on GitHub, and is not a
substitute for Apple build provenance on the managed Mac. A Draft can still be changed before Publish, so finish all asset inspection before Publishing.

### 1. Build canonical artifacts on the managed Mac

Commit/push the version change to the default branch, and confirm the working tree is clean and that commit is
in the default branch history.

```bash
set -euo pipefail
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin "$DEFAULT_BRANCH" --tags
test "$(git branch --show-current)" = "$DEFAULT_BRANCH"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$DEFAULT_BRANCH")"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RELEASE_RECORD_DIR=/absolute/private/release-records \
  ./scripts/release.sh
```

Keep the built `provenance.json` only in an access-controlled private location.

For the private `provenance.json` the script displays, confirm that `source.gitState` is `clean`, `source.gitCommit` matches
`git rev-parse HEAD`, and notarization status is `Accepted` for both the app and DMG. Do not upload personal absolute paths,
submission IDs, notarization responses/logs, dSYMs, entitlements, xcarchives, or the notary zip to GitHub.

### 2. Pin the tag and create the Draft

Do not move or reuse an existing tag. After creating and pushing an annotated tag against the artifact's source commit,
create the Draft limited to exactly two explicitly named Release assets. Do not use globs.

```bash
set -euo pipefail
VERSION=$(awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)
TAG="v$VERSION"
COMMIT=$(git rev-parse HEAD)
DMG="dist/AIUsage-$VERSION.dmg"
CHECKSUM="$DMG.sha256"
NOTES_FILE=/absolute/private/release-notes.md

test ! -e "dist/unnotarized/AIUsage-$VERSION-UNNOTARIZED.dmg"
(cd dist && shasum -a 256 -c "$(basename "$CHECKSUM")")
git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1 && exit 1
git tag -a "$TAG" "$COMMIT" -m "AI Usage $VERSION"
git push origin "$TAG"

gh release create "$TAG" \
  --draft \
  --verify-tag \
  --title "AI Usage $VERSION" \
  --notes-file "$NOTES_FILE" \
  "$DMG" \
  "$CHECKSUM"
```

The Draft's release notes are visible only to users with write access to the repository, but become fully public after Publish.
Before upload, confirm there are no personal paths like `/Users/...`, submission IDs, or contents of `provenance.json` or private logs.

### 3. Inspect the Draft, approve in Actions, and Publish

The workflow can only be triggered from the default branch. The first job checks that the tag is an annotated tag on the default branch history, that the tag
matches `MARKETING_VERSION`, that the Draft is not a prerelease, that there are exactly two assets — the DMG and `.sha256` —
and that the SHA-256 matches the GitHub-side digest. Even with `publish=true`, it does not proceed to the approval wait until these checks pass.

```bash
gh workflow run release.yml \
  --ref "$DEFAULT_BRANCH" \
  -f tag="$TAG" \
  -f publish=true
```

Once `Validate draft metadata and release assets` succeeds in the Actions view, it waits for approval on the `release-publish` Environment.
The approver should re-confirm:

- the tag's commit matches the commit in the private provenance
- CI for the target commit succeeded
- the release notes contain no internal information
- the attached assets are exactly `AIUsage-<version>.dmg` and the same-named `.sha256`
- the SHA-256 of the local DMG matches the one downloaded from the Draft
- release immutability is still enabled in Repository Settings

Select `release-publish` from **Review deployments** on the workflow run and press **Approve and deploy**.
The post-approval job re-checks the tag, Draft metadata, the asset ID/name/size/digest, and the SHA-256 of the downloaded DMG once more.
If anything changed since the first check, it stops without publishing; only if everything matches does it Publish the Draft.
After Publish, it also verifies `immutable=true`, the GitHub release attestation, and attestation for both assets.
Do not re-run a successful run; to redo it, start a new `workflow_dispatch`.

The public Release and assets can also be fetched from GitHub by general users. The app itself never references the GitHub API or Releases, and
holds no GitHub token. Sparkle's canonical update path remains the appcast on Cloudflare and the fixed-version asset.

```bash
gh release view "$TAG" --json tagName,isDraft,isImmutable,assets
gh release verify "$TAG"
gh release verify-asset "$TAG" "dist/AIUsage-${TAG#v}.dmg"
gh release verify-asset "$TAG" "dist/AIUsage-${TAG#v}.dmg.sha256"
```

Aside from the source archive GitHub automatically displays, the only manually attached assets should be the DMG and `.sha256`. After Publish,
do not `gh release upload --clobber`, delete/re-upload assets, or move the tag. If there's a mistake or incident, don't replace the existing
asset — announce that distribution is paused and publish a fixed version with a new version/build, tag, and Draft.

### 4. Generate the signed appcast and reflect it to Cloudflare

Do not put a Draft or a mutable asset into the feed. After Publish via the approved workflow, confirm `isDraft=false`,
`isImmutable=true`, and the attestation, then run the following in the AI Usage repository.

```bash
set -euo pipefail
PROFILE_REPO=/absolute/path/to/profile
PUBLIC_ASSETS_ROOT="$PROFILE_REPO/public/ai-usage/releases"

mkdir -p "$PUBLIC_ASSETS_ROOT"

./scripts/bootstrap-sparkle-tools.sh
./scripts/prepare-appcast.sh \
  --repository moritouch/ai-usage \
  --tag "$TAG" \
  --public-assets-root "$PUBLIC_ASSETS_ROOT" \
  --output "$PROFILE_REPO/public/ai-usage/appcast.xml"
```

`PROFILE_REPO` should be the absolute path to moritouch's Cloudflare profile repository.
`prepare-appcast.sh` cross-checks the published, non-prerelease, immutable public Release, the DMG/`.sha256` on both GitHub and the local `dist/`,
the notarization and Gatekeeper verdict, and the Sparkle key in Keychain against the public key in `App/Info.plist`.
It confirms the size is under 25 MiB, and atomically places the two assets into `public/ai-usage/releases/$TAG/`. An existing directory for the same tag is
reused only if the two files are byte-identical; otherwise the replacement is refused. It preserves existing appcast history, does not generate deltas, and
only atomically replaces the output once all verification succeeds. Do not manually edit the XML after output.

`prepare-appcast.sh` only updates the feed and public assets. The version pin held by the profile repository is managed separately, so
next, bump `NEXT_PUBLIC_AI_USAGE_LATEST_VERSION` in `wrangler.jsonc` to this version and regenerate the type definitions.
Skipping this causes the pre-deploy `verify:ai-usage-release` to fail with
`build environment NEXT_PUBLIC_AI_USAGE_LATEST_VERSION must match wrangler.jsonc`
(deploy never starts, so this does not affect the live feed). `cloudflare-env.d.ts` is generated, so do not edit it by hand.

```bash
cd "$PROFILE_REPO"
# After updating NEXT_PUBLIC_AI_USAGE_LATEST_VERSION in wrangler.jsonc to "${TAG#v}", run:
pnpm run cf-typegen
git diff -- wrangler.jsonc cloudflare-env.d.ts
```

The diff should be only one line in `wrangler.jsonc`, plus two lines — the type literal and generated hash — in `cloudflare-env.d.ts`.

Review that the changes on the profile-repository side contain no diffs other than the expected enclosure URL and signature for the tag and
the version pin above, then commit/push, confirm the target Cloudflare account is `moritouch`, and
deploy.

```bash
cd "$PROFILE_REPO"
pnpm run cloudflare:verify-account
NEXT_PUBLIC_AI_USAGE_LATEST_VERSION="${TAG#v}" \
  pnpm run deploy
```

After deploying, verify in production the landing page, the direct download links for the DMG and SHA-256, the Range response, and the feed's Content-Type and
signature. The download target must be a notarized DMG that is byte-identical to the verified immutable Release.

```bash
set -euo pipefail
SPARKLE_SIGN_UPDATE=/absolute/path/to/ai-usage/build/sparkle-tools/2.9.6/bin/sign_update
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT

curl --fail --show-error --silent --location \
  https://moritouch.com/ai-usage/appcast.xml \
  --output "$VERIFY_DIR/appcast.xml"
xmllint --noout "$VERIFY_DIR/appcast.xml"
"$SPARKLE_SIGN_UPDATE" \
  --account jp.co.forestx.aiusage \
  --verify "$VERIFY_DIR/appcast.xml"
curl --fail --show-error --silent --location \
  https://moritouch.com/ai-usage >/dev/null
curl --fail --show-error --silent --location \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg" \
  --output "$VERIFY_DIR/AIUsage-${TAG#v}.dmg"
curl --fail --show-error --silent --location \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg.sha256" \
  --output "$VERIFY_DIR/AIUsage-${TAG#v}.dmg.sha256"
(cd "$VERIFY_DIR" && shasum -a 256 -c "AIUsage-${TAG#v}.dmg.sha256")
cmp "dist/AIUsage-${TAG#v}.dmg" "$VERIFY_DIR/AIUsage-${TAG#v}.dmg"
curl --fail --show-error --silent \
  --range 0-1023 \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg" \
  --output "$VERIFY_DIR/range.bin"
```

If publishing the feed fails, don't change the assets on the immutable GitHub Release — revert to the last correctly signed appcast, then
redeploy to Cloudflare. Any issue requiring a new DMG should be fixed as a new version/build, tag, and Release.

References: [Manually running a workflow on GitHub](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow),
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases),
[`gh release create`](https://cli.github.com/manual/gh_release_create),
[Sparkle's publishing update guide](https://sparkle-project.org/documentation/publishing/).

## Release, update, and incident operations

`0.1.10` (build `12`) is the first public bootstrap release including Sparkle. For users before that, have them
get the latest notarized DMG from the landing page, quit the app, and manually replace the old version in `/Applications`.
There is no way to distribute an update via appcast alone to an old version that doesn't have Sparkle.
Before starting distribution of `0.1.10`, confirm that a correctly signed appcast — even with no items — returns HTTP 200 and XML at its fixed URL,
and that a manual check on `0.1.10` completes with "up to date" rather than an error.

The first real update E2E test goes from a verification environment with `0.1.10` installed to `0.1.11`. After bumping `0.1.11`'s
version/build, finalizing the notarized DMG as a public immutable GitHub Release, and reflecting the appcast to Cloudflare per the procedure above,
verify from Settings > "Check for Updates…" that detection, download, signature verification, replacement,
relaunch, version/build, and Widget re-registration all work. `0.1.10`'s own "up to date" result does not substitute for
a real update E2E test.

From then on, users either enable automatic checks from Settings or update via the manual check button. Before publishing, the release operator
should confirm the release record, notarization status, the final DMG's hash, the Gatekeeper verdict, the release notes, and the appcast enclosure and signature,
and record the target version/build and the approval result. If there are multiple maintainers, separate the signer and approver roles; for a
solo operator, the same owner should confirm it in two separate steps. Do not put an unapproved DMG, an un-notarized DMG, or a
Draft Release or GitHub Release asset URL into the appcast.

Keep the previous known-good DMG, `.sha256`, release record, and dSYM immutably in an access-controlled storage location.
Don't overwrite same-named files, and decide a retention period and support window. If an old version is left available for download,
clearly state its usability, including any known vulnerabilities.

The app name is always `AI Usage.app`; put any version/build used for archival purposes only in the DMG or ZIP filename.
Leaving an expanded `AI Usage-<version>-build<build>.app` around can cause an old version's Widget to get registered,
and the archival name may show up in the gallery name. Keep old versions as a notarized DMG or verified ZIP, and after an
update, confirm the Widget registration for `/Applications/AI Usage.app`, that the gallery name is "AI Usage", and
that a placed Widget shows usage data.

If a problem occurs, stop distributing the new version and assess the scope of impact and data compatibility. If a rollback is safe,
re-point users to the stored previous known-good version at its original hash, without re-compressing or re-signing it as a replacement.
Notify users of the affected version, workarounds, and recovery status, and re-release the fix as a new version/build.

If a leak of the Developer ID private key or notarization credentials is suspected, immediately stop releases and distribution.
Someone with access, including the Account Holder, should revoke the certificate on Apple Developer, and invalidate/rotate the app-specific password, Keychain profile,
CI, and any other related secrets. Investigate the signing history and published artifacts, and rebuild/re-notarize from a trusted source and a new
certificate. If abuse is possible, notify affected users.

## Un-notarized verification builds

Not a substitute for a normal release. It only runs when two explicit arguments are both given; the old
`SKIP_NOTARIZE` environment variable is rejected.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/release.sh --unnotarized --confirm-unnotarized
```

The output is isolated at `dist/unnotarized/AIUsage-<version>-UNNOTARIZED.dmg`.
It's a local verification artifact expected to be rejected by Gatekeeper — do not distribute or publish it to users, or
rename it to look like a canonical DMG.
