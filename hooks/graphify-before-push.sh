#!/usr/bin/env bash
# PreToolUse (Bash and PowerShell matcher) hook: refresh the graphify graph before `git push`.
#
# In repos that track graphify-out/ (graph.json committed), the graph must match
# the code being pushed. graphify's own post-commit hook rebuilds in the
# background and never commits, so without this the graph is pushed stale and
# its changes sit in the working tree. This hook runs the rebuild synchronously,
# and if graphify-out/ changed, commits it as ONE `chore(graphify)` commit, then
# lets the push through. It is a Claude hook rather than a git pre-push hook on
# purpose: git resolves the refs to push BEFORE pre-push runs, so a commit made
# there is left behind (verified); a PreToolUse hook runs before the push starts.
#
# Protocol as in block-main-commit.sh: PreToolUse JSON on stdin, exit 2 blocks
# (stderr shown to the model), exit 0 allows. detect-commit-target.py does the
# command parsing and reports one record per `git push`, with the
# repo-redirecting options to replay. Fails OPEN on anything unreadable; blocks
# only when the graph is known to be stale and cannot be committed here.
#
# Registered in settings.json with "onFailure": "block": a timed-out or crashed
# PreToolUse hook otherwise lets the push through with a stale graph. The
# matcher covers PowerShell as well as Bash, since either tool can push.
#
# Known limits, accepted: the rebuild reads the working tree, so uncommitted
# edits leak into the committed graph; the refresh lands on the CURRENT branch
# even for `git push origin <other-branch>`; linked worktrees are not skipped
# the way graphify's own hooks skip them.

set -u

py=""
if command -v python3 >/dev/null 2>&1; then py="python3"
elif command -v python >/dev/null 2>&1; then py="python"
fi
[ -z "$py" ] && exit 0
command -v graphify >/dev/null 2>&1 || exit 0   # no graphify here -> nothing to refresh

# Keep the raw payload: the opt-out below is read from the command text.
payload="$(cat)"
info="$(printf '%s' "$payload" | "$py" "$(dirname "$0")/detect-commit-target.py" push 2>/dev/null)"
[ -z "$info" ] && exit 0
info="${info//$'\r'/}"

# Same opt-out graphify's own hooks honour: `GRAPHIFY_SKIP_HOOK=1 git push` in
# Bash, `$env:GRAPHIFY_SKIP_HOOK = 1; git push` in PowerShell.
printf '%s' "$payload" | grep -Eq "GRAPHIFY_SKIP_HOOK *= *[\\\\\"']*1" && exit 0   # raw JSON: a quote arrives as \"

git_at() { git -C "$cwd" ${git_args[@]+"${git_args[@]}"} "$@" 2>/dev/null; }

while IFS= read -r n; do
  case "$n" in ''|*[!0-9]*) exit 0 ;; esac
  IFS= read -r cwd || exit 0
  [ -z "$cwd" ] && exit 0

  git_args=()
  while [ "${#git_args[@]}" -lt "$n" ]; do
    IFS= read -r arg || exit 0
    git_args+=("$arg")
  done

  gitdir="$(git_at rev-parse --absolute-git-dir || true)"
  [ -z "$gitdir" ] && continue
  [ -f "$gitdir/claude-hooks-exempt" ] && continue
  root="$(git_at rev-parse --show-toplevel || true)"
  [ -z "$root" ] && continue

  # Only repos that track the graph; a gitignored graphify-out/ has nothing to push.
  git -C "$root" ls-files --error-unmatch graphify-out/graph.json >/dev/null 2>&1 || continue

  log="$HOME/.cache/graphify-rebuild.log"
  mkdir -p "$(dirname "$log")"
  # PYTHONHASHSEED pins clustering order so community ids do not churn between
  # runs; MAX_WORKERS=1 mirrors graphify's own Windows hook. --force: a shrink
  # after deleting code is wanted, and the commit below makes a bad rebuild a
  # `git revert` away. The rebuild blocks on graphify's per-repo lock, so a
  # background post-commit rebuild still in flight is waited out, not raced.
  if ! (cd "$root" && PYTHONHASHSEED=0 GRAPHIFY_MAX_WORKERS=1 graphify update --force >>"$log" 2>&1); then
    echo "Blocked: graphify rebuild failed in $root, so the graph would be pushed stale. Last lines of $log:" >&2
    tail -n 15 "$log" >&2
    echo "Fix it, or push without refreshing by setting GRAPHIFY_SKIP_HOOK=1 (Bash: prefix the push; PowerShell: \$env:GRAPHIFY_SKIP_HOOK = 1; git push), then retry." >&2
    exit 2
  fi

  git -C "$root" diff --quiet HEAD -- graphify-out 2>/dev/null && continue   # already fresh

  branch="$(git -C "$root" branch --show-current 2>/dev/null)"
  if [ "$branch" = main ] || [ "$branch" = master ] || [ -z "$branch" ]; then
    echo "Blocked: the graphify graph in $root is stale and this hook will not commit on ${branch:-a detached HEAD} (user's git rules)." >&2
    echo "Commit graphify-out/ from a branch (it needs no review) and merge, or push with GRAPHIFY_SKIP_HOOK=1 set (PowerShell: \$env:GRAPHIFY_SKIP_HOOK = 1; git push), then retry." >&2
    exit 2
  fi

  # Pathspec commit: only graphify-out/; whatever else is staged stays staged
  # for the model's own commit. Runs outside the Bash tool, so the commit gates
  # never see it; the branch guard above is what keeps it within the rules.
  if ! git -C "$root" commit -q -m "chore(graphify): refresh the knowledge graph" -- graphify-out; then
    echo "Blocked: could not commit the refreshed graphify-out/ in $root. Commit it yourself (no review needed) and retry the push." >&2
    exit 2
  fi
done <<< "$info"

exit 0
