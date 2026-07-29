#!/usr/bin/env bash
# Tests for the code-review commit gate (require-code-review.sh +
# review-manifest.py).
#
# Run:  bash hooks/tests/test-review-gate.sh
#
# The gate has two failure modes and both are silent: block every commit, or
# stop enforcing while still looking like it works. Neither announces itself in
# normal use, which is why this exists.
#
# Every case builds a throwaway repo under a temp dir. Nothing here touches the
# repo the tests live in.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$HOOKS_DIR/require-code-review.sh"
HELPER="$HOOKS_DIR/review-manifest.py"
TMPROOT="${TMPDIR:-/tmp}/review-gate-tests.$$"

# Git Bash on Windows makes `ln -s` COPY unless told otherwise, which would turn
# every symlink case below into a silent false pass. Ignored on POSIX.
export MSYS=winsymlinks:nativestrict

PASS=0
FAIL=0
SKIP=0

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Assert an exit code, naming what was expected in words rather than digits —
# a bare "expected 2" tells you nothing when a test fails months from now.
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s (expected exit %s, got %s)\n' "$label" "$expected" "$actual"
  fi
}

# A fresh repo with one commit: a.py (code) and README.md (prose).
new_repo() {
  local dir="$TMPROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email test@example.com
    git config user.name test
    printf 'original\n' > a.py
    printf 'docs\n' > README.md
    git add -A
    git commit -qm base
  ) >/dev/null 2>&1
  echo "$dir"
}

# An empty repo with no commits, for the unborn-HEAD cases.
new_empty_repo() {
  local dir="$TMPROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q . && git config user.email test@example.com &&
    git config user.name test ) >/dev/null 2>&1
  echo "$dir"
}

# Setup that fails silently produces a test that passes for the wrong reason, so
# a broken setup command is itself a failure rather than a shrug.
in_repo() {
  local dir="$1"; shift
  if ! ( cd "$dir" && "$@" ) >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  setup command failed: %s\n' "$*"
  fi
}

# Drive the gate the way Claude Code does: PreToolUse JSON on stdin. The hook
# reports its verdict as an exit code — 0 allow, 2 block.
run_gate() {
  local dir="$1" command="${2:-git commit -m x}"
  local win
  win="$(cd "$dir" && { pwd -W 2>/dev/null || pwd; })"
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$win" "$command" \
    | bash "$GATE" >/dev/null 2>&1
  echo $?
}

approve() { ( cd "$1" && bash "$GATE" --approve ) >/dev/null 2>&1; }

marker_of() { echo "$1/.git/claude-code-review-approved"; }

mkdir -p "$TMPROOT"

# --- the two behaviours this change exists to deliver ----------------------

echo "one review covers a sequence of atomic commits"
repo="$(new_repo atomic)"
in_repo "$repo" bash -c 'printf x >> a.py; printf x >> b.py; printf x >> c.py'
approve "$repo"
check "commit 1 of 3" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git add a.py && git commit -qm one'
check "commit 2 of 3, no re-approval" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git add b.py && git commit -qm two'
check "commit 3 of 3, no re-approval" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git add c.py && git commit -qm three'
check "sequence complete" 0 "$(run_gate "$repo")"

echo "but the gate still bites on anything unreviewed"
repo="$(new_repo bites)"
in_repo "$repo" bash -c 'printf x >> a.py'
check "unreviewed edit" 2 "$(run_gate "$repo")"
approve "$repo"
check "after approval" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'printf more >> a.py'
check "edited again after approval" 2 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git checkout -q -- a.py; printf new > brand-new.py'
check "new file after approval" 2 "$(run_gate "$repo")"

echo "staging is bookkeeping, not a content change"
repo="$(new_repo staging)"
in_repo "$repo" bash -c 'printf x >> a.py'
approve "$repo"
in_repo "$repo" git add a.py
check "git add must not invalidate the review" 0 "$(run_gate "$repo")"
in_repo "$repo" git reset -q
check "git reset must not invalidate it either" 0 "$(run_gate "$repo")"

echo "docs-only changes need no review"
repo="$(new_repo docs)"
in_repo "$repo" bash -c 'printf x >> README.md'
check "prose alone" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'printf x >> a.py'
check "prose mixed with code" 2 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git checkout -q -- .'

