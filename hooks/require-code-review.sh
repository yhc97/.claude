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
#
# What counts as "reviewed" is decided by review-manifest.py, shared between the
# two modes here. It records the content identity of every pending path and
# allows a commit while everything still pending is content a reviewer has
# already seen. Two consequences that are the whole point of it:
#   * one review covers a whole sequence of atomic commits, because committing
#     part of the reviewed work leaves the rest still reviewed;
#   * a commit touching only prose skips the gate, because an opus code review
#     of a README is a waste of a review.
# Its exit code is the verdict — 0 allow, 10 block, anything else means it could
# not tell and we fail open.

set -u

REVIEW_EXIT_ALLOW=0
REVIEW_EXIT_BLOCK=10

# Locate the python interpreter, or "" if there is none. Without one the gate
# cannot evaluate anything and both modes degrade to no-ops.
find_python() {
  if command -v python3 >/dev/null 2>&1; then echo "python3"
  elif command -v python >/dev/null 2>&1; then echo "python"
  fi
}

MANIFEST_HELPER="$(dirname "$0")/review-manifest.py"

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

  py="$(find_python)"
  # Hook mode already fails open without an interpreter, so the gate cannot
  # block on this machine either way. Erroring here would stall the caller over
  # a marker that was never going to be consulted; say so and carry on.
  if [ -z "$py" ]; then
    echo "Note: no python interpreter found, so the code-review gate is inactive here. Nothing recorded."
    exit 0
  fi

  if ! count="$("$py" "$MANIFEST_HELPER" record --marker "$gitdir/claude-code-review-approved" 2>&1)"; then
    echo "Error: could not record the review marker in $gitdir." >&2
    [ -n "$count" ] && echo "$count" >&2
    exit 1
  fi
  echo "Recorded code review covering ${count%%$'\n'*} pending path(s)."
  echo "This covers the whole sequence of atomic commits for these changes — no need to re-approve between them."
  exit 0
fi

# --- hook mode -------------------------------------------------------------
py="$(find_python)"
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
  GIT_PREFIX=(-C "$cwd" ${git_args[@]+"${git_args[@]}"})
  GIT_CMD=(git "${GIT_PREFIX[@]}")

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

  # Ask the shared helper whether everything pending is content a review has
  # already covered. The verdict is its EXIT CODE, so a crash (any other code)
  # can never be mistaken for either answer and simply fails open.
  unapproved="$("$py" "$MANIFEST_HELPER" check \
    --marker "$gitdir/claude-code-review-approved" -- "${GIT_PREFIX[@]}" 2>/dev/null)"
  verdict=$?
  [ "$verdict" -eq "$REVIEW_EXIT_ALLOW" ] && continue
  [ "$verdict" -ne "$REVIEW_EXIT_BLOCK" ] && continue   # cannot evaluate -> fail open

  # No review on record for this content -> block. Name the repo: the commit
  # being blocked is not necessarily the one in the session cwd, and approving
  # in the wrong repo records a marker that can never satisfy this gate.
  target="$("${GIT_CMD[@]}" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -z "$target" ] && target="$gitdir"
  echo "Blocked: these paths in $target have changes no code review has covered:" >&2
  echo "$unapproved" | sed 's/^/  /' >&2
  echo "Delegate the review to the code-reviewer subagent and address its findings, then record it with:" >&2
  echo "  bash \"\$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh\" --approve   (run inside $target), then retry the commit." >&2
  echo "One approval covers a whole sequence of atomic commits, so do NOT re-approve between them — only after further edits." >&2
  echo "Carving hunks with 'git add -p' does need a fresh approval: the partial content staged is not what was reviewed." >&2
  exit 2
done <<< "$info"

exit 0
