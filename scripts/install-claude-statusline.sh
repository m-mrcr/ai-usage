#!/bin/bash
# Registers a statusLine in ~/.claude/settings.json (backs up the existing setting).
# To remove it, use scripts/uninstall-claude-statusline.sh.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
STATE="$HOME/.claude/.aiusage-statusline-state.json"
[ -f "$SETTINGS" ] || { echo "not found: $SETTINGS" >&2; exit 1; }

STATUSLINE_PATH="$SCRIPT_DIR/claude-statusline.sh" STATE_PATH="$STATE" \
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
installed = {
    "type": "command",
    "command": os.environ["STATUSLINE_PATH"],
    "padding": 0,
}

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
            "settings.json changed while installing; quit Claude Code and retry"
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
    base = f"{file_path}.bak-aiusage-{stamp}"
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
backup = create_backup(path, original_settings)

old_state = None
try:
    old_state = read_json(state_path, maximum=256 * 1024)
except FileNotFoundError:
    pass
except Exception:
    raise ValueError(f"invalid installer state: {state_path}")

current_exists = "statusLine" in settings
current = settings.get("statusLine")
if (isinstance(old_state, dict)
        and old_state.get("version") == 1
        and current_exists
        and current == old_state.get("installed")):
    # Keep the originally saved-off value even across a reinstall or a repository move.
    had_previous = bool(old_state.get("had_previous"))
    previous = old_state.get("previous")
else:
    had_previous = current_exists
    previous = current

if current_exists and current != installed:
    print("warning: saving off the existing statusLine and replacing it with AIUsage")

state = {
    "version": 1,
    "installed": installed,
    "had_previous": had_previous,
    "previous": previous,
}

# Persist the restore information first, then switch over the settings.
assert_unchanged(path, original_settings)
atomic_json(state_path, state, 0o600)
settings["statusLine"] = installed
atomic_json(path, settings, settings_mode)

print("backup:", backup)
print("installed statusLine ->", installed["command"])
PY
echo "Next, launch Claude Code — once you receive one response, usage will be recorded."
