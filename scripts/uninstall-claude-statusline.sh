#!/bin/bash
# Removes only the statusLine owned by AIUsage, and restores the value from before it was installed.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
STATE="$HOME/.claude/.aiusage-statusline-state.json"
[ -f "$SETTINGS" ] || { echo "not found: $SETTINGS" >&2; exit 1; }

EXPECTED_PATH="$SCRIPT_DIR/claude-statusline.sh" STATE_PATH="$STATE" \
  /usr/bin/python3 - "$SETTINGS" <<'PY'
import fcntl, json, os, stat, sys, tempfile, time

path = sys.argv[1]
state_path = os.environ["STATE_PATH"]
lock_path = os.path.join(os.path.dirname(path), ".aiusage-statusline.lock")
lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
os.fchmod(lock_fd, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise RuntimeError("another AIUsage statusLine installer is running")

def read_json(file_path, maximum=5 * 1024 * 1024):
    info = os.stat(file_path)
    if info.st_size > maximum:
        raise ValueError(f"JSON is too large: {file_path}")
    with open(file_path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {file_path}")
    return value

def read_bytes(file_path, maximum=5 * 1024 * 1024):
    with open(file_path, "rb") as handle:
        value = handle.read(maximum + 1)
    if len(value) > maximum:
        raise ValueError(f"file is too large: {file_path}")
    return value

def assert_unchanged(file_path, expected):
    if read_bytes(file_path) != expected:
        raise RuntimeError(
            "settings.json changed while uninstalling; quit Claude Code and retry"
        )

def sync_directory(directory):
    try:
        fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass

def atomic_json(file_path, value, mode):
    directory = os.path.dirname(file_path)
    fd, temporary = tempfile.mkstemp(prefix=".aiusage-settings.", dir=directory)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, file_path)
        temporary = None
        sync_directory(directory)
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

def create_backup(file_path, contents):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = f"{file_path}.bak-aiusage-uninstall-{stamp}"
    candidate = base
    counter = 1
    while True:
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.fchmod(fd, 0o600)
            break
        except FileExistsError:
            candidate = f"{base}-{counter}"
            counter += 1
    try:
        with os.fdopen(fd, "wb") as target:
            target.write(contents)
            target.flush()
            os.fsync(target.fileno())
    except Exception:
        try:
            os.unlink(candidate)
        except FileNotFoundError:
            pass
        raise
    sync_directory(os.path.dirname(file_path))
    return candidate

original_settings = read_bytes(path)
settings_mode = stat.S_IMODE(os.stat(path).st_mode)
settings = read_json(path)
current_exists = "statusLine" in settings
current = settings.get("statusLine")

try:
    state = read_json(state_path, maximum=256 * 1024)
except FileNotFoundError:
    state = None

if state is not None:
    if state.get("version") != 1 or not isinstance(state.get("installed"), dict):
        raise ValueError(f"invalid installer state: {state_path}")
    if not current_exists or current != state["installed"]:
        print("not removed: the current statusLine has been changed from the value AIUsage installed", file=sys.stderr)
        sys.exit(2)

    if bool(state.get("had_previous")):
        settings["statusLine"] = state.get("previous")
        action = "restored previous statusLine"
    else:
        settings.pop("statusLine", None)
        action = "removed AIUsage statusLine"

    backup = create_backup(path, original_settings)
    assert_unchanged(path, original_settings)
    atomic_json(path, settings, settings_mode)
    os.unlink(state_path)
    sync_directory(os.path.dirname(state_path))
    print("backup:", backup)
    print(action)
else:
    # An old installer has no state. Only remove it when it exactly matches the current script.
    legacy = {
        "type": "command",
        "command": os.environ["EXPECTED_PATH"],
        "padding": 0,
    }
    if current_exists and current == legacy:
        settings.pop("statusLine", None)
        backup = create_backup(path, original_settings)
        assert_unchanged(path, original_settings)
        atomic_json(path, settings, settings_mode)
        print("backup:", backup)
        print("removed legacy AIUsage statusLine (previous value is available only in .bak-aiusage files)")
    else:
        print("not removed: no statusLine could be confirmed as owned by AIUsage", file=sys.stderr)
        sys.exit(2)
PY
