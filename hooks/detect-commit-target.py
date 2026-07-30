"""Shared commit-detection helper for the two PreToolUse commit-gate hooks.

Reads a PreToolUse JSON payload on stdin and answers one question: does this
Bash command invoke `git commit`, and if so, WHICH repository does it target?

The target is not always the session cwd — `git -C <path> commit`,
`git --git-dir=... --work-tree=... commit`, `GIT_DIR=... git commit` and
`cd <path> && git commit` all redirect git elsewhere. Guarding the cwd instead
of the real target is how an unreviewed commit onto main slips through, so we
hand the caller back the same repo-redirecting options the command itself used,
for it to replay verbatim. Command-local environment assignments and preceding
`cd`s are translated into their equivalent options, since neither reaches the
hook process.

Output (stdout), one record per `git commit` found in the command:

    <number of option tokens>
    <cwd>
    <option token>          x <number>

Counted framing means no delimiter can ever collide with a path. A commit we
cannot read confidently is omitted rather than guessed at, and no output at all
means no commit was found — callers treat a missing record as "no opinion" and
FAIL OPEN. Reporting the wrong repository is the one outcome worse than
reporting nothing, so every uncertain path here drops the record.

This is a heuristic over shell text, not a shell. It exists to stop ordinary
mistakes, and it does not pretend to stop a deliberate bypass. Known holes,
all verified rather than assumed:

  * Nested interpreters and indirection — `sh -c 'git commit'`, `xargs git
    commit`, git aliases (`git -c alias.ci=commit ci`), shell aliases and
    functions. Each reaches a commit without the text ever saying so.
  * Anything whose target depends on runtime state we cannot evaluate:
    `cd "$VAR"`, `cd "$(...)"`, `cd ~/x`. These fail open — the replayed
    option simply does not resolve.
  * A `cd` we cannot read at the start of a segment sets lost_track, so the
    record is dropped rather than misattributed to the cwd.

One limitation belongs to the review gate rather than to detection, and no
amount of parsing fixes it:

  * The review marker describes the tree AS THE HOOK SEES IT, before the command
    runs. A compound command that mutates the tree and then commits — say
    `printf x > tracked && git add -A && git commit` — is judged on the
    pre-mutation state. Closing it fully would mean blocking the ordinary
    `git add -A && git commit` pattern outright. The gate does close the worst
    version of it, where the pre-mutation state is CLEAN: an empty pending set
    is allowed only when a review marker exists, so writing a file and
    committing it in one command still needs a review on record.

A second limitation used to live here — `git status --porcelain -uall` lists
untracked file NAMES, not contents, so editing an untracked file after approval
did not invalidate the marker. review-manifest.py now hashes the content of
every pending path, untracked ones included, which closes it.
"""

import json
import re
import shlex
import sys

# Git global options that consume the NEXT argument as their value. They have
# to be skipped as a pair; otherwise their value can be mistaken for the
# subcommand.
VALUE_OPTS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
              "--exec-path", "--super-prefix")
# The subset that changes which repository or worktree git ends up using.
# These are what the caller replays, so that its probe resolves the repo
# exactly as the real command will.
#
# `-c` is deliberately NOT among them. It looks like it belongs — surely
# `-c core.worktree=<path>` relocates the worktree — but measured against git
# 2.39.1, command-line `-c core.worktree` is ignored outright, as is a
# core.worktree arriving via `-c include.path=<file>`; only the repository's
# own config file is honoured. Replaying `-c` therefore buys nothing, while
# costing plenty: it couples the review fingerprint to presentation settings
# the approve side never sees (`-c status.showUntrackedFiles=no` would wedge
# the gate permanently shut) and makes the probe honour a model-supplied
# diff.external, running it BEFORE deciding whether to block.
REPLAY_OPTS = ("-C", "--git-dir", "--work-tree", "--namespace")
# Options we cannot faithfully replay: --config-env names an environment
# variable this process does not have, so it could set core.worktree behind our
# back. Seeing one means we have no answer.
UNSAFE_OPTS = ("--config-env",)

