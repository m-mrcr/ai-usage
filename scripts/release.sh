#!/bin/bash
# Distribution build: archive -> Developer ID signing -> DMG -> notarization -> stapling.
#
#   ./scripts/release.sh --check
#   ./scripts/release.sh
#   ./scripts/release.sh --unnotarized --confirm-unnotarized
#
# Unnotarized artifacts require explicit confirmation and are written to a separate location/name from regular distribution artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT_NAME="AIUsage"          # Project / scheme / archive name
APP_NAME="AI Usage"             # .app name of the artifact
APP_BUNDLE_ID="jp.co.forestx.aiusage"
WIDGET_BUNDLE_ID="jp.co.forestx.aiusage.widget"
DMG_NAME="AIUsage"              # Distribution file name (no spaces)
VOLUME_NAME="AI Usage"
TEAM_ID="WTKUV8PPM7"
NOTARY_PROFILE="${NOTARY_PROFILE:-AIUsage}"
SPARKLE_VERSION="2.9.6"
SPARKLE_FEED_URL="https://moritouch.com/ai-usage/appcast.xml"
SPARKLE_PUBLIC_KEY="rUEpVqbT7U1FSjjuxv3WyP4Fqd1WFOqk/71V71fKKs0="
PACKAGE_RESOLVED="$ROOT/AIUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SOURCE_PACKAGES_DIR="$ROOT/build/SourcePackages"
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/$PROJECT_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_SETTINGS="$ROOT/packaging/dmg/settings.py"
DMG_REQUIREMENTS="$ROOT/packaging/dmg/requirements.txt"
DMG_BACKGROUND_RENDERER="$ROOT/scripts/make-dmg-background.swift"
DMGBUILD_PYTHON="${DMGBUILD_PYTHON:-$ROOT/build/release-tools/venv/bin/python}"
DMGBUILD_STAMP="$ROOT/build/release-tools/toolchain-stamp.txt"
EXPECTED_DMGBUILD_VERSION="1.6.7"
EXPECTED_DS_STORE_VERSION="1.3.3"
EXPECTED_MAC_ALIAS_VERSION="2.2.3"
RECORD_ROOT="${RELEASE_RECORD_DIR:-$ROOT/build/release-records}"
RELEASE_LOCK_DIR="$ROOT/build/release.lock"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
fail()  { printf '\033[31m%s\033[0m\n' "$1" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/release.sh --check
      Check the tools, certificates, and credentials required for notarized direct distribution (no changes made).

  ./scripts/release.sh
      Run Developer ID signing, app/DMG notarization, stapling, and final verification.

  ./scripts/release.sh --unnotarized --confirm-unnotarized
      Explicitly skip notarization. The artifact is isolated to dist/unnotarized/
      as *-UNNOTARIZED.dmg and must not be used for regular distribution.

  ./scripts/release.sh --help
      Show this help.

Unknown options are rejected. The legacy SKIP_NOTARIZE environment variable is rejected.
USAGE
}

MODE="release"
UNNOTARIZED=0
case "$#:$*" in
  "0:")
    ;;
  "1:--check")
    MODE="check"
    ;;
  "1:--help"|"1:-h")
    usage
    exit 0
    ;;
  "2:--unnotarized --confirm-unnotarized")
    UNNOTARIZED=1
    ;;
  *)
    fail "Unknown or incomplete arguments."
    usage >&2
    exit 2
    ;;
esac

if [ -n "${SKIP_NOTARIZE+x}" ]; then
  fail "SKIP_NOTARIZE has been removed for safety reasons."
  fail "Pass --unnotarized --confirm-unnotarized explicitly only when it is actually needed."
  exit 2
fi

VERSION=$(/usr/bin/awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)
BUILD_NUMBER=$(/usr/bin/awk '$1 == "CURRENT_PROJECT_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z]+)*([-][0-9A-Za-z.-]+)?$ ]]; then
  fail "MARKETING_VERSION in project.yml is invalid: ${VERSION:-<empty>}"
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  fail "CURRENT_PROJECT_VERSION in project.yml is invalid: ${BUILD_NUMBER:-<empty>}"
  exit 1
fi

if [ "$UNNOTARIZED" -eq 1 ]; then
  RELEASE_MODE="unnotarized"
  FINAL_DMG="$ROOT/dist/unnotarized/$DMG_NAME-$VERSION-UNNOTARIZED.dmg"
else
  RELEASE_MODE="notarized"
  FINAL_DMG="$ROOT/dist/$DMG_NAME-$VERSION.dmg"
fi
FINAL_DMG_HASH_FILE="$FINAL_DMG.sha256"
DMG_HASH_FILE="$FINAL_DMG_HASH_FILE"

# ---------- Signing / preflight checks ----------
signing_identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -v team="($TEAM_ID)" \
        'index($0, "Developer ID Application") && index($0, team) && !found { print $2; found=1 }'
}

signing_identity_lines() {
  security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -v team="($TEAM_ID)" \
        'index($0, "Developer ID Application") && index($0, team)'
}

have_signing_id() {
  [ -n "$(signing_identity_hash)" ]
}

have_notary_profile() {
  xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null 2>&1
}