repo="$(new_repo docs_compose)"
in_repo "$repo" bash -c 'printf x >> a.py'
approve "$repo"
in_repo "$repo" bash -c 'printf x >> README.md'
check "reviewed code plus an unreviewed doc tweak" 0 "$(run_gate "$repo")"

repo="$(new_repo docs_scope)"
in_repo "$repo" bash -c 'mkdir -p docs && printf x > docs/conf.py'
check "location never exempts: docs/conf.py" 2 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'rm -rf docs; printf x > .gitattributes'
check ".gitattributes is not exempt (it changes every other oid)" 2 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'rm -f .gitattributes; printf x > NOTES.MD'
check "basename match is case-folded: NOTES.MD" 0 "$(run_gate "$repo")"

# --- edge cases in the manifest -------------------------------------------

echo "manifest edge cases"
repo="$(new_repo rename)"
in_repo "$repo" git mv a.py renamed.py
check "a rename is unreviewed on both sides" 2 "$(run_gate "$repo")"
approve "$repo"
check "and is fine once reviewed" 0 "$(run_gate "$repo")"

repo="$(new_empty_repo unborn)"
in_repo "$repo" bash -c 'printf x > a.py'
check "unborn HEAD, unreviewed" 2 "$(run_gate "$repo")"
approve "$repo"
check "unborn HEAD, reviewed" 0 "$(run_gate "$repo")"

repo="$(new_repo weird_paths)"
in_repo "$repo" bash -c "printf x > 'my file ünïcode.py'"
check "spaces and non-ASCII, unreviewed" 2 "$(run_gate "$repo")"
approve "$repo"
check "spaces and non-ASCII, reviewed" 0 "$(run_gate "$repo")"

# Both an untracked and a TRACKED-then-modified file, because only the tracked
# one reaches `git hash-object --stdin-paths`. Status reports repo-root-relative
# paths while the approve-mode subprocess inherits the caller's subdirectory, so
# this pins that hash-object resolves its inputs against the repo root.
repo="$(new_repo subdir)"
in_repo "$repo" bash -c 'mkdir -p sub/deep && printf x > sub/deep/tracked.py &&
                         git add -A && git commit -qm sub'
in_repo "$repo" bash -c 'printf more >> sub/deep/tracked.py'
( cd "$repo/sub/deep" && bash "$GATE" --approve ) >/dev/null 2>&1
check "approving a modified tracked file from a subdirectory" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'printf untracked > sub/deep/new.py'
( cd "$repo/sub" && bash "$GATE" --approve ) >/dev/null 2>&1
check "approving an untracked file from a subdirectory" 0 "$(run_gate "$repo")"

# An empty pending set is allowed only with a marker. The hook sees the tree
# BEFORE the command runs, so a clean tree is exactly what a compound
# write-then-commit looks like from here; allowing it unconditionally would let
# content authored inside the Bash tool commit with no review at all.
repo="$(new_repo clean)"
check "nothing pending, no marker" 2 "$(run_gate "$repo")"
check "compound write-then-commit from a clean tree" 2 \
  "$(run_gate "$repo" "printf evil > new.py && git add -A && git commit -m x")"
in_repo "$repo" bash -c 'printf x >> a.py'
approve "$repo"
in_repo "$repo" bash -c 'git add -A && git commit -qm landed'
check "--amend inside an approved sequence" 0 "$(run_gate "$repo" "git commit --amend --no-edit")"

echo "the prose exemption must not cover code"
repo="$(new_repo prose_vs_code)"
for f in licence_check.sh copying_utils.c requirements.txt CMakeLists.txt; do
  in_repo "$repo" bash -c "printf x > '$f'"
  check "$f is not prose" 2 "$(run_gate "$repo")"
  in_repo "$repo" bash -c "rm -f '$f'"
done
for f in LICENCE LICENSE.md COPYING.txt CHANGELOG.md; do
  in_repo "$repo" bash -c "printf x > '$f'"
  check "$f is prose" 0 "$(run_gate "$repo")"
  in_repo "$repo" bash -c "rm -f '$f'"
done

# With no index entry the mode is unknowable, and guessing made an executable
# file block after `git reset` re-labelled an identical blob — while the block
# message tells the model not to re-approve. Both file modes must satisfy it.
echo "an executable file survives staging round-trips"
repo="$(new_repo exec_mode)"
in_repo "$repo" bash -c 'printf "#!/bin/sh\necho hi\n" > run.sh &&
                         git add run.sh && git update-index --chmod=+x run.sh'