# Command-local `NAME=value git commit` assignments. The hook does not inherit
# them, so the ones that steer repository resolution are translated into the
# equivalent option and replayed.
ENV_AS_OPTION = {
    "GIT_DIR": "--git-dir",
    "GIT_WORK_TREE": "--work-tree",
    "GIT_NAMESPACE": "--namespace",
}
# GIT_* assignments that cannot affect which repository or which pending
# changes we would see. Anything else starting with GIT_ is assumed to matter
# (GIT_INDEX_FILE and GIT_OBJECT_DIRECTORY both do) and we fail open.
HARMLESS_GIT_ENV = frozenset((
    "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE",
    "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_PAGER", "GIT_ASKPASS",
    "GIT_TERMINAL_PROMPT", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_MERGE_AUTOEDIT",
))

# An option value as it appears in the raw command: a double-quoted string, a
# single-quoted string, or a bare run of non-space. Quoted forms matter because
# Windows paths routinely contain spaces ("C:/My Repo"). The three branches are
# disjoint on their first character, so the matcher cannot backtrack between
# them.
VALUE = r"""(?:"[^"]*"|'[^']*'|[^\s"']\S*)"""

# The command word: bare `git`, or a path ending in git / git.exe, quoted or
# not ("C:/Program Files/Git/cmd/git.exe").
GIT_WORD = (r"""(?:"[^"]*[/\\]git(?:\.exe)?"|'[^']*[/\\]git(?:\.exe)?'"""
            r"""|[^\s"']*[/\\]git(?:\.exe)?|git)""")

_VALUE_OPT_ALT = "|".join(VALUE_OPTS)

# Anchored at the segment start: optional whitespace, any number of env-var
# assignments (FOO=bar), then git, then any number of git global options, then
# `commit`. The value-taking alternative comes first so `git -C <path> commit`
# matches at all — without it the path sits where `commit` is expected and the
# whole command goes undetected. The bare-flag alternative excludes the
# value-taking names via lookahead, so exactly one alternative can match at any
# position; overlapping alternatives inside a repetition are what turn a long
# option list into exponential backtracking. This is still a matcher, not a
# parser: nonsense like `git -C commit` matches, and erring towards detection
# is the safe direction. `commit(?![\w./:-])` excludes commit-graph,
# commit-tree and `commit.foo`, none of which are commits.
COMMIT_RE = re.compile(
    r"^\s*(?:\w+=" + VALUE + r"?\s+)*" + GIT_WORD + r"\s+"
    r"(?:(?:" + _VALUE_OPT_ALT + r")\s+" + VALUE + r"\s+"
    r"|--[\w-]+=" + VALUE + r"?\s+"
    r"|(?!(?:" + _VALUE_OPT_ALT + r")\s)-{1,2}[\w-]+\s+)*"
    r"commit(?![\w./:-])"
)

ASSIGN_RE = re.compile(r"^(\w+)=(.*)$", re.DOTALL)

# Connectors after which a preceding `cd` may not have taken effect: `||` runs
# the next command precisely when the previous one failed, `&` backgrounds it
# in a subshell that never moves the parent, and `|` is a subshell too.
UNSOUND_SEPARATORS = ("||", "|", "&")

# `<<EOF`, `<<-EOF`, `<<"EOF"`, `<<'EOF'`. Not `<<<` (a here-string), whose
# next character cannot start an identifier.
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# `cd somewhere && git commit` targets the repo at `somewhere`, exactly as
# `git -C somewhere commit` does.
CD_RE = re.compile(r"^\s*cd(?:\s|$)")

# Shell keywords that can precede a command inside a segment. Stripping them
# means `if ...; then cd x && git commit; fi` reads the cd, instead of missing
# it and then claiming the commit targets the cwd.
LEADING_KEYWORDS = ("then", "else", "elif", "do", "done", "fi", "if", "while",
                    "for", "until", "!", "time")