find_repository_secret() {
  find "$ROOT" \
    \( -path "$ROOT/.git" -o -path "$ROOT/build" -o -path "$ROOT/dist" \
       -o -path "$ROOT/DerivedData" -o -path '*/xcuserdata' \) -prune -o \
    -type f \( -name '*.p8' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' \) \
    -print -quit
}

EXPECTED_GIT_COMMIT=""
GIT_SOURCE_COMMIT=""
GIT_SOURCE_STATE="unavailable"
GIT_SOURCE_ERROR=""
EXPECTED_DEVELOPER_DIR=""
EFFECTIVE_DEVELOPER_DIR=""
EFFECTIVE_XCODE_APP=""
EFFECTIVE_XCODEBUILD_PATH=""
XCODE_RELEASE_CHANNEL="unknown"
XCODE_TOOLCHAIN_ERROR=""
DEVELOPER_DIRECTORY_SOURCE="xcode-select"

inspect_git_source() {
  local git_root
  local git_root_physical
  local root_physical
  local status_output

  GIT_SOURCE_COMMIT=""
  GIT_SOURCE_STATE="unavailable"
  GIT_SOURCE_ERROR=""

  if ! command -v git >/dev/null 2>&1; then
    GIT_SOURCE_ERROR="git command not found"
    return 1
  fi
  if [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || printf 'false')" != "true" ]; then
    GIT_SOURCE_ERROR="project root is not a Git worktree"
    return 1
  fi
  if ! git_root=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null); then
    GIT_SOURCE_ERROR="cannot get the Git repository root"
    return 1
  fi
  if ! git_root_physical=$(cd "$git_root" 2>/dev/null && pwd -P); then
    GIT_SOURCE_ERROR="cannot resolve the Git repository root"
    return 1
  fi
  root_physical=$(cd "$ROOT" && pwd -P)
  if [ "$git_root_physical" != "$root_physical" ]; then
    GIT_SOURCE_ERROR="project root and Git repository root do not match"
    return 1
  fi
  if ! GIT_SOURCE_COMMIT=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
    GIT_SOURCE_COMMIT=""
    GIT_SOURCE_ERROR="no valid HEAD commit"
    return 1
  fi
  if [[ ! "$GIT_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    GIT_SOURCE_ERROR="HEAD commit ID is not a GitHub-compatible 40-digit SHA"
    return 1
  fi
  if ! status_output=$(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null); then
    GIT_SOURCE_ERROR="cannot get the Git worktree status"
    return 1
  fi
  if [ -n "$status_output" ]; then
    GIT_SOURCE_STATE="dirty"
    GIT_SOURCE_ERROR="Git worktree has uncommitted or untracked changes"
    return 1
  fi

  GIT_SOURCE_STATE="clean"
  return 0
}

inspect_xcode_toolchain() {
  local developer_dir
  local xcodebuild_path

  EFFECTIVE_DEVELOPER_DIR=""
  EFFECTIVE_XCODE_APP=""
  EFFECTIVE_XCODEBUILD_PATH=""
  XCODE_RELEASE_CHANNEL="unknown"
  XCODE_TOOLCHAIN_ERROR=""
  DEVELOPER_DIRECTORY_SOURCE="xcode-select"

  if [ -n "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIRECTORY_SOURCE="DEVELOPER_DIR"
  fi
  if ! xcodebuild_path=$(xcrun --find xcodebuild 2>/dev/null); then
    XCODE_TOOLCHAIN_ERROR="cannot resolve the effective Xcode's xcodebuild"
    return 1
  fi
  case "$xcodebuild_path" in
    */Contents/Developer/usr/bin/xcodebuild)
      developer_dir=${xcodebuild_path%/usr/bin/xcodebuild}
      ;;
    *)
      XCODE_TOOLCHAIN_ERROR="xcodebuild is not inside Xcode.app: $xcodebuild_path"
      return 1
      ;;
  esac
  if ! EFFECTIVE_DEVELOPER_DIR=$(cd "$developer_dir" 2>/dev/null && pwd -P); then
    XCODE_TOOLCHAIN_ERROR="cannot resolve the effective Developer directory: $developer_dir"
    return 1
  fi
  EFFECTIVE_XCODE_APP=${EFFECTIVE_DEVELOPER_DIR%/Contents/Developer}
  EFFECTIVE_XCODEBUILD_PATH="$EFFECTIVE_DEVELOPER_DIR/usr/bin/xcodebuild"
  if [ ! -f "$EFFECTIVE_XCODE_APP/Contents/Info.plist" ]; then
    XCODE_TOOLCHAIN_ERROR="effective Xcode.app's Info.plist is missing: $EFFECTIVE_XCODE_APP"
    return 1
  fi
  if [ -f "$EFFECTIVE_XCODE_APP/Contents/Resources/BetaVersion.plist" ]; then
    XCODE_RELEASE_CHANNEL="beta"
  else
    XCODE_RELEASE_CHANNEL="stable"
  fi
  return 0
}

check_git_source_checkpoint() {
  local checkpoint=$1
  local checkpoint_error=""

  if inspect_git_source; then
    if [ -z "$EXPECTED_GIT_COMMIT" ]; then
      checkpoint_error="no source commit recorded at preflight"
    elif [ "$GIT_SOURCE_COMMIT" != "$EXPECTED_GIT_COMMIT" ]; then
      checkpoint_error="HEAD has changed since the preflight commit"
    else
      return 0
    fi
  else
    checkpoint_error=$GIT_SOURCE_ERROR
  fi

  if [ "$UNNOTARIZED" -eq 1 ]; then
    warn "  [--] Git source check at $checkpoint: $checkpoint_error"
    return 0
  fi
  fail "Git source check at $checkpoint failed: $checkpoint_error"
  return 1
}

ACTUAL_RELEASE_PYTHON_VERSION=""
ACTUAL_DMGBUILD_VERSION=""
ACTUAL_DS_STORE_VERSION=""
ACTUAL_MAC_ALIAS_VERSION=""
RELEASE_TOOLS_ERROR=""

inspect_release_tools() {
  local details
  local requirements_sha256
  local expected_stamp
  local actual_stamp

  ACTUAL_RELEASE_PYTHON_VERSION=""
  ACTUAL_DMGBUILD_VERSION=""
  ACTUAL_DS_STORE_VERSION=""
  ACTUAL_MAC_ALIAS_VERSION=""
  RELEASE_TOOLS_ERROR=""

  if [ ! -x "$DMGBUILD_PYTHON" ]; then
    RELEASE_TOOLS_ERROR="pinned Python environment is missing: $DMGBUILD_PYTHON"
    return 1
  fi
  if [ ! -f "$DMGBUILD_STAMP" ]; then
    RELEASE_TOOLS_ERROR="release tool stamp is missing: $DMGBUILD_STAMP"
    return 1
  fi

  if ! details=$("$DMGBUILD_PYTHON" - \
      "$EXPECTED_DMGBUILD_VERSION" \
      "$EXPECTED_DS_STORE_VERSION" \
      "$EXPECTED_MAC_ALIAS_VERSION" <<'PY'
from importlib.metadata import distribution, version
import base64
import hashlib
import platform
import sys

expected = {
    "dmgbuild": sys.argv[1],
    "ds-store": sys.argv[2],
    "mac-alias": sys.argv[3],
}
actual = {name: version(name) for name in expected}
if actual != expected:
    raise SystemExit(f"release tool versions do not match: {actual}")

for name in expected:
    package = distribution(name)
    for entry in package.files or ():
        if entry.hash is None:
            continue
        path = package.locate_file(entry)
        digest = hashlib.new(entry.hash.mode, path.read_bytes()).digest()
        encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
        if encoded != entry.hash.value:
            raise SystemExit(f"release tool integrity check failed: {name}: {entry}")

print("\t".join((
    platform.python_version(),
    actual["dmgbuild"],
    actual["ds-store"],
    actual["mac-alias"],
)))
PY
  ); then
    RELEASE_TOOLS_ERROR="release tool version or installed file integrity does not match"
    return 1
  fi

  IFS=$'\t' read -r \
    ACTUAL_RELEASE_PYTHON_VERSION \
    ACTUAL_DMGBUILD_VERSION \
    ACTUAL_DS_STORE_VERSION \
    ACTUAL_MAC_ALIAS_VERSION <<<"$details"
  if [ -z "$ACTUAL_RELEASE_PYTHON_VERSION" ] \
     || [ -z "$ACTUAL_DMGBUILD_VERSION" ] \
     || [ -z "$ACTUAL_DS_STORE_VERSION" ] \
     || [ -z "$ACTUAL_MAC_ALIAS_VERSION" ]; then
    RELEASE_TOOLS_ERROR="cannot get the actual release tool versions"
    return 1
  fi

  requirements_sha256=$(shasum -a 256 "$DMG_REQUIREMENTS" | /usr/bin/awk '{print $1}')
  expected_stamp=$(printf '%s\n' \
    'schemaVersion=1' \
    "requirementsSha256=$requirements_sha256" \
    "pythonVersion=$ACTUAL_RELEASE_PYTHON_VERSION" \
    "dmgbuildVersion=$ACTUAL_DMGBUILD_VERSION" \
    "dsStoreVersion=$ACTUAL_DS_STORE_VERSION" \
    "macAliasVersion=$ACTUAL_MAC_ALIAS_VERSION")
  actual_stamp=$(cat "$DMGBUILD_STAMP")
  if [ "$actual_stamp" != "$expected_stamp" ]; then
    RELEASE_TOOLS_ERROR="release tool stamp does not match the current requirements and installed environment"
    return 1
  fi
  return 0
}

preflight() {
  local ready=0
  local tool
  local secret_path
  local required_tools=(
    /usr/libexec/PlistBuddy awk basename cat chmod codesign cp date dirname ditto diskutil find git hdiutil ln
    jq mkdir mktemp mv otool plutil readlink rm rmdir security sed shasum sips sleep sort spctl tail tr
    xcode-select xcodebuild xcodegen xcrun
  )

  echo "== Requirements for distribution =="

  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "  [--] required command not found: $tool"
      ready=1
    fi
  done
  if [ "$ready" -eq 0 ]; then
    green "  [ok] required commands"
  fi

  if [ ! -f "$DMG_SETTINGS" ] || [ ! -f "$DMG_REQUIREMENTS" ] \
     || [ ! -f "$DMG_BACKGROUND_RENDERER" ]; then
    fail "  [--] DMG layout settings or background renderer not found"
    ready=1
  elif inspect_release_tools; then
    green "  [ok] dmgbuild $ACTUAL_DMGBUILD_VERSION / ds-store $ACTUAL_DS_STORE_VERSION / mac-alias $ACTUAL_MAC_ALIAS_VERSION"
  else
    fail "  [--] cannot verify the pinned environment for dmgbuild $EXPECTED_DMGBUILD_VERSION"
    fail "       $RELEASE_TOOLS_ERROR"
    echo "       Run ./scripts/bootstrap-release-tools.sh first."
    ready=1
  fi

  if inspect_git_source; then
    EXPECTED_GIT_COMMIT=$GIT_SOURCE_COMMIT
    green "  [ok] Git source: clean HEAD $EXPECTED_GIT_COMMIT"
  elif [ "$UNNOTARIZED" -eq 1 ]; then
    EXPECTED_GIT_COMMIT=$GIT_SOURCE_COMMIT
    warn "  [--] Git source: ${GIT_SOURCE_ERROR} (continuing with local verification only, unnotarized)"
  else
    EXPECTED_GIT_COMMIT=""
    fail "  [--] Git source: $GIT_SOURCE_ERROR"
    fail "       A regular release can only be created from a clean HEAD in the Git repository."
    ready=1
  fi

  if xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    green "  [ok] notarytool / stapler"
  elif [ "$UNNOTARIZED" -eq 0 ]; then
    fail "  [--] notarytool or stapler not found"
    ready=1
  else
    warn "  [--] notarytool / stapler missing (unused in an explicit unnotarized build)"
  fi

  if have_signing_id; then
    green "  [ok] Developer ID Application certificate for Team $TEAM_ID"
    signing_identity_lines | sed 's/^/       /'
  else
    fail "  [--] no Developer ID Application certificate for Team $TEAM_ID"
    echo "       Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    ready=1
  fi

  if [ "$UNNOTARIZED" -eq 0 ]; then
    if have_notary_profile; then
      green "  [ok] notarization credentials (profile: ${NOTARY_PROFILE})"
    else
      fail "  [--] cannot verify notarization credentials (check credentials or network)"
      printf '       xcrun notarytool store-credentials "%s" \\\n' "$NOTARY_PROFILE"
      echo "         --apple-id <Apple ID> --team-id $TEAM_ID"
      echo "       Enter the password at the secure interactive prompt."
      ready=1
    fi
  else
    warn "  [--] notarization is explicitly skipped in this mode"
  fi

  if inspect_xcode_toolchain && xcodebuild -version >/dev/null 2>&1; then
    EXPECTED_DEVELOPER_DIR=$EFFECTIVE_DEVELOPER_DIR
    green "  [ok] Xcode: $(xcodebuild -version | tr '\n' ' ')"
    echo "       Effective developer directory: $EFFECTIVE_DEVELOPER_DIR ($DEVELOPER_DIRECTORY_SOURCE)"
    echo "       XcodeGen: $(xcodegen --version | tr '\n' ' ')"
    if [ "$XCODE_RELEASE_CHANNEL" = "stable" ]; then
      green "  [ok] stable Xcode distribution"
    elif [ "$UNNOTARIZED" -eq 1 ]; then
      warn "  [--] using a beta Xcode (continuing with local verification only, unnotarized)"
    else
      fail "  [--] a beta Xcode cannot be used for a regular release: $EFFECTIVE_XCODE_APP"
      fail "       Re-run with a stable Xcode set explicitly via DEVELOPER_DIR."
      ready=1
    fi
  else
    fail "  [--] cannot verify Xcode: ${XCODE_TOOLCHAIN_ERROR:-xcodebuild execution failed}"
    ready=1
  fi

  secret_path=$(find_repository_secret)
  if [ -n "$secret_path" ]; then
    fail "  [--] found a private key/certificate archive inside the repository: $secret_path"
    fail "       Move it outside the repository before running this."
    ready=1
  else
    green "  [ok] no private key files inside the repository"
  fi

  if bash "$ROOT/scripts/check-localizations.sh"; then
    green "  [ok] Japanese/English localization catalog"
  else
    fail "  [--] Japanese/English localization catalog verification failed"
    ready=1
  fi

  if [ ! -f "$PACKAGE_RESOLVED" ]; then
    fail "  [--] Swift package lock not found: $PACKAGE_RESOLVED"
    ready=1
  elif jq -e \
      --arg version "$SPARKLE_VERSION" \
      '(.version == 3)
       and ([.pins[]
             | select(.identity == "sparkle"
                      and .location == "https://github.com/sparkle-project/Sparkle"
                      and .state.version == $version
                      and .state.revision == "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a")]
            | length == 1)' \
      "$PACKAGE_RESOLVED" >/dev/null; then
    green "  [ok] package lock for Sparkle $SPARKLE_VERSION"
  else
    fail "  [--] Sparkle package lock does not match the pinned version/revision"
    ready=1
  fi

  if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
    fail "  [--] output for this same version already exists: $FINAL_DMG"
    fail "       It will not be overwritten. Bump the version or move the existing artifact aside."
    ready=1
  else
    green "  [ok] no existing output for this version"
  fi

  echo
  if [ "$ready" -eq 0 ]; then
    if [ "$UNNOTARIZED" -eq 1 ]; then
      warn "Prerequisites for an unnotarized build are in place. It must not be used for regular distribution."
    else
      green "Everything is in place. ./scripts/release.sh will produce a notarized distribution artifact."
    fi
  else
    warn "The release process will not start until the issues above are resolved."
  fi
  return "$ready"
}

if [ "$MODE" = "check" ]; then
  if preflight; then
    exit 0
  else
    exit 1
  fi
fi

preflight || exit 1

# ---------- Audit records ----------
RUN_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ')-$VERSION-$BUILD_NUMBER-$RELEASE_MODE
RECORD_DIR="$RECORD_ROOT/$RUN_ID"
WORK_DIR="$BUILD_DIR/working/$RUN_ID"
if [ "$UNNOTARIZED" -eq 1 ]; then
  DMG="$WORK_DIR/$DMG_NAME-$VERSION-UNNOTARIZED.dmg"
else
  DMG="$WORK_DIR/$DMG_NAME-$VERSION.dmg"
fi
WORK_DMG_HASH_FILE="$DMG.sha256"
DMG_BACKGROUND="$WORK_DIR/dmg-background.png"
DMG_INPUT_DIR="$RECORD_DIR/dmg-inputs"
DMG_SETTINGS_SNAPSHOT="$DMG_INPUT_DIR/settings.py"
DMG_REQUIREMENTS_SNAPSHOT="$DMG_INPUT_DIR/requirements.txt"
DMG_BACKGROUND_RENDERER_SNAPSHOT="$DMG_INPUT_DIR/make-dmg-background.swift"
DMGBUILD_STAMP_SNAPSHOT="$DMG_INPUT_DIR/toolchain-stamp.txt"
PROVENANCE="$RECORD_DIR/provenance.json"
SOURCE_MANIFEST="$RECORD_DIR/source-sha256.txt"
SOURCE_MANIFEST_AFTER="$RECORD_DIR/source-sha256-after-build.txt"
SOURCE_MANIFEST_BEFORE_DMG="$RECORD_DIR/source-sha256-before-dmg.txt"
SOURCE_MANIFEST_AFTER_DMG="$RECORD_DIR/source-sha256-after-dmg.txt"
DEBUG_SYMBOL_DIR="$RECORD_DIR/debug-symbols"
CURRENT_STEP="record-initialization"
MOUNT_DIR=""
MOUNTED=0
LOCK_HELD=0
RECORD_CREATED=0
ARTIFACTS_PUBLISHED=0

umask 077
mkdir -p "$ROOT/build" "$RECORD_ROOT"

receipt_has_key() {
  plutil -type "$1" "$PROVENANCE" >/dev/null 2>&1
}

receipt_set_string() {
  if receipt_has_key "$1"; then
    plutil -replace "$1" -string "$2" "$PROVENANCE"
  else
    plutil -insert "$1" -string "$2" "$PROVENANCE"
  fi
}

receipt_set_integer() {
  if receipt_has_key "$1"; then
    plutil -replace "$1" -integer "$2" "$PROVENANCE"
  else
    plutil -insert "$1" -integer "$2" "$PROVENANCE"
  fi
}

receipt_add_dictionary() {
  if ! receipt_has_key "$1"; then
    plutil -insert "$1" -dictionary "$PROVENANCE"
  fi
}

cleanup_mount() {
  local cleanup_status=0

  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    if diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 \
       || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
      MOUNTED=0
    else
      warn "could not auto-eject the DMG: $MOUNT_DIR"
      cleanup_status=1
    fi
  fi
  if [ "$MOUNTED" -eq 0 ] && [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    if ! rmdir "$MOUNT_DIR" >/dev/null 2>&1; then
      warn "could not remove the temporary mount directory: $MOUNT_DIR"
      cleanup_status=1
    fi
  fi
  return "$cleanup_status"
}

cleanup_on_exit() {
  local script_status=$?
  trap - EXIT
  set +e
  if ! cleanup_mount && [ "$script_status" -eq 0 ]; then
    script_status=1
  fi
  if [ "$ARTIFACTS_PUBLISHED" -eq 1 ] && [ "$CURRENT_STEP" != "complete" ]; then
    if [ -e "$FINAL_DMG" ] && ! rm "$FINAL_DMG"; then
      warn "could not remove the published DMG from the failed release: $FINAL_DMG"
      script_status=1
    fi
    if [ -e "$FINAL_DMG_HASH_FILE" ] && ! rm "$FINAL_DMG_HASH_FILE"; then
      warn "could not remove the published checksum from the failed release: $FINAL_DMG_HASH_FILE"
      script_status=1
    fi
    ARTIFACTS_PUBLISHED=0
  fi
  # Even if a Bash expansion error or similar causes the exit status to be passed as 0 by mistake,
  # a release that never reached the completion point must not be treated as a success.
  # A receipt for a run that ended midway must always be closed as failed.
  if [ "$RECORD_CREATED" -eq 1 ] && [ -f "$PROVENANCE" ] \
     && [ "$CURRENT_STEP" != "complete" ]; then
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
    receipt_set_string "state" "failed"
    receipt_add_dictionary "failure"
    receipt_set_string "failure.step" "$CURRENT_STEP"
    receipt_set_integer "failure.exitStatus" "$script_status"
    receipt_set_string "failure.recordedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    plutil -convert json -r "$PROVENANCE" >/dev/null 2>&1
    chmod 600 "$PROVENANCE"
    shasum -a 256 "$PROVENANCE" >"$PROVENANCE.sha256"
    chmod 600 "$PROVENANCE.sha256"
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    if rmdir "$RELEASE_LOCK_DIR" >/dev/null 2>&1; then
      LOCK_HELD=0
    else
      warn "could not release the release lock: $RELEASE_LOCK_DIR"
      if [ "$script_status" -eq 0 ]; then
        script_status=1
      fi
    fi
  fi
  exit "$script_status"
}
trap cleanup_on_exit EXIT

if ! mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
  fail "another release or release tool preparation is running: $RELEASE_LOCK_DIR"
  fail "Only rmdir the empty lock directory if no process is actually running and it was simply left behind."
  exit 1
fi
LOCK_HELD=1

# Re-check after acquiring the lock, in case another process published the same version first, after preflight.
if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
  fail "output for this same version already exists: $FINAL_DMG"
  exit 1
fi
if ! mkdir "$RECORD_DIR"; then
  fail "a release record with the same name already exists: $RECORD_DIR"
  exit 1
fi
RECORD_CREATED=1
mkdir -p "$WORK_DIR"

# macOS 27's plutil cannot insert directly into an empty JSON object, so the root is built as XML first
# and then converted to JSON. Subsequent inserts/replaces operate on non-empty JSON.
plutil -create xml1 "$PROVENANCE"
chmod 600 "$PROVENANCE"
receipt_set_integer "schemaVersion" 1
receipt_set_string "state" "prepared"
receipt_set_string "createdAt" "$RUN_TIMESTAMP"
receipt_add_dictionary "app"
receipt_set_string "app.name" "$APP_NAME"
receipt_set_string "app.bundleId" "$APP_BUNDLE_ID"
receipt_set_string "app.widgetBundleId" "$WIDGET_BUNDLE_ID"
receipt_set_string "app.teamId" "$TEAM_ID"
receipt_set_string "app.marketingVersion" "$VERSION"
receipt_set_string "app.buildNumber" "$BUILD_NUMBER"
receipt_add_dictionary "release"
receipt_set_string "release.mode" "$RELEASE_MODE"
receipt_set_string "release.outputPath" "$FINAL_DMG"
receipt_set_string "release.workingPath" "$DMG"
receipt_set_string "release.notaryProfile" "$NOTARY_PROFILE"
receipt_add_dictionary "source"
receipt_add_dictionary "toolchain"
receipt_add_dictionary "signing"
receipt_add_dictionary "update"
receipt_add_dictionary "artifacts"
receipt_add_dictionary "artifacts.dmgLayout"
receipt_add_dictionary "notarization"
receipt_add_dictionary "notarization.app"
receipt_add_dictionary "notarization.dmg"
receipt_set_string "notarization.app.status" "$([ "$UNNOTARIZED" -eq 1 ] && printf 'skipped-explicitly' || printf 'not-started')"
receipt_set_string "notarization.dmg.status" "$([ "$UNNOTARIZED" -eq 1 ] && printf 'skipped-explicitly' || printf 'not-started')"
plutil -convert json -r "$PROVENANCE"

if ! inspect_xcode_toolchain; then
  fail "cannot verify Xcode before creating the receipt: $XCODE_TOOLCHAIN_ERROR"
  exit 1
fi
if [ -z "$EXPECTED_DEVELOPER_DIR" ] || [ "$EFFECTIVE_DEVELOPER_DIR" != "$EXPECTED_DEVELOPER_DIR" ]; then
  fail "The effective Developer directory changed after preflight. Aborting the release."
  exit 1
fi
if [ "$UNNOTARIZED" -eq 0 ] && [ "$XCODE_RELEASE_CHANNEL" != "stable" ]; then
  fail "Detected a beta Xcode before creating the receipt. Aborting the release."
  exit 1
fi

XCODE_PRODUCT_VERSION=$(xcodebuild -version | /usr/bin/awk 'NR == 1 {print $2}')
XCODE_BUILD=$(xcodebuild -version | /usr/bin/awk 'NR == 2 {print $3}')
SDK_VERSION=$(xcodebuild -version -sdk macosx SDKVersion)
SDK_BUILD=$(xcodebuild -version -sdk macosx ProductBuildVersion)
XCODEGEN_VERSION=$(xcodegen --version | tr '\n' ' ')
SIGN_ID=$(signing_identity_hash)

receipt_set_string "toolchain.xcodeProductVersion" "$XCODE_PRODUCT_VERSION"
receipt_set_string "toolchain.xcodeBuild" "$XCODE_BUILD"
receipt_set_string "toolchain.sdkVersion" "$SDK_VERSION"
receipt_set_string "toolchain.sdkBuild" "$SDK_BUILD"
receipt_set_string "toolchain.developerDirectory" "$EFFECTIVE_DEVELOPER_DIR"
receipt_set_string "toolchain.developerDirectorySource" "$DEVELOPER_DIRECTORY_SOURCE"
receipt_set_string "toolchain.xcodeApplication" "$EFFECTIVE_XCODE_APP"
receipt_set_string "toolchain.xcodebuildPath" "$EFFECTIVE_XCODEBUILD_PATH"
receipt_set_string "toolchain.releaseChannel" "$XCODE_RELEASE_CHANNEL"
receipt_set_string "toolchain.xcodegen" "$XCODEGEN_VERSION"
receipt_set_string "signing.preflightDeveloperIdSha1" "$SIGN_ID"

if inspect_git_source; then
  if [ -n "$EXPECTED_GIT_COMMIT" ] && [ "$GIT_SOURCE_COMMIT" != "$EXPECTED_GIT_COMMIT" ]; then
    fail "HEAD changed before creating the receipt. Aborting the release."
    exit 1
  fi
  receipt_set_string "source.gitCommit" "$GIT_SOURCE_COMMIT"
  receipt_set_string "source.gitState" "clean"
else
  receipt_set_string "source.gitCommit" "${GIT_SOURCE_COMMIT:-unavailable}"
  receipt_set_string "source.gitState" "$GIT_SOURCE_STATE"
  if [ "$UNNOTARIZED" -eq 0 ]; then
    fail "Git source check before creating the receipt failed: $GIT_SOURCE_ERROR"
    exit 1
  fi
  warn "Git source for the unnotarized artifact is ${GIT_SOURCE_STATE}: $GIT_SOURCE_ERROR"
fi

run_logged() {
  local log_path=$1
  local command_status
  shift
  if "$@" >"$log_path" 2>&1; then
    tail -n 20 "$log_path" | sed 's/^/    /'
    return 0
  else
    command_status=$?
    tail -n 80 "$log_path" | sed 's/^/    /' >&2
    return "$command_status"
  fi
}

write_source_manifest() {
  local manifest_path=$1
  local source_file
  local file_hash
  local relative_path

  while IFS= read -r -d '' relative_path; do
    source_file="$ROOT/$relative_path"
    file_hash=$(shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')
    printf '%s  %s\n' "$file_hash" "$relative_path"
  done < <(git -C "$ROOT" ls-files -z) | LC_ALL=C sort >"$manifest_path"
  chmod 600 "$manifest_path"
  shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}'
}

write_tree_manifest() {
  local tree_root=$1
  local manifest_path=$2
  local source_file
  local file_hash
  local relative_path

  while IFS= read -r -d '' source_file; do
    file_hash=$(shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')
    relative_path=${source_file#"$tree_root/"}
    printf '%s  %s\n' "$file_hash" "$relative_path"
  done < <(find "$tree_root" -type f -print0) | LC_ALL=C sort >"$manifest_path"
  chmod 600 "$manifest_path"
  shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}'
}

source_manifest_hash_for() {
  local manifest_path=$1
  local relative_path=$2
  /usr/bin/awk -v path="$relative_path" '
    substr($0, 67) == path { value=substr($0, 1, 64); count++ }
    END {
      if (count == 1) print value
      else exit 1
    }
  ' "$manifest_path"
}

snapshot_dmg_input() {
  local source_path=$1
  local snapshot_path=$2
  local relative_path=${source_path#"$ROOT/"}
  local expected_hash
  local snapshot_hash

  expected_hash=$(source_manifest_hash_for "$SOURCE_MANIFEST_AFTER" "$relative_path") \
    || { fail "DMG input not found in source manifest: $relative_path"; return 1; }
  if [ "$UNNOTARIZED" -eq 0 ]; then
    git -C "$ROOT" show "$EXPECTED_GIT_COMMIT:$relative_path" >"$snapshot_path"
  else
    cp "$source_path" "$snapshot_path"
  fi
  snapshot_hash=$(shasum -a 256 "$snapshot_path" | /usr/bin/awk '{print $1}')
  [ "$snapshot_hash" = "$expected_hash" ] \
    || { fail "DMG input snapshot does not match the source at build time: $relative_path"; return 1; }
  chmod 600 "$snapshot_path"
}

snapshot_dmg_inputs() {
  mkdir "$DMG_INPUT_DIR"
  snapshot_dmg_input "$DMG_SETTINGS" "$DMG_SETTINGS_SNAPSHOT"
  snapshot_dmg_input "$DMG_REQUIREMENTS" "$DMG_REQUIREMENTS_SNAPSHOT"
  snapshot_dmg_input "$DMG_BACKGROUND_RENDERER" "$DMG_BACKGROUND_RENDERER_SNAPSHOT"
  cp "$DMGBUILD_STAMP" "$DMGBUILD_STAMP_SNAPSHOT"
  chmod 600 "$DMGBUILD_STAMP_SNAPSHOT"
}

plist_value() {
  plutil -extract "$1" raw "$2"
}

codesign_team_id() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" {value=$2} END {print value}'
}

codesign_cdhash() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk -F= '$1 == "CDHash" {value=$2} END {print value}'
}

codesign_has_hardened_runtime() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk 'index($0, "flags=") && index($0, "runtime") {found=1} END {exit found ? 0 : 1}'
}

entitlement_value() {
  local key_path=$1
  local plist_path=$2
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null
}

verify_exported_app() {
  local app_plist="$APP/Contents/Info.plist"
  local widget="$APP/Contents/PlugIns/AIUsageWidget.appex"
  local widget_plist="$widget/Contents/Info.plist"
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  local sparkle_plist="$sparkle/Versions/Current/Resources/Info.plist"
  local notices="$APP/Contents/Resources/Third-Party-Notices.txt"
  local app_entitlements="$RECORD_DIR/exported-app-entitlements.plist"
  local widget_entitlements="$RECORD_DIR/exported-widget-entitlements.plist"
  local app_entitlements_stderr="$RECORD_DIR/exported-app-entitlements.stderr.log"
  local widget_entitlements_stderr="$RECORD_DIR/exported-widget-entitlements.stderr.log"
  local app_cert_prefix="$RECORD_DIR/exported-app-signing-cert-"
  local widget_cert_prefix="$RECORD_DIR/exported-widget-signing-cert-"
  local app_cert_sha1
  local widget_cert_sha1
  local expected_app_group="$TEAM_ID.$APP_BUNDLE_ID"
  local actual

  [ -d "$APP" ] || { fail "exported app not found: $APP"; return 1; }
  [ -d "$widget" ] || { fail "widget extension not found: $widget"; return 1; }
  [ -d "$sparkle" ] || { fail "Sparkle.framework not found in the app"; return 1; }
  [ -f "$sparkle_plist" ] || { fail "Sparkle.framework's Info.plist not found"; return 1; }
  [ -s "$notices" ] || { fail "license/third-party notices not found in the app"; return 1; }
  [ "$(shasum -a 256 "$notices" | /usr/bin/awk '{print $1}')" \
    = "$(shasum -a 256 "$ROOT/Resources/Third-Party-Notices.txt" | /usr/bin/awk '{print $1}')" ] \
    || { fail "license/third-party notices in the app do not match the source"; return 1; }
  [ ! -e "$widget/Contents/Frameworks/Sparkle.framework" ] \
    || { fail "the widget must not include Sparkle.framework"; return 1; }

  local localized_bundle
  local language_code
  local strings_file
  for localized_bundle in "$APP" "$widget"; do
    for language_code in en ja; do
      strings_file="$localized_bundle/Contents/Resources/$language_code.lproj/Localizable.strings"
      [ -f "$strings_file" ] \
        || { fail "$language_code localization not found in $localized_bundle"; return 1; }
      plutil -lint "$strings_file" >/dev/null \
        || { fail "cannot verify $strings_file"; return 1; }
    done
  done

  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
  codesign --verify --strict --verbose=2 "$widget" 2>&1 | sed 's/^/    /'
  codesign --verify --deep --strict --verbose=2 "$sparkle" 2>&1 | sed 's/^/    /'

  codesign -d --extract-certificates="$app_cert_prefix" "$APP" >/dev/null 2>&1
  codesign -d --extract-certificates="$widget_cert_prefix" "$widget" >/dev/null 2>&1
  [ -f "${app_cert_prefix}0" ] || { fail "cannot extract the app's signing certificate"; return 1; }
  [ -f "${widget_cert_prefix}0" ] || { fail "cannot extract the widget's signing certificate"; return 1; }
  find "$RECORD_DIR" -maxdepth 1 -type f \
    \( -name 'exported-app-signing-cert-*' -o -name 'exported-widget-signing-cert-*' \) \
    -exec chmod 600 {} +
  app_cert_sha1=$(shasum -a 1 "${app_cert_prefix}0" | /usr/bin/awk '{print toupper($1)}')
  widget_cert_sha1=$(shasum -a 1 "${widget_cert_prefix}0" | /usr/bin/awk '{print toupper($1)}')
  signing_identity_lines | /usr/bin/awk -v hash="$app_cert_sha1" \
    '$2 == hash {found=1} END {exit found ? 0 : 1}' \
    || { fail "the app's actual signing certificate does not match an available identity for Team ${TEAM_ID}"; return 1; }
  [ "$widget_cert_sha1" = "$app_cert_sha1" ] \
    || { fail "the app's and widget's signing certificates do not match"; return 1; }
  receipt_set_string "signing.developerIdSha1" "$app_cert_sha1"
  receipt_set_string "signing.appLeafCertificatePath" "${app_cert_prefix}0"
  receipt_set_string "signing.widgetLeafCertificatePath" "${widget_cert_prefix}0"
  # The DMG is also signed with the same certificate Xcode actually used for the export.
  SIGN_ID="$app_cert_sha1"

  actual=$(codesign_team_id "$APP")
  [ "$actual" = "$TEAM_ID" ] || { fail "app Team ID mismatch: $actual"; return 1; }
  actual=$(codesign_team_id "$widget")
  [ "$actual" = "$TEAM_ID" ] || { fail "widget Team ID mismatch: $actual"; return 1; }

  actual=$(plist_value CFBundleIdentifier "$app_plist")
  [ "$actual" = "$APP_BUNDLE_ID" ] || { fail "app Bundle ID mismatch: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$widget_plist")
  [ "$actual" = "$WIDGET_BUNDLE_ID" ] || { fail "widget Bundle ID mismatch: $actual"; return 1; }

  actual=$(plist_value CFBundleShortVersionString "$app_plist")
  [ "$actual" = "$VERSION" ] || { fail "app version mismatch: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$app_plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "app build number mismatch: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$widget_plist")
  [ "$actual" = "$VERSION" ] || { fail "widget version mismatch: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$widget_plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "widget build number mismatch: $actual"; return 1; }

  actual=$(plist_value SUFeedURL "$app_plist")
  [ "$actual" = "$SPARKLE_FEED_URL" ] || { fail "Sparkle feed URL mismatch: $actual"; return 1; }
  actual=$(plist_value SUPublicEDKey "$app_plist")
  [ "$actual" = "$SPARKLE_PUBLIC_KEY" ] || { fail "Sparkle public key mismatch"; return 1; }
  actual=$(plist_value SUVerifyUpdateBeforeExtraction "$app_plist")
  [ "$actual" = "true" ] || { fail "pre-extraction verification of the update archive is not enabled"; return 1; }
  actual=$(plist_value SURequireSignedFeed "$app_plist")
  [ "$actual" = "true" ] || { fail "a signed appcast is not required"; return 1; }
  actual=$(plist_value SUScheduledCheckInterval "$app_plist")
  [ "$actual" = "86400" ] || { fail "unexpected update check interval: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$sparkle_plist")
  [ "$actual" = "$SPARKLE_VERSION" ] || { fail "Sparkle version mismatch: $actual"; return 1; }
  otool -L "$APP/Contents/MacOS/$APP_NAME" \
    | /usr/bin/awk 'index($1, "@rpath/Sparkle.framework/") {found=1} END {exit found ? 0 : 1}' \
    || { fail "the app executable does not reference the bundled Sparkle.framework"; return 1; }

  receipt_set_string "update.feedURL" "$SPARKLE_FEED_URL"
  receipt_set_string "update.publicEdKey" "$SPARKLE_PUBLIC_KEY"
  receipt_set_string "update.sparkleVersion" "$SPARKLE_VERSION"
  receipt_set_string "update.requiresSignedFeed" "true"
  receipt_set_string "update.verifiesBeforeExtraction" "true"

  codesign -d --entitlements - --xml "$APP" >"$app_entitlements" 2>"$app_entitlements_stderr"
  codesign -d --entitlements - --xml "$widget" >"$widget_entitlements" 2>"$widget_entitlements_stderr"
  chmod 600 "$app_entitlements" "$widget_entitlements" \
    "$app_entitlements_stderr" "$widget_entitlements_stderr"
  plutil -lint "$app_entitlements" >/dev/null
  plutil -lint "$widget_entitlements" >/dev/null

  if actual=$(entitlement_value "com.apple.security.app-sandbox" "$app_entitlements"); then
    [ "$actual" = "false" ] || { fail "the app, which should not be sandboxed, has the app-sandbox entitlement"; return 1; }
  fi
  actual=$(entitlement_value "com.apple.security.app-sandbox" "$widget_entitlements" || printf '')
  [ "$actual" = "true" ] || { fail "the widget is missing the app-sandbox entitlement"; return 1; }

  actual=$(entitlement_value "com.apple.security.application-groups:0" "$app_entitlements" || printf '')
  [ "$actual" = "$expected_app_group" ] || { fail "app App Group mismatch: $actual"; return 1; }
  actual=$(entitlement_value "com.apple.security.application-groups:0" "$widget_entitlements" || printf '')
  [ "$actual" = "$expected_app_group" ] || { fail "widget App Group mismatch: $actual"; return 1; }
  if entitlement_value "com.apple.security.application-groups:1" "$app_entitlements" >/dev/null \
     || entitlement_value "com.apple.security.application-groups:1" "$widget_entitlements" >/dev/null; then
    fail "found an unexpected additional App Group entitlement"
    return 1
  fi

  if actual=$(entitlement_value "com.apple.security.get-task-allow" "$app_entitlements"); then
    [ "$actual" = "false" ] || { fail "the app has the get-task-allow entitlement"; return 1; }
  fi
  if actual=$(entitlement_value "com.apple.security.get-task-allow" "$widget_entitlements"); then
    [ "$actual" = "false" ] || { fail "the widget has the get-task-allow entitlement"; return 1; }
  fi
  codesign_has_hardened_runtime "$APP" || { fail "the app does not have hardened runtime"; return 1; }
  codesign_has_hardened_runtime "$widget" || { fail "the widget does not have hardened runtime"; return 1; }

  receipt_set_string "artifacts.exportedAppEntitlementsPath" "$app_entitlements"
  receipt_set_string "artifacts.exportedAppEntitlementsSha256" \
    "$(shasum -a 256 "$app_entitlements" | /usr/bin/awk '{print $1}')"
  receipt_set_string "artifacts.exportedWidgetEntitlementsPath" "$widget_entitlements"
  receipt_set_string "artifacts.exportedWidgetEntitlementsSha256" \
    "$(shasum -a 256 "$widget_entitlements" | /usr/bin/awk '{print $1}')"
}

submit_and_record_notarization() {
  local artifact_path=$1
  local label=$2
  local response_path="$RECORD_DIR/$label-submit.json"
  local response_stderr_path="$RECORD_DIR/$label-submit.stderr.log"
  local log_path="$RECORD_DIR/$label-notary-log.json"
  local log_stderr_path="$RECORD_DIR/$label-notary-log.stderr.log"
  local command_status
  local log_command_status=1
  local log_attempt_count=0
  local submission_id=""
  local submission_status="command-failed"
  local log_status="unknown"
  local log_status_code="unknown"
  local issue_count="unknown"
  local artifact_hash
  local log_ok=0

  artifact_hash=$(shasum -a 256 "$artifact_path" | /usr/bin/awk '{print $1}')
  receipt_set_string "notarization.$label.submittedSha256" "$artifact_hash"
  receipt_set_string "notarization.$label.responsePath" "$response_path"
  receipt_set_string "notarization.$label.responseStderrPath" "$response_stderr_path"
  receipt_set_string "notarization.$label.logPath" "$log_path"
  receipt_set_string "notarization.$label.logStderrPath" "$log_stderr_path"
  receipt_set_string "notarization.$label.status" "submitting"

  set +e
  xcrun notarytool submit "$artifact_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 2h --output-format json >"$response_path" 2>"$response_stderr_path"
  command_status=$?
  set -e
  chmod 600 "$response_path" "$response_stderr_path"
  receipt_set_integer "notarization.$label.submitExitStatus" "$command_status"
  receipt_set_string "notarization.$label.responseSha256" \
    "$(shasum -a 256 "$response_path" | /usr/bin/awk '{print $1}')"
  receipt_set_string "notarization.$label.responseStderrSha256" \
    "$(shasum -a 256 "$response_stderr_path" | /usr/bin/awk '{print $1}')"

  if submission_id=$(plutil -extract id raw -expect string "$response_path" 2>/dev/null); then
    submission_status=$(plutil -extract status raw -expect string "$response_path" 2>/dev/null || printf 'unknown')
  fi

  if [ -n "$submission_id" ]; then
    receipt_set_string "notarization.$label.submissionId" "$submission_id"
    : >"$log_stderr_path"
    set +e
    while [ "$log_attempt_count" -lt 3 ]; do
      log_attempt_count=$((log_attempt_count + 1))
      rm -f "$log_path"
      printf 'attempt %s\n' "$log_attempt_count" >>"$log_stderr_path"
      xcrun notarytool log \
        --keychain-profile "$NOTARY_PROFILE" \
        "$submission_id" "$log_path" \
        >/dev/null 2>>"$log_stderr_path"
      log_command_status=$?
      if [ "$log_command_status" -eq 0 ]; then
        break
      fi
      if [ "$log_attempt_count" -lt 3 ]; then
        sleep "$log_attempt_count"
      fi
    done
    set -e
    chmod 600 "$log_stderr_path"
    receipt_set_integer "notarization.$label.logAttemptCount" "$log_attempt_count"
    receipt_set_integer "notarization.$label.logExitStatus" "$log_command_status"
    receipt_set_string "notarization.$label.logStderrSha256" \
      "$(shasum -a 256 "$log_stderr_path" | /usr/bin/awk '{print $1}')"
    if [ "$log_command_status" -eq 0 ] && [ -f "$log_path" ]; then
      chmod 600 "$log_path"
      receipt_set_string "notarization.$label.logSha256" \
        "$(shasum -a 256 "$log_path" | /usr/bin/awk '{print $1}')"
      if issue_count=$(jq -er \
          'if .issues == null then 0
           elif (.issues | type) == "array" then (.issues | length)
           else error("issues must be null or an array") end' "$log_path" 2>/dev/null) \
         && log_status=$(jq -er '.status | select(type == "string")' "$log_path" 2>/dev/null) \
         && log_status_code=$(jq -er '.statusCode | select(type == "number")' "$log_path" 2>/dev/null); then
        receipt_set_integer "notarization.$label.issueCount" "$issue_count"
        receipt_set_string "notarization.$label.logStatus" "$log_status"
        receipt_set_integer "notarization.$label.logStatusCode" "$log_status_code"
        if [ "$log_status" = "$submission_status" ] && [ "$log_status_code" -eq 0 ]; then
          log_ok=1
        fi
      fi
    fi
  fi

  receipt_set_string "notarization.$label.status" "$submission_status"
  printf '    id: %s\n' "${submission_id:-<unavailable>}"
  printf '    status: %s\n' "$submission_status"
  printf '    issues: %s\n' "$issue_count"
  printf '    response: %s\n' "$response_path"
  printf '    log: %s\n' "$log_path"

  if [ "$command_status" -ne 0 ] || [ "$submission_status" != "Accepted" ]; then
    fail "Notarization for $label did not reach Accepted. Check the submission ID in the receipt and do not blindly resubmit."
    return 1
  fi
  if [ "$log_ok" -ne 1 ]; then
    fail "Could not save/verify the notarization log for $label. Fetch it using submission ID $submission_id."
    return 1
  fi
  if [ "$issue_count" != "0" ]; then
    warn "The notarization log for $label has issues. Check $log_path before distributing."
  fi
}

verify_dmg_contents() {
  local verification_label=$1
  local mounted_app
  local mounted_widget
  local mounted_sparkle
  local mounted_notices
  local actual
  local exported_widget="$APP/Contents/PlugIns/AIUsageWidget.appex"
  local exported_sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  local visible_items

  echo "  -- $verification_label: DMG layout and app --"
  MOUNT_DIR=$(mktemp -d "$WORK_DIR/mount.XXXXXX")
  if diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$MOUNT_DIR" \
       "$DMG" >/dev/null 2>&1; then
    MOUNTED=1
  elif hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" \
         "$DMG" >/dev/null 2>&1; then
    MOUNTED=1
  else
    fail "could not mount the DMG read-only"
    return 1
  fi

  mounted_app="$MOUNT_DIR/$APP_NAME.app"
  mounted_widget="$mounted_app/Contents/PlugIns/AIUsageWidget.appex"
  mounted_sparkle="$mounted_app/Contents/Frameworks/Sparkle.framework"
  mounted_notices="$mounted_app/Contents/Resources/Third-Party-Notices.txt"
  [ -d "$mounted_app" ] || { fail "$APP_NAME.app not found in the DMG"; return 1; }
  [ -d "$mounted_widget" ] || { fail "widget extension not found in the DMG"; return 1; }
  [ -d "$mounted_sparkle" ] || { fail "Sparkle.framework not found in the app inside the DMG"; return 1; }
  [ -s "$mounted_notices" ] || { fail "license/third-party notices not found in the app inside the DMG"; return 1; }
  [ -L "$MOUNT_DIR/Applications" ] || { fail "Applications link not found in the DMG"; return 1; }
  [ "$(readlink "$MOUNT_DIR/Applications")" = "/Applications" ] \
    || { fail "the Applications link target in the DMG is invalid"; return 1; }
  [ -s "$MOUNT_DIR/.DS_Store" ] || { fail "Finder layout not found in the DMG"; return 1; }
  [ -s "$MOUNT_DIR/.background.png" ] \
    || { fail "background image not found in the DMG"; return 1; }
  [ "$(shasum -a 256 "$MOUNT_DIR/.background.png" | /usr/bin/awk '{print $1}')" \
     = "$(shasum -a 256 "$DMG_BACKGROUND" | /usr/bin/awk '{print $1}')" ] \
    || { fail "the background image in the DMG does not match the generated artifact"; return 1; }

  if ! "$DMGBUILD_PYTHON" - "$MOUNT_DIR/.DS_Store" "$MOUNT_DIR" <<'PY'
import os
import stat
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    records = {(entry.filename, entry.code): entry.value for entry in store}

mount_dir = sys.argv[2]
bwsp = records.get((".", b"bwsp"), {})
icvp = records.get((".", b"icvp"), {})
expected_locations = {
    ("AI Usage.app", b"Iloc"): (180, 135),
    ("Applications", b"Iloc"): (620, 135),
    (".background.png", b"Iloc"): (1200, 900),
}
expected_root_items = {
    ".DS_Store",
    ".background.png",
    "AI Usage.app",
    "Applications",
}
background_flags = os.stat(os.path.join(mount_dir, ".background.png")).st_flags
valid = (
    records.get((".", b"icvl")) == b"icnv"
    and bwsp.get("WindowBounds") == "{{200, 200}, {800, 500}}"
    and not any(bwsp.get(key, True) for key in (
        "ShowPathbar", "ShowSidebar", "ShowStatusBar", "ShowTabView", "ShowToolbar"
    ))
    and icvp.get("arrangeBy") == "none"
    and icvp.get("backgroundType") == 2
    and icvp.get("iconSize") == 96.0
    and icvp.get("textSize") == 14.0
    and all(records.get(key) == value for key, value in expected_locations.items())
    and bool(background_flags & stat.UF_HIDDEN)
    and set(os.listdir(mount_dir)) == expected_root_items
)
raise SystemExit(0 if valid else 1)
PY
  then
    fail "the Finder layout in the DMG does not match the configured settings"
    return 1
  fi

  visible_items=("$MOUNT_DIR"/*)
  [ "${#visible_items[@]}" -eq 2 ] \
    || { fail "the DMG root does not have exactly 2 visible items"; return 1; }

  codesign --verify --deep --strict --verbose=2 "$mounted_app" 2>&1 | sed 's/^/    /'
  codesign --verify --strict --verbose=2 "$mounted_widget" 2>&1 | sed 's/^/    /'
  codesign --verify --deep --strict --verbose=2 "$mounted_sparkle" 2>&1 | sed 's/^/    /'
  [ "$(codesign_cdhash "$mounted_app")" = "$(codesign_cdhash "$APP")" ] \
    || { fail "the app's CDHash in the DMG does not match the export"; return 1; }
  [ "$(codesign_cdhash "$mounted_widget")" = "$(codesign_cdhash "$exported_widget")" ] \
    || { fail "the widget's CDHash in the DMG does not match the export"; return 1; }
  [ "$(codesign_cdhash "$mounted_sparkle")" = "$(codesign_cdhash "$exported_sparkle")" ] \
    || { fail "Sparkle.framework's CDHash in the DMG does not match the export"; return 1; }
  [ "$(shasum -a 256 "$mounted_notices" | /usr/bin/awk '{print $1}')" \
    = "$(shasum -a 256 "$APP/Contents/Resources/Third-Party-Notices.txt" | /usr/bin/awk '{print $1}')" ] \
    || { fail "the license/third-party notices in the DMG do not match the export"; return 1; }

  actual=$(codesign_team_id "$mounted_app")
  [ "$actual" = "$TEAM_ID" ] || { fail "app Team ID mismatch in the DMG: $actual"; return 1; }
  actual=$(codesign_team_id "$mounted_widget")
  [ "$actual" = "$TEAM_ID" ] || { fail "widget Team ID mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$APP_BUNDLE_ID" ] || { fail "app Bundle ID mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$WIDGET_BUNDLE_ID" ] || { fail "widget Bundle ID mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$VERSION" ] || { fail "app version mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "app build mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$VERSION" ] || { fail "widget version mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "widget build mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value SUFeedURL "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$SPARKLE_FEED_URL" ] || { fail "app Sparkle feed URL mismatch in the DMG: $actual"; return 1; }
  actual=$(plist_value SUPublicEDKey "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$SPARKLE_PUBLIC_KEY" ] || { fail "app Sparkle public key mismatch in the DMG"; return 1; }

  if [ "$UNNOTARIZED" -eq 0 ]; then
    spctl --assess --type execute -vv "$mounted_app" 2>&1 | sed 's/^/    /'
    xcrun stapler validate "$mounted_app" 2>&1 | sed 's/^/    /'
  fi

  if ! cleanup_mount; then
    return 1
  fi
  MOUNT_DIR=""
  return 0
}

prepare_receipt_for_publication() {
  local intended_final_state=$1
  local final_dmg_hash
  local receipt_hash_file="$PROVENANCE.sha256"

  final_dmg_hash=$(shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')
  printf '%s  %s\n' "$final_dmg_hash" "$(basename "$FINAL_DMG")" >"$WORK_DMG_HASH_FILE"

  receipt_set_string "artifacts.dmgPath" "$FINAL_DMG"
  receipt_set_string "artifacts.dmgFinalSha256" "$final_dmg_hash"
  receipt_set_string "artifacts.dmgSha256Path" "$FINAL_DMG_HASH_FILE"
  receipt_set_string "release.intendedFinalState" "$intended_final_state"
  receipt_set_string "verifiedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  receipt_set_string "state" "verified-awaiting-publication"
  plutil -convert json -r "$PROVENANCE"
  chmod 600 "$PROVENANCE"
  shasum -a 256 "$PROVENANCE" >"$receipt_hash_file"
  chmod 600 "$receipt_hash_file"
  chmod 644 "$DMG" "$WORK_DMG_HASH_FILE"
}

complete_receipt() {
  local final_state=$1
  local expected_hash
  local actual_hash
  local receipt_hash_file="$PROVENANCE.sha256"

  expected_hash=$(/usr/bin/awk 'NR == 1 {print $1}' "$FINAL_DMG_HASH_FILE")
  actual_hash=$(shasum -a 256 "$FINAL_DMG" | /usr/bin/awk '{print $1}')
  [ -n "$expected_hash" ] && [ "$actual_hash" = "$expected_hash" ] \
    || { fail "the published DMG does not match the checksum"; return 1; }

  receipt_set_string "completedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  receipt_set_string "state" "$final_state"
  plutil -convert json -r "$PROVENANCE"
  chmod 600 "$PROVENANCE"
  shasum -a 256 "$PROVENANCE" >"$receipt_hash_file"
  chmod 600 "$receipt_hash_file"
}

publish_artifacts() {
  mkdir -p "$(dirname "$FINAL_DMG")"
  if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
    fail "detected output for this same version right before publishing: $FINAL_DMG"
    return 1
  fi

  # Hard-link the checksum first, then link the DMG last. This avoids leaving an unverified DMG name behind if interrupted midway.
  if ! ln "$WORK_DMG_HASH_FILE" "$FINAL_DMG_HASH_FILE"; then
    fail "could not place the SHA-256 artifact at the publish destination"
    return 1
  fi
  if ! ln "$DMG" "$FINAL_DMG"; then
    rm "$FINAL_DMG_HASH_FILE"
    fail "could not place the DMG artifact at the publish destination"
    return 1
  fi
  ARTIFACTS_PUBLISHED=1

  chmod 644 "$FINAL_DMG" "$FINAL_DMG_HASH_FILE"
  if ! rm "$DMG" "$WORK_DMG_HASH_FILE"; then
    warn "could not remove the verified working artifact: $WORK_DIR"
  fi
  DMG="$FINAL_DMG"
  DMG_HASH_FILE="$FINAL_DMG_HASH_FILE"
}

# ---------- Build ----------
CURRENT_STEP="xcodegen"
echo "==> Generating the project"
run_logged "$RECORD_DIR/xcodegen.log" xcodegen generate

CURRENT_STEP="source-provenance"
check_git_source_checkpoint "after xcodegen"
SOURCE_SHA256=$(write_source_manifest "$SOURCE_MANIFEST")
receipt_set_string "source.manifestPath" "$SOURCE_MANIFEST"
receipt_set_string "source.manifestSha256" "$SOURCE_SHA256"

CURRENT_STEP="archive"
echo "==> Archiving ($VERSION / $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
run_logged "$RECORD_DIR/xcodebuild-archive.log" \
  xcodebuild archive \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$PROJECT_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -onlyUsePackageVersionsFromResolvedFile \
    -packageAuthorizationProvider netrc \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

[ -d "$ARCHIVE" ] || { fail "the archive was not created"; exit 1; }

CURRENT_STEP="archive-recording"
echo "==> Saving dSYMs and xcarchive metadata to the release record"
HOST_DSYM="$ARCHIVE/dSYMs/$APP_NAME.app.dSYM"
WIDGET_DSYM="$ARCHIVE/dSYMs/AIUsageWidget.appex.dSYM"
XCARCHIVE_INFO="$ARCHIVE/Info.plist"
RECORDED_HOST_DSYM="$DEBUG_SYMBOL_DIR/$(basename "$HOST_DSYM")"
RECORDED_WIDGET_DSYM="$DEBUG_SYMBOL_DIR/$(basename "$WIDGET_DSYM")"
HOST_DSYM_MANIFEST="$RECORD_DIR/host-dsym-sha256.txt"
WIDGET_DSYM_MANIFEST="$RECORD_DIR/widget-dsym-sha256.txt"
RECORDED_XCARCHIVE_INFO="$RECORD_DIR/xcarchive-Info.plist"

[ -d "$HOST_DSYM" ] || { fail "app dSYM not found in the archive: $HOST_DSYM"; exit 1; }
[ -d "$WIDGET_DSYM" ] || { fail "widget dSYM not found in the archive: $WIDGET_DSYM"; exit 1; }
[ -f "$XCARCHIVE_INFO" ] || { fail "xcarchive's Info.plist not found: $XCARCHIVE_INFO"; exit 1; }

mkdir "$DEBUG_SYMBOL_DIR"
ditto "$HOST_DSYM" "$RECORDED_HOST_DSYM"
ditto "$WIDGET_DSYM" "$RECORDED_WIDGET_DSYM"
cp "$XCARCHIVE_INFO" "$RECORDED_XCARCHIVE_INFO"
chmod -R go-rwx "$DEBUG_SYMBOL_DIR"
chmod 600 "$RECORDED_XCARCHIVE_INFO"

HOST_DSYM_MANIFEST_SHA256=$(write_tree_manifest "$RECORDED_HOST_DSYM" "$HOST_DSYM_MANIFEST")
WIDGET_DSYM_MANIFEST_SHA256=$(write_tree_manifest "$RECORDED_WIDGET_DSYM" "$WIDGET_DSYM_MANIFEST")
XCARCHIVE_INFO_SHA256=$(shasum -a 256 "$RECORDED_XCARCHIVE_INFO" | /usr/bin/awk '{print $1}')
receipt_set_string "artifacts.hostDsymPath" "$RECORDED_HOST_DSYM"
receipt_set_string "artifacts.hostDsymManifestPath" "$HOST_DSYM_MANIFEST"
receipt_set_string "artifacts.hostDsymManifestSha256" "$HOST_DSYM_MANIFEST_SHA256"
receipt_set_string "artifacts.widgetDsymPath" "$RECORDED_WIDGET_DSYM"
receipt_set_string "artifacts.widgetDsymManifestPath" "$WIDGET_DSYM_MANIFEST"
receipt_set_string "artifacts.widgetDsymManifestSha256" "$WIDGET_DSYM_MANIFEST_SHA256"
receipt_set_string "artifacts.xcarchiveInfoPath" "$RECORDED_XCARCHIVE_INFO"
receipt_set_string "artifacts.xcarchiveInfoSha256" "$XCARCHIVE_INFO_SHA256"

CURRENT_STEP="export"
echo "==> Exporting with Developer ID"
run_logged "$RECORD_DIR/xcodebuild-export.log" \
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist packaging/ExportOptions.plist \
    -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/$APP_NAME.app"
CURRENT_STEP="export-verification"
echo "==> Verifying signature, bundle identity, and version"
verify_exported_app

SOURCE_SHA256_AFTER=$(write_source_manifest "$SOURCE_MANIFEST_AFTER")
receipt_set_string "source.manifestAfterBuildPath" "$SOURCE_MANIFEST_AFTER"
receipt_set_string "source.manifestAfterBuildSha256" "$SOURCE_SHA256_AFTER"
check_git_source_checkpoint "after archive/export"
if [ "$SOURCE_SHA256_AFTER" != "$SOURCE_SHA256" ]; then
  fail "The source changed during the build. The artifact will not be notarized."
  exit 1
fi

CURRENT_STEP="dmg-input-snapshot"
echo "==> Pinning the DMG inputs from the build source"
snapshot_dmg_inputs

# ---------- App-only notarization ----------
# Staple a ticket onto the .app too, so the first launch succeeds offline after extraction from the DMG.
if [ "$UNNOTARIZED" -eq 0 ]; then
  CURRENT_STEP="app-notarization"
  echo "==> Notarizing the app (1/2)"
  APP_ZIP="$RECORD_DIR/$PROJECT_NAME-notary.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  chmod 600 "$APP_ZIP"
  receipt_set_string "artifacts.appNotaryZipPath" "$APP_ZIP"
  submit_and_record_notarization "$APP_ZIP" "app"
  xcrun stapler staple "$APP" | sed 's/^/    /'
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
fi

# ---------- DMG ----------
CURRENT_STEP="dmg-source-verification"
check_git_source_checkpoint "before DMG creation"
SOURCE_SHA256_BEFORE_DMG=$(write_source_manifest "$SOURCE_MANIFEST_BEFORE_DMG")
receipt_set_string "source.manifestBeforeDmgPath" "$SOURCE_MANIFEST_BEFORE_DMG"
receipt_set_string "source.manifestBeforeDmgSha256" "$SOURCE_SHA256_BEFORE_DMG"
if [ "$SOURCE_SHA256_BEFORE_DMG" != "$SOURCE_SHA256_AFTER" ]; then
  fail "The source changed while waiting for app notarization. The DMG will not be created."
  exit 1
fi
if ! inspect_release_tools; then
  fail "cannot verify the release tools right before creating the DMG: $RELEASE_TOOLS_ERROR"
  exit 1
fi
if [ "$(shasum -a 256 "$DMGBUILD_STAMP" | /usr/bin/awk '{print $1}')" \
     != "$(shasum -a 256 "$DMGBUILD_STAMP_SNAPSHOT" | /usr/bin/awk '{print $1}')" ]; then
  fail "the release tool stamp changed during the build"
  exit 1
fi

CURRENT_STEP="dmg-creation"
echo "==> Creating the DMG"
mkdir -p "$(dirname "$DMG")"
DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" xcrun swift \
  "$DMG_BACKGROUND_RENDERER_SNAPSHOT" "$DMG_BACKGROUND"

BACKGROUND_WIDTH=$(sips -g pixelWidth "$DMG_BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ {print $2}')
BACKGROUND_HEIGHT=$(sips -g pixelHeight "$DMG_BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ {print $2}')
if [ "$BACKGROUND_WIDTH" != "800" ] || [ "$BACKGROUND_HEIGHT" != "500" ]; then
  fail "DMG background dimensions are invalid: ${BACKGROUND_WIDTH:-?}x${BACKGROUND_HEIGHT:-?}"
  exit 1
fi

receipt_set_string "artifacts.dmgLayout.generator" "dmgbuild"
receipt_set_string "artifacts.dmgLayout.generatorVersion" "$ACTUAL_DMGBUILD_VERSION"
receipt_set_string "artifacts.dmgLayout.dsStoreVersion" "$ACTUAL_DS_STORE_VERSION"
receipt_set_string "artifacts.dmgLayout.macAliasVersion" "$ACTUAL_MAC_ALIAS_VERSION"
receipt_set_string "artifacts.dmgLayout.pythonVersion" "$ACTUAL_RELEASE_PYTHON_VERSION"
receipt_set_string "artifacts.dmgLayout.requirementsSha256" \
  "$(shasum -a 256 "$DMG_REQUIREMENTS_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.settingsSha256" \
  "$(shasum -a 256 "$DMG_SETTINGS_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.rendererSha256" \
  "$(shasum -a 256 "$DMG_BACKGROUND_RENDERER_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.toolchainStampSha256" \
  "$(shasum -a 256 "$DMGBUILD_STAMP_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.backgroundSha256" \
  "$(shasum -a 256 "$DMG_BACKGROUND" | /usr/bin/awk '{print $1}')"

"$DMGBUILD_PYTHON" -m dmgbuild \
  --no-hidpi \
  -s "$DMG_SETTINGS_SNAPSHOT" \
  -D "app=$APP" \
  -D "background=$DMG_BACKGROUND" \
  "$VOLUME_NAME" "$DMG"
echo "    created (dmgbuild $ACTUAL_DMGBUILD_VERSION)"

CURRENT_STEP="dmg-source-postcheck"
if ! inspect_release_tools; then
  fail "cannot verify the release tools after creating the DMG: $RELEASE_TOOLS_ERROR"
  exit 1
fi
check_git_source_checkpoint "after DMG creation"
SOURCE_SHA256_AFTER_DMG=$(write_source_manifest "$SOURCE_MANIFEST_AFTER_DMG")
receipt_set_string "source.manifestAfterDmgPath" "$SOURCE_MANIFEST_AFTER_DMG"
receipt_set_string "source.manifestAfterDmgSha256" "$SOURCE_SHA256_AFTER_DMG"
if [ "$SOURCE_SHA256_AFTER_DMG" != "$SOURCE_SHA256_AFTER" ]; then
  fail "The source changed during DMG creation. The artifact will not be signed."
  exit 1
fi

CURRENT_STEP="dmg-signing"
echo "==> Signing the DMG with Team ${TEAM_ID}'s certificate"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=4 "$DMG" 2>&1 | sed 's/^/    /'
DMG_TEAM_ID=$(codesign_team_id "$DMG")
if [ "$DMG_TEAM_ID" != "$TEAM_ID" ]; then
  fail "DMG Team ID mismatch: $DMG_TEAM_ID"
  exit 1
fi

CURRENT_STEP="dmg-content-verification"
verify_dmg_contents "pre-notarization verification"
receipt_set_string "artifacts.dmgLayout.preNotarizationVerification" "passed"

if [ "$UNNOTARIZED" -eq 1 ]; then
  CURRENT_STEP="receipt-preparation"
  prepare_receipt_for_publication "complete-unnotarized"
  CURRENT_STEP="artifact-promotion"
  publish_artifacts
  CURRENT_STEP="receipt-completion"
  complete_receipt "complete-unnotarized"
  CURRENT_STEP="complete"
  warn "This is an unnotarized artifact. Gatekeeper will reject it, so do not use it for regular distribution."
  green "Verification DMG: $DMG"
  green "SHA-256: $DMG_HASH_FILE"
  green "Release record: $PROVENANCE"
  exit 0
fi

# ---------- DMG notarization ----------
CURRENT_STEP="dmg-notarization"
echo "==> Notarizing the DMG (2/2)"
submit_and_record_notarization "$DMG" "dmg"

CURRENT_STEP="dmg-stapling"
echo "==> Stapling"
xcrun stapler staple "$DMG" | sed 's/^/    /'

# ---------- Final verification ----------
CURRENT_STEP="final-verification"
echo "==> Final verification"
echo "  -- DMG --"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$DMG" 2>&1 | sed 's/^/    /'
verify_dmg_contents "final artifact"
receipt_set_string "artifacts.dmgLayout.finalVerification" "passed"

CURRENT_STEP="receipt-preparation"
prepare_receipt_for_publication "complete"
CURRENT_STEP="artifact-promotion"
publish_artifacts
CURRENT_STEP="receipt-completion"
complete_receipt "complete"
CURRENT_STEP="complete"

green "Done: $DMG"
green "SHA-256: $DMG_HASH_FILE"
green "Release record: $PROVENANCE"
