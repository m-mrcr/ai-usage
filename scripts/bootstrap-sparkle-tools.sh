#!/bin/bash
# Prepares Sparkle's distribution CLI from the official release archive, at a pinned version/hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.9.6"
ARCHIVE_NAME="Sparkle-${SPARKLE_VERSION}.tar.xz"
ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${ARCHIVE_NAME}"
ARCHIVE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
TOOLS_ROOT="$ROOT/build/sparkle-tools"
INSTALL_DIR="$TOOLS_ROOT/$SPARKLE_VERSION"
DOWNLOAD_DIR="$TOOLS_ROOT/downloads"
CACHED_ARCHIVE="$DOWNLOAD_DIR/$ARCHIVE_NAME"
LOCK_DIR="$TOOLS_ROOT/.bootstrap.lock"

# Also pins the 3 binaries extracted after the archive hash is verified.
GENERATE_APPCAST_SHA256="b3b54ba3fb85ef1f25eb2f5a9ad90c32ba6e71af777b181c50ffb5d860bac6b7"
SIGN_UPDATE_SHA256="bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
GENERATE_KEYS_SHA256="2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"

WORK_DIR=""
LOCK_HELD=0

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/bootstrap-sparkle-tools.sh

Verifies Sparkle 2.9.6's official tar.xz against a pinned SHA-256, then extracts it to:
  build/sparkle-tools/2.9.6/bin/

This script never creates, exports, or displays a Sparkle signing key.
USAGE
}

cleanup() {
  local script_status=$?
  trap - EXIT

  if [ -n "$WORK_DIR" ]; then
    case "$WORK_DIR" in
      "$TOOLS_ROOT"/.bootstrap-work.*)
        rm -rf -- "$WORK_DIR"
        ;;
      *)
        printf 'error: unexpected temporary path; not removing: %s\n' "$WORK_DIR" >&2
        if [ "$script_status" -eq 0 ]; then
          script_status=1
        fi
        ;;
    esac
  fi

  if [ "$LOCK_HELD" -eq 1 ] && ! rmdir "$LOCK_DIR"; then
    printf 'error: could not release the Sparkle tool lock: %s\n' "$LOCK_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi
  exit "$script_status"
}
trap cleanup EXIT

case "$#:${1:-}" in
  "0:")
    ;;
  "1:--help"|"1:-h")
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for command_name in curl shasum tar codesign; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "missing required command: $command_name"
done

file_sha256() {
  shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_binary() {
  local path=$1
  local expected_hash=$2
  local actual_hash

  [ -x "$path" ] || return 1
  actual_hash=$(file_sha256 "$path")
  [ "$actual_hash" = "$expected_hash" ] || return 1
  codesign --verify --deep --strict "$path" >/dev/null 2>&1
}

verify_installation() {
  local stamp="$INSTALL_DIR/toolchain-stamp.txt"

  [ -f "$stamp" ] || return 1
  /usr/bin/awk -F= \
    -v version="$SPARKLE_VERSION" \
    -v archive_url="$ARCHIVE_URL" \
    -v archive_sha="$ARCHIVE_SHA256" '
      $1 == "sparkleVersion" && $2 == version { version_ok=1 }
      $1 == "archiveURL" && $2 == archive_url { url_ok=1 }
      $1 == "archiveSha256" && $2 == archive_sha { archive_ok=1 }
      END { exit !(version_ok && url_ok && archive_ok) }
    ' "$stamp" || return 1
  verify_binary "$INSTALL_DIR/bin/generate_appcast" "$GENERATE_APPCAST_SHA256" || return 1
  verify_binary "$INSTALL_DIR/bin/sign_update" "$SIGN_UPDATE_SHA256" || return 1
  verify_binary "$INSTALL_DIR/bin/generate_keys" "$GENERATE_KEYS_SHA256" || return 1
  [ -f "$INSTALL_DIR/LICENSE" ]
}

mkdir -p "$TOOLS_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another Sparkle tool preparation is running: $LOCK_DIR"
fi
LOCK_HELD=1

if [ -e "$INSTALL_DIR" ]; then
  if verify_installation; then
    printf 'Sparkle tools ready: %s\n' "$INSTALL_DIR/bin"
    exit 0
  fi
  fail "the existing Sparkle tool installation doesn't match the pinned hash: $INSTALL_DIR"
fi

mkdir -p "$DOWNLOAD_DIR"
WORK_DIR=$(mktemp -d "$TOOLS_ROOT/.bootstrap-work.XXXXXX")
DOWNLOAD_TEMP="$WORK_DIR/$ARCHIVE_NAME"

if [ -f "$CACHED_ARCHIVE" ] \
   && [ "$(file_sha256 "$CACHED_ARCHIVE")" = "$ARCHIVE_SHA256" ]; then
  ARCHIVE_PATH="$CACHED_ARCHIVE"
else
  curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-all-errors \
    --output "$DOWNLOAD_TEMP" \
    "$ARCHIVE_URL"
  [ "$(file_sha256 "$DOWNLOAD_TEMP")" = "$ARCHIVE_SHA256" ] \
    || fail "the Sparkle archive's SHA-256 doesn't match the pinned value"
  chmod 644 "$DOWNLOAD_TEMP"
  mv -f "$DOWNLOAD_TEMP" "$CACHED_ARCHIVE"
  ARCHIVE_PATH="$CACHED_ARCHIVE"
fi

[ "$(file_sha256 "$ARCHIVE_PATH")" = "$ARCHIVE_SHA256" ] \
  || fail "the Sparkle archive cache's SHA-256 doesn't match the pinned value"

STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"
tar -xJf "$ARCHIVE_PATH" -C "$STAGE_DIR" \
  ./bin/generate_appcast \
  ./bin/sign_update \
  ./bin/generate_keys \
  ./LICENSE

verify_binary "$STAGE_DIR/bin/generate_appcast" "$GENERATE_APPCAST_SHA256" \
  || fail "generate_appcast verification failed"
verify_binary "$STAGE_DIR/bin/sign_update" "$SIGN_UPDATE_SHA256" \
  || fail "sign_update verification failed"
verify_binary "$STAGE_DIR/bin/generate_keys" "$GENERATE_KEYS_SHA256" \
  || fail "generate_keys verification failed"

STAMP_TEMP="$STAGE_DIR/toolchain-stamp.txt.tmp"
{
  printf 'schemaVersion=1\n'
  printf 'sparkleVersion=%s\n' "$SPARKLE_VERSION"
  printf 'archiveURL=%s\n' "$ARCHIVE_URL"
  printf 'archiveSha256=%s\n' "$ARCHIVE_SHA256"
  printf 'generateAppcastSha256=%s\n' "$GENERATE_APPCAST_SHA256"
  printf 'signUpdateSha256=%s\n' "$SIGN_UPDATE_SHA256"
  printf 'generateKeysSha256=%s\n' "$GENERATE_KEYS_SHA256"
} >"$STAMP_TEMP"
chmod 644 "$STAMP_TEMP"
mv "$STAMP_TEMP" "$STAGE_DIR/toolchain-stamp.txt"

# INSTALL_DIR doesn't exist at this point. Only the finished directory is published, all at once.
mv "$STAGE_DIR" "$INSTALL_DIR"
printf 'Sparkle tools ready: %s\n' "$INSTALL_DIR/bin"
