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
- This section decides how replies are written. The ponytail plugin decides what gets built; its limits on reply length do not apply.

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
- Review once per finished piece of work, not per edit. When a nontrivial implementation is complete and ready to commit, delegate one review to the `code-reviewer` subagent (fresh context, read-only) and address its findings.
- Trivial changes need no subagent: a few lines of configuration, a rename, a comment, or a one-line fix. Read the diff yourself, then record the approval directly. The same applies to small follow-up edits made in response to review findings.
- `/ponytail-review` is optional for an ad hoc complexity pass. It flips the ponytail mode flag to `review` (machine-wide, not per session), so run `/ponytail full` afterwards.
- Once the review is done, record with `bash "$CLAUDE_CONFIG_DIR/hooks/require-code-review.sh" --approve` (run in the repo). The commit-gate hook blocks `git commit`, one approval covers the whole sequence of atomic commits for those changes. Re-approve only after further edits (including `git add -p` hunk carving, which stages content nobody reviewed).
- Prose-only changes need no review at all. Anything else, including `.gitattributes`, still needs one.
- `graphify-out/` is review-exempt (gate and reviewer). Never commit it by hand unless the push hook tells you to: the hook (`hooks/graphify-before-push.sh`) refreshes and commits the graph right before each push.

# Models & delegation
- These rules hold whichever model and effort level the session runs on. Reserve the main loop for reasoning, design, and planning. Keep single-threaded implementation in the main loop.
- Delegate only for work that is large and genuinely independent. Do not delegate anything you could finish in a handful of tool calls, and do not spawn subagents to double-check your own work beyond the code-review gate above. One subagent beats several; keep spawn counts low.
- For large mechanical / parallel edits, delegate to `Agent` on a cheaper model than the main loop.
- Use the `test-runner` subagent to run suites/linters when the output is likely to be long; run a single quick test or check directly.
- Ponytail rules are injected into every subagent except those listed in `PONYTAIL_SUBAGENT_MATCHER` in `settings.json`; add new read-only agents to that list.

# Vault vs repos
- The personal Obsidian vault at `$PERSONAL_OBSIDIAN_VAULT` owns cross-project and cross-domain knowledge — decisions, lessons, patterns, concepts. Vault writes to individual repos, not the other way around.

# Conventions
- Use British English.
- Prefer `uv` as the Python package manager.