# Fallback boundaries, used only to recover detection from a command whose
# quoting the scanner could not follow.
NAIVE_SPLIT_RE = re.compile(r"\n|;|&&|\|\||\||&|\$\(|`|\(|\)|\{|\}")


def strip_heredoc_bodies(command):
    """Drop heredoc bodies, keeping the line that introduces them.

    Heredoc content is data, not commands, but every newline is a command
    boundary — so `cat <<EOF` ... `git commit` ... `EOF` would otherwise read
    as a commit and block a `cat`. Blocking a non-commit is the one thing
    these hooks must never do.

    A body is only dropped when its terminator actually appears. Without that
    check, `echo "a << b"` swallows the entire rest of the command, and any
    `<<` used as data or a shift operator hides real commits behind it.
    """
    if "<<" not in command:
        return command
    lines = command.split("\n")
    kept = []
    i = 0
    while i < len(lines):
        line = lines[i]
        kept.append(line)
        i += 1
        match = HEREDOC_RE.search(line)
        if not match:
            continue
        terminator = match.group(2)
        end = i
        while end < len(lines) and lines[end].strip() != terminator:
            end += 1
        if end < len(lines):
            i = end + 1  # skip the body and the terminator line
    return "\n".join(kept)


def split_segments(command):
    """Split a command into (segment, preceding separator, group depth).

    Quote-aware, which the highest-priority contract requires: a boundary
    character inside a quoted string is data. Without this, a commit message
    like 'feat(scope): x' reads as a subshell, and a `cd` mentioned inside an
    echoed string reads as a real one — the latter producing a confident claim
    about a repository the command never touches.

    Depth counts SUBSHELL nesting, so a `cd` inside `( ... )` can be discarded
    at the closing paren instead of leaking out to later commands. Brace groups
    are deliberately not counted: `{ cd x; }` runs in the current shell and the
    move persists.

    Returns (segments, unterminated) where unterminated says a quote was left
    open — the caller must not trust any move it thinks it saw.
    """
    segments = []
    buf = []
    sep = ""
    seg_depth = 0
    depth = 0
    quote = None
    in_backticks = False
    i = 0
    n = len(command)

    def flush(next_sep, next_depth):
        segments.append(("".join(buf), sep, seg_depth))
        del buf[:]
        return next_sep, next_depth

    while i < n:
        char = command[i]
        if quote:
            buf.append(char)
            if char == "\\" and quote == '"' and i + 1 < n:
                buf.append(command[i + 1])
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if char == "\\" and i + 1 < n:
            buf.append(char)
            buf.append(command[i + 1])
            i += 2
            continue
        if char in "'\"":
            quote = char
            buf.append(char)
            i += 1
            continue

        pair = command[i:i + 2]
        if pair in ("&&", "||"):
            sep, seg_depth = flush(pair, depth)
            i += 2
            continue
        if pair == "$(":
            depth += 1
            sep, seg_depth = flush(pair, depth)
            i += 2
            continue
        if char == "(":
            depth += 1
            sep, seg_depth = flush(char, depth)
            i += 1
            continue
        if char == ")":
            depth = max(0, depth - 1)
            sep, seg_depth = flush(char, depth)
            i += 1
            continue
        if char == "`":
            # Backticks are command substitution, i.e. a subshell, exactly like
            # $( ). They do not nest, so a toggle is enough — but they must
            # move the depth, or a `cd` inside one leaks out to later commands.
            in_backticks = not in_backticks
            depth = depth + 1 if in_backticks else max(0, depth - 1)
            sep, seg_depth = flush(char, depth)
            i += 1
            continue
        if char in ";\n|&{}":
            # Brace groups are boundaries but not subshells: no depth change.
            sep, seg_depth = flush(char, depth)
            i += 1
            continue
        buf.append(char)
        i += 1

    segments.append(("".join(buf), sep, seg_depth))
    return segments, quote is not None


