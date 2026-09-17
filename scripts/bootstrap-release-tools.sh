#!/bin/bash
# Prepares the DMG layout generation tools at a pinned version, separate from the release process.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${RELEASE_PYTHON:-python3}"
TOOLS_ROOT="$ROOT/build/release-tools"
VENV="$TOOLS_ROOT/venv"
REQUIREMENTS="$ROOT/packaging/dmg/requirements.txt"
STAMP="$TOOLS_ROOT/toolchain-stamp.txt"
RELEASE_LOCK_DIR="$ROOT/build/release.lock"
LOCK_HELD=0

cleanup_on_exit() {
  local script_status=$?
  trap - EXIT
  if [ "$LOCK_HELD" -eq 1 ] && ! rmdir "$RELEASE_LOCK_DIR"; then
    echo "could not release the release tool lock: $RELEASE_LOCK_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi
  exit "$script_status"
}
trap cleanup_on_exit EXIT

mkdir -p "$ROOT/build"
if ! mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
  echo "another release or release tool preparation is running: $RELEASE_LOCK_DIR" >&2
  echo "Only rmdir the empty lock directory if you've confirmed no process is actually running." >&2
  exit 1
fi
LOCK_HELD=1
mkdir -p "$TOOLS_ROOT"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "Python 3.10 or later is required: $PYTHON" >&2
  exit 1
fi

PYTHON_VERSION=$(
  "$PYTHON" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))'
)
if ! "$PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 or later is required (current: ${PYTHON_VERSION})" >&2
  exit 1
fi

rm -f "$STAMP"
"$PYTHON" -m venv --clear "$VENV"
"$VENV/bin/python" -m pip install \
  --disable-pip-version-check \
  --require-hashes \
  --only-binary=:all: \
  -r "$REQUIREMENTS"

"$VENV/bin/python" -c '
from importlib.metadata import distribution, version
import base64
import hashlib

expected = {"dmgbuild": "1.6.7", "ds-store": "1.3.3", "mac-alias": "2.2.3"}
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
'

REQUIREMENTS_SHA256=$(shasum -a 256 "$REQUIREMENTS" | /usr/bin/awk '{print $1}')
INSTALLED_PYTHON_VERSION=$("$VENV/bin/python" -c 'import platform; print(platform.python_version())')
DMGBUILD_VERSION=$("$VENV/bin/python" -c 'from importlib.metadata import version; print(version("dmgbuild"))')
DS_STORE_VERSION=$("$VENV/bin/python" -c 'from importlib.metadata import version; print(version("ds-store"))')
MAC_ALIAS_VERSION=$("$VENV/bin/python" -c 'from importlib.metadata import version; print(version("mac-alias"))')
STAMP_TEMP=$(mktemp "$TOOLS_ROOT/toolchain-stamp.XXXXXX")
{
  printf 'schemaVersion=1\n'
  printf 'requirementsSha256=%s\n' "$REQUIREMENTS_SHA256"
  printf 'pythonVersion=%s\n' "$INSTALLED_PYTHON_VERSION"
  printf 'dmgbuildVersion=%s\n' "$DMGBUILD_VERSION"
  printf 'dsStoreVersion=%s\n' "$DS_STORE_VERSION"
  printf 'macAliasVersion=%s\n' "$MAC_ALIAS_VERSION"
} >"$STAMP_TEMP"
chmod 600 "$STAMP_TEMP"
mv "$STAMP_TEMP" "$STAMP"

echo "release tools ready: dmgbuild $DMGBUILD_VERSION / ds-store $DS_STORE_VERSION / mac-alias $MAC_ALIAS_VERSION ($VENV)"
