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
# command structure anyway, so ALL parsing + commit-detection happens in
# detect-commit-target.py (shared with require-code-review.sh — see that file
# for the output format). It reports one record per `git commit` in the command:
# the cwd plus the repo-redirecting git global options (-C / --git-dir /
# --work-tree) that commit used. Replaying those options is what makes
# `git -C <other-repo> commit` get guarded against <other-repo> rather than
# against the session cwd. Bash just acts on that verdict. If no python is
# available, JSON parsing fails, or anything else goes wrong, we FAIL OPEN.

set -u

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
# to parse it, and return nothing — leaving the branch empty and the guard
# failing open on exactly the redirected commits it exists to catch.
info="${info//$'\r'/}"

# Run git the way the guarded command would: from the tool cwd, with the same
# repo-redirecting options after it. git applies -C options cumulatively, so a
# relative `-C ../foo` still resolves against the cwd. Any failure (missing
# dir, not a repo) yields empty output and we fail open.
git_at() { git -C "$cwd" ${git_args[@]+"${git_args[@]}"} "$@" 2>/dev/null; }

# Records are counted, not delimited: an option count, the cwd, then exactly
# that many option tokens. Every command in a compound line gets its own
# record, and ANY of them landing on main is enough to block.
while IFS= read -r n; do
  case "$n" in ''|*[!0-9]*) exit 0 ;; esac  # malformed -> fail open
  IFS= read -r cwd || exit 0
  [ -z "$cwd" ] && exit 0

  git_args=()
  while [ "${#git_args[@]}" -lt "$n" ]; do
    IFS= read -r arg || exit 0
    git_args+=("$arg")
  done

  # Per-repo exemption. A repo opts out of the commit gates by placing an empty
  # file at .git/claude-hooks-exempt — used for the personal Obsidian vault,
  # where branch discipline and code review are meaningless (no remote, no
  # branches, no collaborators, prose not code). The marker lives inside .git
  # so it is never committed and never synced, and it affects no other repo.
  gitdir="$(git_at rev-parse --absolute-git-dir || true)"
  if [ -n "$gitdir" ] && [ -f "$gitdir/claude-hooks-exempt" ]; then
    continue
  fi

  # Determine the current branch in the target repo. Fail open on any error:
  # missing dir, not a repo, or detached HEAD all yield "".
  branch="$(git_at branch --show-current || true)"

  if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    # Name the repo: the commit being blocked is not necessarily the one in the
    # session cwd, and "create a branch" is unactionable without knowing where.
    target="$(git_at rev-parse --show-toplevel || true)"
    [ -z "$target" ] && target="$gitdir"
    echo "Blocked: committing directly to $branch in $target violates the user's git rules. Create a branch there first (feat/, bugfix/, merge/, chore/)." >&2
    exit 2
  fi
done <<< "$info"

exit 0
