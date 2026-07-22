#!/usr/bin/env bash
# PreToolUse (Bash matcher) commit-review-gate hook  +  --approve recorder.
#
# Purpose: block `git commit` (issued via the Bash tool) until a code review
# has been recorded for the CURRENT pending changes. A review is "recorded" by
# running this same script with --approve, which stores a fingerprint of the
# pending changes. The commit is allowed only while that fingerprint still
# matches — so it auto-invalidates once files change or the commit lands.
#
# Two modes:
#   (default, no args)  Hook mode. Reads PreToolUse JSON on stdin, detects a
#                       real `git commit`, and blocks (exit 2) unless a matching
#                       review marker exists. Fails OPEN on every error.
#   --approve           Recorder mode. Run inside a git repo; writes the current
#                       fingerprint to the marker file so the next commit passes.
#
# Protocol (hook mode): PreToolUse JSON arrives on stdin. It carries
# .tool_input.command (the Bash command about to run — MAY CONTAIN NEWLINES) and
# .cwd (a Windows path, no newlines). Exit 2 = block (stderr shown to the model);
# exit 0 = allow / no opinion. This gate must NEVER block anything except a
# detected `git commit`, and must FAIL OPEN on all errors.
#
# jq is not guaranteed on this machine and cannot safely reason about shell
# command structure anyway, so ALL parsing + commit-detection happens in python
# (mirroring block-main-commit.sh; the two scripts are kept independent).

set -u

# --- shared fingerprint of the pending changes -----------------------------
# CRITICAL: hook mode and approve mode MUST compute this identically, so both
# call this one function. It is run with the current directory inside the repo.
# Fingerprint = sha256 of `git status --porcelain` output concatenated with
# `git diff HEAD` output. `git diff HEAD` fails in a repo with no commits yet —
# that is tolerated and treated as empty output (we do NOT fail closed).
compute_fingerprint() {
  local status diff
  status="$(git status --porcelain 2>/dev/null)"
  diff="$(git diff HEAD 2>/dev/null || true)"
  printf '%s\n%s' "$status" "$diff" | sha256sum | awk '{print $1}'
}

# --- approve mode ----------------------------------------------------------
# Record the current pending-change fingerprint as "reviewed". Must be run from
# inside a git repo (the shell's cwd). Exit 1 with an error if it is not.
if [ "${1:-}" = "--approve" ]; then
  gitdir="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [ -z "$gitdir" ]; then
    echo "Error: --approve must be run inside a git repository." >&2
    exit 1
  fi
  fp="$(compute_fingerprint)"
  printf '%s' "$fp" > "$gitdir/claude-code-review-approved"
  echo "Recorded code review for pending changes (fingerprint ${fp:0:12})."
  exit 0
fi

# --- hook mode -------------------------------------------------------------
py=""
if command -v python3 >/dev/null 2>&1; then py="python3"
elif command -v python >/dev/null 2>&1; then py="python"
fi
# No interpreter -> can't parse -> fail open.
[ -z "$py" ] && exit 0

# Python does the whole detection job: parse JSON, detect a real `git commit`
# invocation, and print ONLY the cwd when one is found (single line, no cwd ->
# nothing). This mirrors block-main-commit.sh exactly.
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

# cwd must be a real directory we can enter. Fail open otherwise.
[ -d "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# Not a git repo -> fail open.
gitdir="$(git rev-parse --git-dir 2>/dev/null || true)"
[ -z "$gitdir" ] && exit 0

# Merge-commit exception: if a merge is in progress, MERGE_HEAD exists. Use
# rev-parse --git-path so this works in worktrees/submodules too. Merge commits
# do not need the review gate.
mergehead="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
if [ -n "$mergehead" ] && [ -f "$mergehead" ]; then
  exit 0
fi

# Compute the current fingerprint and compare against the recorded marker.
# An empty fingerprint means the hash tooling failed (e.g. sha256sum missing);
# fail open rather than blocking a commit we cannot evaluate.
fp="$(compute_fingerprint)"
[ -z "$fp" ] && exit 0
marker="$gitdir/claude-code-review-approved"
if [ -f "$marker" ]; then
  recorded="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$fp" ] && [ "$recorded" = "$fp" ]; then
    # Review recorded for exactly these pending changes -> allow.
    exit 0
  fi
fi

# No matching review on record -> block.
echo "Blocked: pending changes have not been code-reviewed." >&2
echo "Delegate the review to the code-reviewer subagent and address its findings, then record it with:" >&2
echo "  bash \"\$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh\" --approve   (run in the repo), then retry the commit." >&2
exit 2
