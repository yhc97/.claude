#!/usr/bin/env bash
# PreToolUse (Bash matcher) commit-guard hook.
# Blocks `git commit` on branch main/master; fails open on everything else.
#
# Protocol: PreToolUse JSON arrives on stdin. It carries .tool_input.command
# (the Bash command about to run — MAY CONTAIN NEWLINES) and .cwd (a Windows
# path, no newlines). Exit 2 = block (stderr shown to the model); exit 0 =
# allow / no opinion.
#
# jq is not guaranteed on this machine and cannot safely reason about shell
# command structure anyway, so ALL parsing + commit-detection happens in python.
# Python reads stdin and, only when the command actually invokes `git commit`,
# prints the single-line cwd (Windows paths can't contain newlines) — otherwise
# it prints nothing. Bash just acts on that verdict. If no python is available,
# JSON parsing fails, or anything else goes wrong, we FAIL OPEN.

set -u

py=""
if command -v python3 >/dev/null 2>&1; then py="python3"
elif command -v python >/dev/null 2>&1; then py="python"
fi
# No interpreter -> can't parse -> fail open.
[ -z "$py" ] && exit 0

# Python does the whole job: parse JSON, detect a real `git commit` invocation,
# and print ONLY the cwd when one is found (single line, no cwd -> nothing).
cwd="$("$py" -c '
import sys, json, re

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

ti = d.get("tool_input") or {}
command = ti.get("command") or ""
cwd = d.get("cwd") or ""
if not isinstance(command, str) or not isinstance(cwd, str):
    sys.exit(0)

# Split the command into rough segments on shell boundaries so a leading `echo`
# (or any other command word) shields text like `echo "git commit is great"`.
# We split on newlines, ; && || | & $( and backticks. Best-effort by design:
# this guard must fail open, so weird quoting that slips either way is fine.
segments = re.split(r"\n|;|&&|\|\||\||&|\$\(|`", command)

# Anchored at the segment start: optional leading whitespace, any number of
# env-var assignments (FOO=bar ), then `git`, then any number of git global
# flags (-x, --long, --long=val, -c key=val), then `commit`.
commit_re = re.compile(
    r"^\s*(?:\w+=\S*\s+)*git\s+(?:-\S+\s+|-c\s+\S+\s+|--\S+(?:=\S+)?\s+)*commit\b"
)

matched = any(commit_re.search(seg) for seg in segments)
if matched and cwd:
    # Windows paths cannot contain newlines, so one line is unambiguous.
    sys.stdout.write(cwd)
' 2>/dev/null)"

# Empty -> not a git commit (or no cwd) -> nothing to guard.
[ -z "$cwd" ] && exit 0

# Determine the current branch in the tool cwd. Fail open on any error:
# missing dir, not a repo, detached HEAD, or empty output all yield "".
if [ -d "$cwd" ]; then
  branch="$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null || true)"
else
  exit 0
fi

# Detached HEAD / not a repo / unknown -> empty branch -> fail open.
[ -z "$branch" ] && exit 0

if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "Blocked: committing directly to main/master violates the user's git rules. Create a branch first (feat/, bugfix/, merge/, chore/)." >&2
  exit 2
fi

exit 0
