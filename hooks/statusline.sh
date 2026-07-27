#!/usr/bin/env bash
# Status line: shows the active model tier and the current git branch.
# Reads the Claude Code status JSON on stdin; fails soft (prints what it can).
set -u

input="$(cat)"

# Match the repo's other hooks: jq isn't guaranteed, so parse with python.
# Probe python3 first, then python; if neither exists, skip JSON parsing.
py=""
if command -v python3 >/dev/null 2>&1; then py="python3"
elif command -v python >/dev/null 2>&1; then py="python"
fi

model=""
cwd=""
if [ -n "$py" ]; then
  info="$(printf '%s' "$input" | "$py" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("model", {}).get("display_name", "") or "")
print(d.get("workspace", {}).get("current_dir") or d.get("cwd", "") or "")
' 2>/dev/null)"
  model="$(printf '%s\n' "$info" | sed -n '1p')"
  cwd="$(printf '%s\n' "$info" | sed -n '2p')"
fi

# Branch: prefer the JSON-derived cwd; fall back to the process cwd (Claude Code
# runs the status command with cwd set to the workspace), so the branch still
# shows even when python is unavailable.
branch=""
if [ -n "$cwd" ]; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
fi
if [ -z "$branch" ]; then
  branch="$(git branch --show-current 2>/dev/null)"
fi

if [ -n "$model" ] && [ -n "$branch" ]; then
  printf '%s  \xe2\x8e\x87 %s' "$model" "$branch"
elif [ -n "$model" ]; then
  printf '%s' "$model"
elif [ -n "$branch" ]; then
  printf '\xe2\x8e\x87 %s' "$branch"
fi
