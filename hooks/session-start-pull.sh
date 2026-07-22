#!/usr/bin/env bash
# SessionStart hook. Pulls the latest changes for this config directory
# whenever a Claude Code session begins, so config/hooks/agents stay current
# without a manual `git pull`.
#
# Self-locating: resolves the repo root relative to this script's own path
# rather than a hardcoded absolute path, so the script works unmodified if
# this whole config directory is copied or renamed (~/.claude,
# .claude-personal, .claude-work, etc). Only the `command` path in
# settings.json needs to point at wherever this file actually lives.
#
# Fails open: a stale checkout should never block a session from starting.
# --ff-only avoids merging/rewriting local history if it has diverged.
#
# GIT_TERMINAL_PROMPT=0 and a batch-mode, connect-timeout'd SSH command stop
# a missing ssh-agent passphrase or an unrecognized host key from blocking
# on an interactive prompt — without these, "fails open" wouldn't hold, since
# a hung prompt never reaches the exit-code check below.

set -u

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

output="$(git -C "$REPO_DIR" pull --ff-only 2>&1)"
status=$?

if [ $status -ne 0 ]; then
  echo "session-start-pull: git pull failed in $REPO_DIR, continuing anyway:" >&2
  echo "$output" >&2
  exit 0
fi

if [ "$output" != "Already up to date." ]; then
  echo "session-start-pull: $output"
fi
exit 0
