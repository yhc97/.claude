# Instruction files
- When creating agent instruction files in any project, write the canonical content in AGENTS.md and add a thin CLAUDE.md bridge next to it containing `@AGENTS.md`. Edit AGENTS.md, never the bridge — including audits from claude-md-improver or `/init`.
- Keep AGENTS.md lean; if a section grows past ~40 lines, extract the detail into a referenced file and leave a one-line pointer here.
- When running the session-report skill, always pass `--dir "$CLAUDE_CONFIG_DIR/projects"` as path.

# Communication style
- Readable beats concise. Drop details that would not change what I do next.
- Spell out technical terms, no arrow chains (`A → B → fails`), no hyphen-stacked compounds, and no shorthand or labels invented earlier in the session that I would have to decode.
- Lead with the outcome. The first sentence answers "what happened" or "what did you find"; supporting detail comes after.
- State claims directly rather than building towards a turn of phrase.
- Before the first tool call, say in one sentence what you are about to do. While working, give a brief update only on finding something important or changing direction.
- Match the length of written documents to what the task needs: cover the substance without padding with filler sections, redundant summaries, or boilerplate.

# Git
- Never commit directly to the main branch; create a branch first. If already on a side branch, confirm with user before further branching off.
- Branch names use a helpful prefix: feat/, bugfix/, merge/, docs/, chore/.
- Prefer small atomic commits that each describe one change over a single monolithic commit.
- Do not commit data files to git unless the user specifically asked.
- When initialising a new repo (or a repo that lacks one), add a `.gitattributes` file that normalises line endings across systems (e.g. `* text=auto eol=lf`, with explicit `.bat`/`.cmd`/`.ps1` set to `eol=crlf` where relevant).

# Shell commands
- Never combine `cd` with a write in a single Bash call.
- Avoid chaining shell commands unless the data piping is needed.

# Code review
- After each nontrivial implementation, delegate review to the `code-reviewer` subagent (fresh context, read-only) before committing; address its findings.
- `/ponytail-review` is optional for an ad hoc complexity pass. It flips the ponytail mode flag to `review` (machine-wide, not per session), so run `/ponytail full` afterwards.
- Once the `code-reviewer` subagent completes and its findings are addressed, record the review with `bash "$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh" --approve` (run in the repo). The commit-gate hook blocks `git commit`, one approval covers the whole sequence of atomic commits for those changes. Re-approve only after further edits (including `git add -p` hunk carving, which stages content nobody reviewed).
- Prose-only changes need no review at all. Anything else, including `.gitattributes`, still needs one.
- Escalate to a Codex second opinion (`mcp__codex__codex`) when the change is high-stakes: a full-plan implementation, a diff touching core logic or many files, or security-sensitive code.

# Models & delegation
- Reserve the main loop (opus or fable) for reasoning, design, and planning. Keep single-threaded implementation in the main loop.
- Delegate only for work that is large and genuinely independent. Do not delegate anything you could finish in a handful of tool calls, and do not spawn subagents to double-check your own work beyond the code-review gate above. One subagent beats several; keep spawn counts low.
- For large mechanical / parallel edits, delegate to `Agent` with `model: sonnet`.
- Offload fan-out search / "where does X live" to the `explorer` subagent; use `model: sonnet` if the search is ambiguous.
- Use the `test-runner` subagent to run suites/linters.
- The ponytail ruleset is injected into subagents that write code only specified in `settings.json`; add new read-only agents there.

# Vault vs repos
- The personal Obsidian vault at `$PERSONAL_OBSIDIAN_VAULT` owns cross-project and cross-domain knowledge — decisions, lessons, patterns, concepts. Vault writes to individual repos, not the other way around.

# Conventions
- Use British English.
- Prefer `uv` as the Python package manager.

<tone_preference>
Readable over concise, outcome first. See Communication style above.
</tone_preference>