def standalone_env(segment):
    """Read a segment that only sets environment variables.

    Returns a list of equivalent git options, "unknown" if the segment sets
    something we cannot reproduce, or None if it is not a pure assignment.
    `GIT_DIR=... ; git commit` and `export GIT_DIR=...` steer every later
    command exactly as the `GIT_DIR=... git commit` prefix form does.
    """
    try:
        toks = shlex.split(segment)
    except ValueError:
        return None
    if toks and toks[0] == "export":
        toks = toks[1:]
    if not toks:
        return None
    options = []
    for tok in toks:
        assignment = ASSIGN_RE.match(tok)
        if not assignment:
            return None  # a command follows, so this is not a bare assignment
        name, value = assignment.group(1), assignment.group(2)
        option = ENV_AS_OPTION.get(name)
        if option:
            if not value:
                return "unknown"
            options += [option, value]
        elif name.startswith("GIT_") and name not in HARMLESS_GIT_ENV:
            return "unknown"
    return options


def strip_keywords(segment):
    """Drop leading shell keywords so the command word comes first."""
    stripped = segment.lstrip()
    while True:
        head = stripped.split(None, 1)
        if len(head) < 2 or head[0] not in LEADING_KEYWORDS:
            return stripped
        stripped = head[1]


def cd_target(segment):
    """Where a `cd <path>` segment moves to, or None if we cannot tell.

    Only the plain one-argument form counts. `cd` with no argument, `cd -`,
    and anything we cannot tokenise leave us unable to say where the following
    commands run.
    """
    try:
        toks = shlex.split(segment)
    except ValueError:
        return None
    if len(toks) == 2 and toks[0] == "cd" and not toks[1].startswith("-"):
        return toks[1]
    return None


def hides_a_cd(segment):
    """True if a `cd` sits somewhere in the segment we are not reading.

    We only interpret a cd at the start of a segment. One anywhere else means
    a move may be happening that we cannot follow, and continuing to report
    the cwd as the target would be an outright false statement.
    """
    try:
        toks = shlex.split(segment)
    except ValueError:
        # Unreadable quoting. Only worry if the text actually mentions a cd,
        # otherwise every stray apostrophe would disable the gate.
        return re.search(r"(?<![\w-])cd\s", segment) is not None
    return "cd" in toks[1:]


def scan(toks):
    """Repo-redirecting options in a tokenised command, or None if unusable.

    None means "we cannot read this reliably" — the caller must fail open
    rather than guard a repository we only guessed at.
    """
    flags = []
    i = 0
    while i < len(toks):
        assignment = ASSIGN_RE.match(toks[i])
        if not assignment:
            break
        name, value = assignment.group(1), assignment.group(2)
        option = ENV_AS_OPTION.get(name)
        if option:
            if not value:
                return None
            flags += [option, value]
        elif name.startswith("GIT_") and name not in HARMLESS_GIT_ENV:
            return None  # GIT_INDEX_FILE and friends: we cannot reproduce it
        i += 1

    if i >= len(toks):
        return None
    if toks[i].replace("\\", "/").rsplit("/", 1)[-1] not in ("git", "git.exe"):
        return None
    i += 1

    while i < len(toks):
        tok = toks[i]
        if tok in VALUE_OPTS:
            if i + 1 >= len(toks):
                return None  # dangling option, value cut off
            value = toks[i + 1]
            if tok in REPLAY_OPTS:
                if value:
                    flags += [tok, value]
                elif tok != "-C":
                    # `git -C ""` is a documented no-op, so dropping the pair
                    # keeps the cwd as the target. An empty --git-dir is not,
                    # so we do not get to claim we know where this points.
                    return None
            i += 2
        elif tok in UNSAFE_OPTS:
            return None
        elif tok.startswith("--") and "=" in tok:
            name, value = tok.split("=", 1)
            if name in UNSAFE_OPTS:
                return None
            if name in REPLAY_OPTS:
                if not value:
                    return None  # --git-dir= with nothing after it
                flags.append(tok)
            i += 1
        elif tok.startswith("-"):
            i += 1
        else:
            # The subcommand: every global option is behind us, so what we
            # collected is the complete picture.
            return flags
    # Ran off the end without reaching a subcommand. On a truncated retry that
    # means the options we care about may still be ahead of us — reporting
    # "no options, so it targets the cwd" would be an outright false answer.
    return None


