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
# command structure anyway, so ALL parsing + commit-detection happens in
# detect-commit-target.py, shared with block-main-commit.sh. It reports one
# record per `git commit` found, naming the repo that commit actually targets —
# which is not the cwd when the command uses -C / --git-dir / --work-tree.

set -u

# How we invoke git. Approve mode runs in the shell's own repo, so plain `git`.
# Hook mode replaces this with the tool cwd plus the same repo-redirecting
# global options the guarded command used, so `git -C <other-repo> commit` is
# gated against <other-repo> and not against the cwd.
GIT_CMD=(git)

# --- shared fingerprint of the pending changes -----------------------------
# CRITICAL: hook mode and approve mode MUST compute this identically, so both
# call this one function. Both `git status --porcelain` and `git diff HEAD`
# report the whole repo with repo-root-relative paths, so the answer does not
# depend on which directory inside the repo we are standing in — except that
# diff.relative would scope the diff to the cwd, so it is pinned off.
# Fingerprint = sha256 of `git status --porcelain` output concatenated with
# `git diff HEAD` output. `git diff HEAD` fails in a repo with no commits yet —
# that is tolerated and treated as empty output (we do NOT fail closed).
compute_fingerprint() {
  local status diff
  # A failed status is indistinguishable from a clean tree once captured, so
  # check it: an unreadable index or worktree must print nothing, which every
  # caller reads as "cannot evaluate" and fails open. Hashing the empty output
  # instead would produce a confident mismatch and block.
  # -uall, not the default -unormal: the default collapses a whole untracked
  # directory into one `?? dir/` entry, so files added inside it after the
  # review would not change the fingerprint at all.
  if ! status="$("${GIT_CMD[@]}" status --porcelain -uall 2>/dev/null)"; then
    return 0
  fi
  diff="$("${GIT_CMD[@]}" -c diff.relative=false diff HEAD 2>/dev/null || true)"
  printf '%s\n%s' "$status" "$diff" | sha256sum | awk '{print $1}'
}

# --- approve mode ----------------------------------------------------------
# Record the current pending-change fingerprint as "reviewed". Must be run from
# inside a git repo (the shell's cwd). Exit 1 with an error if it is not.
if [ "${1:-}" = "--approve" ]; then
  # --absolute-git-dir, not --git-dir: the latter is relative to the cwd, so
  # approving from a subdirectory wrote the marker to <subdir>/.git/... and the
  # gate never saw it.
  gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -z "$gitdir" ]; then
    echo "Error: --approve must be run inside a git repository." >&2
    exit 1
  fi
  fp="$(compute_fingerprint)"
  if [ -z "$fp" ] || ! printf '%s' "$fp" > "$gitdir/claude-code-review-approved"; then
    echo "Error: could not record the review marker in $gitdir." >&2
    exit 1
  fi
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

# A missing/unreadable helper prints nothing, which is our fail-open signal.
info="$("$py" "$(dirname "$0")/detect-commit-target.py" 2>/dev/null)"

# Empty -> not a git commit (or nothing we can act on) -> nothing to guard.
[ -z "$info" ] && exit 0

# Strip CRs once, on the whole payload. Python's stdout is in text mode on
# Windows, so the newlines it writes arrive as CRLF and every field would end
# up with a trailing CR. Git would then be handed an option like $'-C\r', fail
# to parse it, and return nothing — leaving the git dir empty and the gate
# skipping exactly the redirected commits it exists to catch.
info="${info//$'\r'/}"

# Records are counted, not delimited: an option count, the cwd, then exactly
# that many option tokens. Every commit in a compound command gets its own
# record, and ANY unreviewed one is enough to block.
while IFS= read -r n; do
  case "$n" in ''|*[!0-9]*) exit 0 ;; esac  # malformed -> fail open
  IFS= read -r cwd || exit 0
  [ -z "$cwd" ] && exit 0

  git_args=()
  while [ "${#git_args[@]}" -lt "$n" ]; do
    IFS= read -r arg || exit 0
    git_args+=("$arg")
  done

  # Run git the way the guarded command would: from the tool cwd, with the same
  # repo-redirecting options after it. git applies -C options cumulatively, so
  # a relative `-C ../foo` still resolves against the cwd.
  GIT_CMD=(git -C "$cwd" ${git_args[@]+"${git_args[@]}"})

  # Not a git repo (or unreadable) -> fail open. --absolute-git-dir because the
  # marker paths below are used from an unrelated working directory.
  gitdir="$("${GIT_CMD[@]}" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -z "$gitdir" ] && continue

  # Per-repo exemption (mirrors block-main-commit.sh). A repo opts out of the
  # commit gates by placing an empty file at .git/claude-hooks-exempt — used for
  # the personal Obsidian vault, where "delegate to the code-reviewer subagent"
  # is meaningless for prose. The marker lives inside .git so it is never
  # committed and never synced, and it affects no other repo.
  [ -f "$gitdir/claude-hooks-exempt" ] && continue

  # Merge-commit exception: if a merge is in progress, MERGE_HEAD exists. It is
  # a per-worktree file, so it lives in the resolved git dir (which for a linked
  # worktree is .git/worktrees/<name>) — no extra path lookup needed. Merge
  # commits do not need the review gate.
  [ -f "$gitdir/MERGE_HEAD" ] && continue

  # Compute the current fingerprint and compare against the recorded marker.
  # An empty fingerprint means the hash tooling failed (e.g. sha256sum missing);
  # fail open rather than blocking a commit we cannot evaluate.
  fp="$(compute_fingerprint)"
  [ -z "$fp" ] && continue
  marker="$gitdir/claude-code-review-approved"
  if [ -f "$marker" ]; then
    recorded="$(cat "$marker" 2>/dev/null || true)"
    if [ "$recorded" = "$fp" ]; then
      # Review recorded for exactly these pending changes -> allow.
      continue
    fi
  fi

  # No matching review on record -> block. Name the repo: the commit being
  # blocked is not necessarily the one in the session cwd, and approving in the
  # wrong repo records a marker that can never satisfy this gate.
  target="$("${GIT_CMD[@]}" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -z "$target" ] && target="$gitdir"
  echo "Blocked: pending changes in $target have not been code-reviewed." >&2
  echo "Delegate the review to the code-reviewer subagent and address its findings, then record it with:" >&2
  echo "  bash \"\$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh\" --approve   (run inside $target), then retry the commit." >&2
  exit 2
done <<< "$info"

exit 0