approve "$repo"
check "approved while staged executable" 0 "$(run_gate "$repo")"
in_repo "$repo" git reset -q
check "still approved after git reset drops the index entry" 0 "$(run_gate "$repo")"
in_repo "$repo" git add run.sh
check "still approved once re-staged" 0 "$(run_gate "$repo")"
in_repo "$repo" bash -c 'git update-index --chmod=-x run.sh'
check "flipping the exec bit alone is not a content change" 0 "$(run_gate "$repo")"

# Git stores a symlink as a blob holding the target string, so a regular file
# and a symlink whose target equals its contents are the SAME blob and differ
# only in mode. Without a type tag in the identity a reviewed file could be
# swapped for a symlink to anywhere and the gate would allow it — verified as a
# live bypass, which is why these two cases exist. Skipped where the filesystem
# will not make a native symlink (Windows without Developer Mode).
if ( cd "$TMPROOT" && ln -s target probe ) >/dev/null 2>&1 && [ -L "$TMPROOT/probe" ]; then
  rm -f "$TMPROOT/probe"
  echo "a type change is a change, even at an identical blob"
  repo="$(new_repo typechange)"
  # No separator in the target: on Windows os.readlink would rewrite "a/b" to
  # "a\b" and the oids would differ for the wrong reason, hiding the real test.
  in_repo "$repo" bash -c 'printf prod.env > loader.py'
  approve "$repo"
  check "reviewed regular file" 0 "$(run_gate "$repo")"
  in_repo "$repo" bash -c 'rm loader.py && ln -s prod.env loader.py'
  check "file swapped for a symlink at the same oid" 2 "$(run_gate "$repo")"
  approve "$repo"
  check "reviewed symlink" 0 "$(run_gate "$repo")"
  in_repo "$repo" bash -c 'rm loader.py && printf prod.env > loader.py'
  check "symlink swapped back for a file at the same oid" 2 "$(run_gate "$repo")"

  echo "but an unchanged symlink still stages freely"
  repo="$(new_repo symlink_staging)"
  in_repo "$repo" bash -c 'ln -s prod.env conf'
  approve "$repo"
  in_repo "$repo" git add conf
  check "staging a reviewed symlink does not re-block" 0 "$(run_gate "$repo")"
  in_repo "$repo" git reset -q
  check "unstaging it does not either" 0 "$(run_gate "$repo")"

  # Windows os.readlink returns 'd\target' where git stores the blob 'd/target',
  # so the identity was the sha of the wrong bytes and staging false-blocked.
  # The typechange cases above deliberately use a separator-free target; this one
  # exists so that choice hides nothing.
  echo "a symlink target containing a separator"
  repo="$(new_repo symlink_sep)"
  in_repo "$repo" bash -c 'mkdir -p dd && printf x > dd/target && ln -s dd/target link'
  approve "$repo"
  check "reviewed link into a subdirectory" 0 "$(run_gate "$repo")"
  in_repo "$repo" git add link
  check "staging it must not re-block" 0 "$(run_gate "$repo")"
else
  rm -f "$TMPROOT/probe"
  # Counted, not just printed. A silent skip means a box without Developer Mode
  # reports all-green while the bypass cases never ran at all.
  SKIP=$((SKIP + 8))
  echo "a type change is a change (SKIPPED: no native symlinks on this host)"
fi

# The regression that the type tag introduced, and the reason the worktree side
# cannot simply trust islink. With core.symlinks off — the Windows default — git
# checks a 120000 entry out as a PLAIN FILE holding the target text, yet still
# stores mode 120000 on `git add`. Tagging from the filesystem made an ordinary
# `git add` of reviewed content block.
#
# The committed symlink is built with update-index --cacheinfo rather than ln -s
# so this runs everywhere, including hosts that cannot create a native link —
# which is exactly where the bug lives.
echo "a checked-out symlink that the filesystem cannot represent"
symsrc="$TMPROOT/symsrc"; symdst="$TMPROOT/symdst"
rm -rf "$symsrc" "$symdst"; mkdir -p "$symsrc"
(
  cd "$symsrc" && git init -q . &&
  git config user.email test@example.com && git config user.name test &&
  printf 'real\n' > real.txt &&
  oid="$(printf 'real.txt' | git hash-object -w --stdin)" &&
  git update-index --add --cacheinfo "120000,$oid,conf" &&
  git add real.txt && git commit -qm base
) >/dev/null 2>&1
git -c core.symlinks=false clone -q "$symsrc" "$symdst" >/dev/null 2>&1
in_repo "$symdst" git config user.email test@example.com
in_repo "$symdst" git config user.name test
in_repo "$symdst" git config core.symlinks false
check "the checkout really is a plain file, not a link" \
  "plain" "$([ -L "$symdst/conf" ] && echo link || echo plain)"
