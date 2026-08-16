#!/usr/bin/env bash
# UserPromptSubmit hook. Emits a one-line pointer back at the Communication
# style section of AGENTS.md on every turn.
#
# Why a hook rather than relying on AGENTS.md alone: AGENTS.md is loaded once,
# at the top of the context window. Style instructions placed there measurably
# decay over a long session as tool results and file contents accumulate below
# them. Anthropic's Opus 5 prompting guidance recommends re-anchoring tone
# instructions near the end of the prompt for exactly this reason; a
# UserPromptSubmit hook is the cheapest way to put the reminder adjacent to the
# live turn instead of 100k tokens above it.
#
# Kept deliberately short. Stdout from this hook is injected as context on
# every single prompt, so the cost is paid per turn — it points at the rules
# rather than restating them.
#
# Fails open: a reminder is never worth blocking a prompt over.

set -u

echo "Reminder: follow the Communication style section in AGENTS.md — readable over concise, outcome first, no Claude-isms."
exit 0
