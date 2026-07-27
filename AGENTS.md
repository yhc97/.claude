# Instruction files
- When creating agent instruction files in any project, write the canonical content in AGENTS.md and add a thin CLAUDE.md bridge next to it containing `@AGENTS.md`. Edit AGENTS.md, never the bridge.

# Git
- Never commit directly to the main branch; create a branch first. If already on a side branch, confirm with user before further branching off.
- Branch names use a helpful prefix: feat/, bugfix/, merge/, docs/, chore/.
- Prefer small atomic commits that each describe one change over a single monolithic commit.
- Do not commit data files to git unless the user specifically asked.
- When initialising a new repo (or a repo that lacks one), add a `.gitattributes` file that normalizes line endings across systems (e.g. `* text=auto eol=lf`, with explicit `.bat`/`.cmd`/`.ps1` set to `eol=crlf` where relevant). Do this before the first commit so history doesn't carry mixed line endings.

# Code review
- After each nontrivial implementation, delegate review to the `code-reviewer` subagent (fresh context, read-only) before committing; address its findings.
- Once the `code-reviewer` subagent completes and its findings are addressed, record the review with `bash "$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh" --approve` (run in the repo) — the commit-gate hook blocks `git commit` until this matches the pending changes.
- Escalate to a Codex second opinion (`mcp__codex__codex`) when the change is high-stakes: a full-plan implementation, a diff touching core logic or many files, or security-sensitive code. Point it at the changes and address any findings before committing. Skip Codex for small/routine changes — the subagent plus the commit gate already cover those.

# Plugins
- CLAUDE.md files should always only contain `@AGENTS.md` bridges.
- Any CLAUDE.md audit or improvement (claude-md-improver, `/init`) must be applied to the imported AGENTS.md, not the bridge.
- When running the session-report skill, always pass `--dir C:\Users\gordo\.claude-personal\projects` as path.

# Models & delegation
- Reserve the main loop (opus) for reasoning, design, and implementation.
- For large mechanical / parallel edits (codemods, bulk migrations across many files), delegate to `Agent` with `model: sonnet` (plus worktree isolation) or a Workflow — not for ordinary single-threaded implementation, which stays in the main loop.
- Offload fan-out search / "where does X live" to the `explorer` subagent (haiku) — it keeps large reads out of the main context and returns `file:line` pointers.
- Use the `test-runner` subagent (sonnet) to run suites/linters so verbose logs stay out of the main context.
- Prefer `explorer` for cheap search; when reaching for the built-in Explore / general-purpose agents instead, pass `model: haiku` (or `sonnet` when the search is ambiguous).
- Reserve opus for adversarial / correctness-critical work: `code-reviewer`, Codex, architecture review.
- Keep AGENTS.md lean; if a section grows past ~40 lines, extract the detail into a referenced file and leave a one-line pointer here.

# Python
- Prefer using `uv` as the package manager if possible

# Language
- Use British English