def repo_flags(segment):
    """Repo-redirecting options in one command segment, or None if unusable."""
    try:
        return scan(shlex.split(segment))
    except ValueError:
        pass
    # Unbalanced quoting, because a shell metacharacter inside a quoted string
    # (`git commit -m "fix: a; b"`) split the segment mid-string. The global
    # options always precede the subcommand and its message, so retry on the
    # text before quoting begins. scan() only answers once it has actually
    # reached the subcommand, so a prefix that stops short fails open instead
    # of pointing us at the wrong repository.
    # First try simply closing the quote the split left open — that recovers
    # the whole invocation, options included.
    for quote in ('"', "'"):
        try:
            return scan(shlex.split(segment + quote))
        except ValueError:
            continue
    # Otherwise fall back to the text before quoting begins.
    cuts = [i for i in (segment.find('"'), segment.find("'")) if i >= 0]
    head = segment[:min(cuts)] if cuts else segment
    try:
        return scan(shlex.split(head))
    except ValueError:
        return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    cwd = payload.get("cwd") or ""
    if not isinstance(command, str) or not isinstance(cwd, str) or not cwd:
        return

    command = strip_heredoc_bodies(command)
    # A backslash-newline continuation is one command, but the splitter treats
    # the newline as a boundary and would lose the tail. CRLF first, so the
    # LF pass cannot strip the backslash and strand the CR.
    command = command.replace("\\\r\n", " ").replace("\\\n", " ")

    # A `cd`, or a bare GIT_DIR assignment, earlier in the same command moves
    # the target repo just as `-C` does, and replaying it reproduces the move
    # exactly (git applies -C cumulatively, so relative paths still resolve).
    # Each is remembered with the grouping depth it happened at, so a `cd`
    # inside `( ... )` is discarded at the closing paren rather than leaking
    # out to later commands.
    pending = []       # [(depth, [option tokens])], outermost first
    lost_track = False

    segments, unterminated = split_segments(command)
    # A quote left open — an apostrophe in a comment is enough — collapses
    # everything after it into one segment, so later commands would be missed
    # entirely. Recover detection with the naive split, but refuse to apply any
    # move: we clearly cannot tell code from data here, so a move we think we
    # see is not one we can stand behind. A move we cannot apply becomes
    # lost_track below, which drops the record rather than misreporting it.
    moves_untrusted = unterminated
    if unterminated:
        segments = [(seg, "", 0) for seg in NAIVE_SPLIT_RE.split(command)]

    out = []
    for segment, separator, depth in segments:
        while pending and pending[-1][0] > depth:
            pending.pop()  # left the group the move happened in
        if pending and separator in UNSOUND_SEPARATORS:
            # The commit may be running because the cd FAILED, or in a subshell
            # of its own. Either way we no longer know where it lands.
            lost_track = True

        if COMMIT_RE.search(segment):
            if lost_track:
                continue
            flags = repo_flags(segment)
            # An unreadable commit is a hole in THIS segment only — the caller
            # evaluates each record independently, so the others still stand.
            # A newline in a value cannot survive the line-based framing;
            # Windows paths cannot contain one, so it only ever means
            # something strange.
            if flags is None or any("\n" in flag for flag in flags):
                continue
            flags = [tok for _, toks in pending for tok in toks] + flags
            out.append("%d\n%s" % (len(flags), "\n".join([cwd] + flags)))
            continue

        command_text = strip_keywords(segment)
        env = standalone_env(command_text)
        if env == "unknown":
            lost_track = True
        elif env:
            if moves_untrusted:
                lost_track = True
            else:
                pending.append((depth, env))
        elif env is None and CD_RE.match(command_text):
            target = cd_target(command_text)
            if target is None or moves_untrusted:
                lost_track = True
            else:
                pending.append((depth, ["-C", target]))
        elif hides_a_cd(command_text):
            lost_track = True

    if out:
        sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