in_repo "$symdst" bash -c 'printf other.env > conf'
approve "$symdst"
check "reviewed placeholder" 0 "$(run_gate "$symdst")"
in_repo "$symdst" git add conf
check "staging it must not re-block" 0 "$(run_gate "$symdst")"
in_repo "$symdst" bash -c 'printf changed-again > conf'
check "but a real edit still blocks" 2 "$(run_gate "$symdst")"

# A symlink's identity has to be git's own 120000:<oid>, not a shape of our
# own. If it were not comparable with what the index reports, approving a
# symlink change and then staging it would block with no way out but
# re-approving after every `git add`. Symlinks usually cannot be created on
# Windows, so drive the derivation directly, with os.readlink monkeypatched.
#
# This no longer proves the oid is right — the function asks git for it, so
# comparing the two would be git against itself. What it still pins is the
# plumbing either side of that call: the separator rewrite below, and the fact
# that a link yields an oid at all rather than ABSENT or a traceback.
symlink_probe() {
  "$(command -v python3 || command -v python)" - "$HELPER" "$1" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("review_manifest", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
os.readlink = lambda _path: sys.argv[2]
print(mod.symlink_identity([], "irrelevant"))
PY
}
git_oid="$(printf 'reviewed-new-target' | git hash-object --stdin)"
check "a symlink identity matches git's own blob oid" \
  "$git_oid" "$(symlink_probe 'reviewed-new-target')"

# Windows hands back 'd\target' where git hashes the blob 'd/target'. The
# separator-containing end-to-end case above only runs where native symlinks
# exist, so pin the normalisation here too. Skipped on POSIX, where a backslash
# is a legal filename character and rewriting it would corrupt the oid.
pysep="$("$(command -v python3 || command -v python)" -c 'import os; print(os.sep)')"
if [ "$pysep" != "/" ]; then
  git_oid="$(printf 'dd/target' | git hash-object --stdin)"
  check "a Windows-style separator is normalised before hashing" \
    "$git_oid" "$(symlink_probe "dd${pysep}target")"
else
  git_oid="$(printf 'dd\\target' | git hash-object --stdin)"
  check "a backslash is left alone where it is a legal filename character" \
    "$git_oid" "$(symlink_probe 'dd\target')"
fi

# Git supports sha256 repositories, where a blob oid is not a sha1 at all. The
# oid used to be hand-rolled with hashlib.sha1, so approving an unstaged symlink
# there recorded a sha1 while `git add` produced a sha256 — a false block on the
# most ordinary action. Asking git for the oid is what makes this format-blind.
if git init -q --object-format=sha256 "$TMPROOT/probe256" >/dev/null 2>&1; then
  rm -rf "$TMPROOT/probe256"
  echo "a sha256 repository"
  s256="$TMPROOT/sha256repo"; rm -rf "$s256"
  git init -q --object-format=sha256 "$s256" >/dev/null 2>&1
  in_repo "$s256" git config user.email test@example.com
  in_repo "$s256" git config user.name test
  in_repo "$s256" bash -c 'printf seed > seed.txt && git add -A && git commit -qm base'
  check "the repo really is sha256" "sha256" \
    "$(cd "$s256" && git rev-parse --show-object-format)"
  # cacheinfo rather than ln -s, so this runs without native symlink support.
  in_repo "$s256" bash -c 'oid="$(printf prod.env | git hash-object -w --stdin)" &&
                           git update-index --add --cacheinfo "120000,$oid,conf" &&
                           git commit -qm link'
  in_repo "$s256" bash -c 'printf other.env > conf'
  approve "$s256"
  check "reviewed symlink in a sha256 repo" 0 "$(run_gate "$s256")"
  in_repo "$s256" git add conf
  check "staging it must not re-block" 0 "$(run_gate "$s256")"
else
  rm -rf "$TMPROOT/probe256"
  SKIP=$((SKIP + 3))
  echo "a sha256 repository (SKIPPED: this git cannot create one)"
fi

repo="$(new_repo redirect)"
other="$(new_repo redirect_other)"
in_repo "$other" bash -c 'printf x >> a.py'
check "git -C <other> commit is gated against <other>" 2 \
  "$(run_gate "$repo" "git -C $(cd "$other" && { pwd -W 2>/dev/null || pwd; }) commit -m x")"

# --- marker validity -------------------------------------------------------

echo "marker validity"
repo="$(new_repo marker)"
in_repo "$repo" bash -c 'printf x >> a.py'
approve "$repo"
marker="$(marker_of "$repo")"

printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' > "$marker"
check "legacy v1 digest counts as no approval" 2 "$(run_gate "$repo")"
printf '{"version":2,"appro' > "$marker"
check "corrupt JSON counts as no approval" 2 "$(run_gate "$repo")"
printf '{"version":1,"approved":{}}' > "$marker"
check "wrong version counts as no approval" 2 "$(run_gate "$repo")"
# v2 is the version actually in the wild: its entries are bare oids that can no
# longer match a `<type>:<oid>` identity, so it must read as "no approval" and
# cost one re-approval, not mismatch silently and forever.
printf '{"version":2,"created_at":%d,"approved":{"a.py":["%s"]}}' \
  "$(date +%s)" "$(in_repo_oid="$(cd "$repo" && git hash-object a.py)"; echo "$in_repo_oid")" > "$marker"
check "a v2 marker's bare oids count as no approval" 2 "$(run_gate "$repo")"

approve "$repo"
python_bin="$(command -v python3 || command -v python)"
"$python_bin" - "$marker" <<'PY'
import json, sys, time
path = sys.argv[1]
data = json.load(open(path))
data["created_at"] = int(time.time()) - 8 * 24 * 3600
json.dump(data, open(path, "w"))
PY
check "a marker older than the TTL expires" 2 "$(run_gate "$repo")"

# --- fail open -------------------------------------------------------------
# The invariant: a gate that cannot evaluate must never block. A wedged commit
# gate is worse than an unenforced one, because it cannot be worked around.

echo "fail open on everything unevaluable"
repo="$(new_repo failopen)"
in_repo "$repo" bash -c 'printf x >> a.py'
check "sanity: this repo does block" 2 "$(run_gate "$repo")"

win="$(cd "$repo" && { pwd -W 2>/dev/null || pwd; })"
payload="$(printf '{"cwd":"%s","tool_input":{"command":"git commit -m x"}}' "$win")"

echo "$payload" | env PATH="/usr/bin:/bin" bash "$GATE" >/dev/null 2>&1
check "no python interpreter" 0 $?

printf '{"cwd":"/no/such/dir","tool_input":{"command":"git commit -m x"}}' \
  | bash "$GATE" >/dev/null 2>&1
check "not a git repository" 0 $?

printf 'not json at all' | bash "$GATE" >/dev/null 2>&1
check "malformed stdin" 0 $?

printf '' | bash "$GATE" >/dev/null 2>&1
check "empty stdin" 0 $?

check "a command that is not a commit" 0 "$(run_gate "$repo" "git status")"

# A helper that dies must fail open. Its exit code is the verdict, and the
# codes are chosen so that Python's exit-1-on-exception cannot read as a block.
cp "$HELPER" "$TMPROOT/helper.bak"
printf 'raise RuntimeError("boom")\n' > "$HELPER"
echo "$payload" | bash "$GATE" >/dev/null 2>&1
check "helper crashes with a traceback" 0 $?
cp "$TMPROOT/helper.bak" "$HELPER"
check "sanity: blocking resumes once the helper is restored" 2 "$(run_gate "$repo")"

echo "escape hatches"
touch "$repo/.git/claude-hooks-exempt"
check "per-repo claude-hooks-exempt" 0 "$(run_gate "$repo")"
rm -f "$repo/.git/claude-hooks-exempt"
touch "$repo/.git/MERGE_HEAD"
check "merge in progress" 0 "$(run_gate "$repo")"
rm -f "$repo/.git/MERGE_HEAD"

if [ "$SKIP" -gt 0 ]; then
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
else
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
