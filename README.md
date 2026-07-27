# claude-setup

My version-controlled Claude Code home directory (`CLAUDE_CONFIG_DIR`).
Everything Claude Code reads to configure itself — instructions, subagents, hooks, permissions —
lives here so it travels with me across machines and evolves like code, with history and review.

## Instruction
Clone this into the `.claude/` directory to use the harness instructions, subagents, and hooks.

## Motivation

The default config dir accumulates config by hand and never leaves the machine it was set up on.
Tracking it in git instead means: one source of truth for how the assistant behaves, changes that
are reviewable and revertible, and a setup that self-updates on every new machine. A `SessionStart`
hook `git pull`s this repo at the start of each session, so the harness is always current.

## Layout

```
AGENTS.md        canonical instructions (the assistant's rules of engagement)
CLAUDE.md        thin @AGENTS.md bridge — Claude Code reads this; edit AGENTS.md, not the bridge
settings.json    permissions, hooks, statusline, enabled plugins
agents/          custom subagents (code-reviewer, explorer, test-runner)
hooks/           shell hooks wired from settings.json (see below)
projects/        per-project session history + memory/ notes (MEMORY.md index → topic files)
plans/           saved plan-mode artifacts
```

## Design principles

- **Portable & versioned.** Config is code: reviewed, committed, synced. `session-start-pull.sh`
  keeps every machine up to date automatically.
- **One canonical instruction file.** Rules live in `AGENTS.md`; each `CLAUDE.md` is a one-line
  `@AGENTS.md` bridge. Ensuring the setup reusabulity in other platforms.
- **Model tiering.** Match the model to the job: `explorer` (haiku) for cheap fan-out search,
  `test-runner` (sonnet) for running suites, `code-reviewer` (opus, high effort) for
  correctness-critical review. The main loop stays on opus for reasoning and implementation.
- **Progressive context disclosure.** Subagents do context-heavy work and return only conclusions
  (`file:line` pointers, findings, pass/fail), keeping the main window lean. The `memory/MEMORY.md`
  index links to topic notes rather than loading everything up front.
- **Safety gates, not vibes.** Hooks enforce the workflow deterministically instead of relying on
  the assistant to remember it.

## How the hooks work

| Hook | Event | What it does |
|------|-------|--------------|
| `session-start-pull.sh` | SessionStart | `git pull --ff-only` this repo; fails open so a stale checkout never blocks startup |
| `block-main-commit.sh` | PreToolUse (Bash) | Blocks `git commit` on `main`/`master` — forces a `feat/ bugfix/ chore/…` branch first |
| `require-code-review.sh` | PreToolUse (Bash) | Blocks `git commit` until a review is recorded for the *exact* pending diff (sha256 fingerprint); any further edit invalidates it |
| `statusline.sh` | statusLine | Shows the active model tier + git branch |

Every hook fails open on error — a broken hook degrades to the default behaviour, it never wedges a session.
