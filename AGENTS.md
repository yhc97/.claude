# Instruction files
- When creating agent instruction files in any project, write the canonical content in AGENTS.md and add a thin CLAUDE.md bridge next to it containing `@AGENTS.md`. Edit AGENTS.md, never the bridge.

# Git
- Never commit directly to the main branch; create a branch first. If already on a side branch, confirm with user before further branching off.
- Branch names use a helpful prefix: feat/, bugfix/, merge/, chore/.
- Prefer small atomic commits that each describe one change over a single monolithic commit.
- Do not commit data files to git unless the user specifically asked.
- When initializing a new repo (or a repo that lacks one), add a `.gitattributes` file that normalizes line endings across systems (e.g. `* text=auto eol=lf`, with explicit `.bat`/`.cmd`/`.ps1` set to `eol=crlf` where relevant). Do this before the first commit so history doesn't carry mixed line endings.

# Code review
- After each nontrivial implementation, delegate review to the `code-reviewer` subagent (fresh context, read-only) before committing.
- Once the `code-reviewer` subagent completes and its findings are addressed, record the review with `bash "C:/Users/gordo/.claude-personal/hooks/require-code-review.sh" --approve` (run in the repo) — the commit-gate hook blocks `git commit` until this matches the pending changes.
- Whenever a plan is fully implemented, delegate a code review to Codex via the `mcp__codex__codex` MCP tool. Point it at the changes just made and ask it to report findings; address any findings before committing.

# Plugins
- CLAUDE.md files should always only contain `@AGENTS.md` bridges.
- Any CLAUDE.md audit or improvement (claude-md-improver, `/init`) must be applied to the imported AGENTS.md, not the bridge — never expand a bridge.
- When running the session-report skill, always pass `--dir C:\Users\gordo\.claude-personal\projects` as path.

# Python
- Prefer using `uv` as the package manager if possible
