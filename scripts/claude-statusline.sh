#!/bin/bash
# Called from Claude Code's statusLine.
#   1) Saves the received JSON's rate_limits for AIUsage (the widget's data source)
#   2) Prints the status line itself to stdout
# stdin's JSON spec: https://code.claude.com/docs/en/statusline
set -uo pipefail
umask 077

INPUT=$(/usr/bin/head -c 1048576)
OUT_DIR="$HOME/Library/Application Support/AIUsage"
/bin/mkdir -p "$OUT_DIR"
/bin/chmod 700 "$OUT_DIR" 2>/dev/null || true

# --- 0) Record the raw payload (only when AIUSAGE_DEBUG=1 is explicitly set) ---------------
if [ "${AIUSAGE_DEBUG:-0}" = "1" ]; then
  RAW_LOG="$OUT_DIR/statusline-raw.log"
  RAW_MAX_BYTES=262144
  RAW_TMP=$(/usr/bin/mktemp "$OUT_DIR/.statusline-raw.XXXXXX" 2>/dev/null) || RAW_TMP=""
  if [ -n "$RAW_TMP" ]; then
    if {
      if [ -f "$RAW_LOG" ]; then
        /usr/bin/tail -c "$RAW_MAX_BYTES" "$RAW_LOG" 2>/dev/null || true
      fi
      printf '%s\n' "$INPUT"
    } | /usr/bin/tail -c "$RAW_MAX_BYTES" > "$RAW_TMP"; then
      /bin/chmod 600 "$RAW_TMP"
      /bin/mv -f "$RAW_TMP" "$RAW_LOG"
    else
      /bin/rm -f "$RAW_TMP"
    fi
  fi
fi

# --- 1) Save the remaining allowance -----------------------------------------------------------
# rate_limits is attached for Claude.ai subscriptions (Pro/Max), after the first response in a session.
printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys, os, tempfile

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

import math, time

def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None

def clean_window(value):
    if not isinstance(value, dict):
        return None
    used = number(value.get("used_percentage"))
    if used is None or not 0 <= used <= 100:
        return None
    result = {"used_percentage": used}
    resets = number(value.get("resets_at"))
    if resets is not None:
        now = time.time()
        if now - 30 * 86400 <= resets <= now + 370 * 86400:
            result["resets_at"] = resets
    return result

limits = data.get("rate_limits")
if not isinstance(limits, dict):
    sys.exit(0)

payload = {"observed_at": time.time()}
for key in ("five_hour", "seven_day"):
    window = clean_window(limits.get(key))
    if window is not None:
        payload[key] = window
if "five_hour" not in payload and "seven_day" not in payload:
    sys.exit(0)

out_dir = os.path.join(os.path.expanduser("~"), "Library/Application Support/AIUsage")
os.makedirs(out_dir, exist_ok=True)
os.chmod(out_dir, 0o700)
path = os.path.join(out_dir, "claude.json")
fd, tmp = tempfile.mkstemp(prefix=".claude.", dir=out_dir)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    tmp = None
finally:
    if tmp is not None:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
' 2>/dev/null

# --- 2) Render the status line ---------------------------------------------------
printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys, os

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

import math, unicodedata

def clean_text(value, limit=80):
    if not isinstance(value, str):
        return None
    cleaned = "".join(
        ch for ch in value
        if unicodedata.category(ch) not in {"Cc", "Cf", "Cs"}
    ).strip()
    return cleaned[:limit] or None

def percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if not math.isfinite(value) or not 0 <= value <= 100:
        return None
    return value

parts = []

model_data = data.get("model")
model = clean_text(model_data.get("display_name")) if isinstance(model_data, dict) else None
if model:
    parts.append(model)

workspace = data.get("workspace")
cwd = workspace.get("current_dir") if isinstance(workspace, dict) else None
cwd = clean_text(cwd or data.get("cwd"))
if cwd:
    parts.append(clean_text(os.path.basename(cwd)) or "")

context = data.get("context_window")
ctx = percent(context.get("used_percentage")) if isinstance(context, dict) else None
if ctx is not None:
    filled = min(10, max(0, int(ctx // 10)))
    parts.append("ctx " + "▓" * filled + "░" * (10 - filled) + f" {int(ctx)}%")

limits = data.get("rate_limits")
limits = limits if isinstance(limits, dict) else {}
chips = []
for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
    window = limits.get(key)
    used = percent(window.get("used_percentage")) if isinstance(window, dict) else None
    if used is not None:
        chips.append(f"{label} {int(used)}%")
if chips:
    parts.append(" | ".join(chips))

print("  ".join(parts))
' 2>/dev/null
