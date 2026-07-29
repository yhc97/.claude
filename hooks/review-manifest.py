"""Content-manifest recorder/checker for the code-review commit gate.

Shared by both modes of require-code-review.sh, which is the whole point: the
recording side and the checking side MUST build the manifest identically or the
gate either wedges shut permanently or silently stops enforcing. One file, one
implementation, no chance of drift.

The gate answers: "has every piece of content about to be committed already been
looked at by a reviewer?" It does NOT answer "is this the exact tree that was
reviewed" — that stricter question is what made the old single-digest gate
demand a fresh review for every commit in an atomic sequence.

    record   store the content identity of everything currently pending
    check    allow while every pending path's content is one we recorded

Content identity is git's own blob oid, never a raw byte hash. The oid is what
`git add` would write, so oids from the worktree, the index and HEAD are
directly comparable. A raw sha256 of the worktree bytes is NOT comparable: with
`* text=auto eol=lf` in .gitattributes the worktree holds CRLF and the blob holds
LF, so a byte hash would mismatch on every file forever.

The identity is the object TYPE plus the oid — `f:<oid>` for a regular file,
`l:<oid>` for a symlink, `g:<oid>` for a gitlink. The executable bit is
deliberately collapsed: 100644 and 100755 both read as `f`.

That split is not cosmetic. Carrying the full mode meant a `chmod +x`
re-triggered review, but it also meant an executable file blocked the moment
`git reset` dropped its index entry and left the mode unknowable — while the
block message tells the model not to re-approve mid-sequence. Two rounds of
wedges came out of that, for a signal worth very little: an exec flip with
identical content is visible in `git status` anyway, and on Windows
core.filemode is off so it was never detected there at all.

Type does not have that problem, because it does not go unknowable the way a
mode does: the worktree side normally reads it straight off the filesystem
(islink/isdir/isfile) rather than inferring it from an index entry that may be
gone. Two places do consult the index, and both are deliberate:

  * A directory takes the index's gitlink entry, because hash-object cannot
    hash a directory.
  * With core.symlinks off — the Windows default — git checks a 120000 entry
    out as a PLAIN FILE holding the target text, and `git add` on that file
    still stores mode 120000. There the filesystem and git disagree about the
    type, and git wins, so the recorded type has to win here too. Trusting
    islink instead made a plain `git add` of unchanged content block: the
    worktree said `f:<oid>`, staging produced `l:<oid>`, and neither the
    record side nor the check side could ever agree. The rule is to follow
    whichever side git itself will follow when it writes the object.

Dropping type entirely, as an earlier version did, opened a real hole. Git
stores a symlink as a blob holding the target string, so a regular file and a
symlink whose target equals that file's contents are THE SAME BLOB, differing
only in mode. A reviewed file could therefore be swapped for a symlink to an
arbitrary path with the oid unchanged, and the gate would wave it through —
even though `git status` reports it as a typechange (`T`). Verified as a live
bypass before this tag was added, not a theoretical one.

For each pending path we record the SET of identities the reviewer can be said
to have seen: the blob in HEAD, in the index, and in the worktree. A commit is
allowed while, for every path still pending, BOTH its current index identity and
its current worktree identity are in that path's recorded set.

Recording all three sides is what makes staging free. `git add` moves a path's
index identity from the HEAD blob to the worktree blob; both are already in the
set, so staging between atomic commits never invalidates anything. Keying on
staging state instead would re-block on the very workflow this exists to allow.

What still blocks, by construction: editing a reviewed file (new oid, not in the
set), adding a new file (path absent from the manifest), and renaming one (the
destination is a new path).

Deliberate holes, accepted rather than overlooked:

  * An empty pending set passes when a marker exists, so `git commit --amend
    --no-edit` and `--allow-empty` succeed inside an approved sequence. With no
    marker it blocks, because the hook sees the tree before the guarded command
    runs and a clean tree is what `printf x > f && git add -A && git commit`
    looks like from here.
  * Deleting a file that was untracked at record time passes: its set contains
    ABSENT from the HEAD and index sides, and a deletion matches that. Making
    the sentinel side-specific would false-block the ordinary "record
    everything, unstage one file, commit the rest" flow, which is worse.
  * `git add -p` hunk carving blocks. An intermediate index blob is a content
    state nobody reviewed, so this is correct, but it bites *within* a file —
    the one place the atomic-commit story does not hold. The block message says
    so explicitly, because otherwise it reads as a bug.

Exit codes are the contract, not stdout, so a traceback can never be mistaken
for a verdict:

    0    allow
    10   block; stdout lists the unapproved paths, one per line
    *    anything else means "could not evaluate" and the caller FAILS OPEN
"""

import hashlib
import json
import os
import subprocess
import sys
import time

# Verdict exit codes. Any code that is not ALLOW or BLOCK means the caller could
# not get an answer and must fail open, so BLOCK deliberately is not 1 — that is
# what Python exits with on an uncaught exception.
ALLOW = 0
BLOCK = 10
CANNOT_EVALUATE = 3

# Bumped to 3 when the type tag entered the identity. A v2 marker holds bare
# oids, which can no longer match anything this builds; reading it as "no valid
# approval" turns a silent permanent mismatch into one clean re-approval.
MARKER_VERSION = 3

# A recorded review goes stale after this long. Content changes already
# invalidate the marker, so this only catches a marker abandoned mid-session and
# rediscovered much later. Time-based rather than HEAD-based on purpose: pinning
# to the approval commit would false-block `git pull --rebase` mid-sequence,
# which rewrites the base under an untouched working tree.
MAX_MARKER_AGE_SECONDS = 7 * 24 * 60 * 60

# Sentinel for "this path does not exist on this side" — not in HEAD, not in the
# index, or deleted from the worktree. Real entries are `<type>:<oid>`, which can
# never collide with this. ABSENT is deliberately left untagged: "not here" has
# no type, and tagging it would make a deletion fail to match itself.
ABSENT = "-"

# Object-type tags. The exec bit is collapsed into TYPE_FILE on purpose (see the
# module docstring): type stays knowable when a mode does not.
TYPE_FILE = "f"
TYPE_LINK = "l"
TYPE_GITLINK = "g"

_MODE_TYPES = {"120000": TYPE_LINK, "160000": TYPE_GITLINK}


def mode_type(mode):
    """Git's 6-digit mode -> a type tag. 100644 and 100755 both mean "file"."""
    return _MODE_TYPES.get(mode, TYPE_FILE)


def tagged(type_tag, oid):
    """`<type>:<oid>`, or ABSENT untouched so deletions still compare equal."""
    return oid if oid == ABSENT else "%s:%s" % (type_tag, oid)

# Prose and repo metadata. A commit touching ONLY these skips the gate: running
# an opus code reviewer over prose is the cost this exemption exists to remove.
# Matched against the BASENAME at any depth, case-folded.
#
# Two things are deliberately missing. There is no directory glob (no `docs/**`)
# because docs/conf.py and docs/build.sh are code — the rule is about file type,
# never location. And .gitattributes is NOT here even though .gitignore is: it
# controls the clean filters that decide every other path's blob oid, so an
# unreviewed edit to it silently changes what the whole manifest hashes to.
EXEMPT_SUFFIXES = (".md", ".txt", ".rst")
EXEMPT_STEMS = ("license", "licence", "copying")
EXEMPT_EXACT = (".gitignore",)

# .txt files that are code by any other name. requirements.txt is a supply-chain
# vector — one line pulls in an arbitrary package — and CMakeLists.txt is build
# logic that executes. Exempting either would contradict the rule these lists
# exist to express: file TYPE decides, and these are not prose.
NOT_PROSE = (
    "requirements.txt",
    "requirements-dev.txt",
    "requirements-test.txt",
    "constraints.txt",
    "cmakelists.txt",
    "makefile.txt",
    "dockerfile.txt",
)


class CannotEvaluate(Exception):
    """Raised when the repo state cannot be read. Always becomes fail-open."""


def git_bytes(prefix, args):
    """Run a git command, returning raw stdout. Bytes, because paths are bytes."""
    try:
        done = subprocess.run(
            ["git"] + prefix + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as exc:
        raise CannotEvaluate("could not run git: %s" % exc)
    if done.returncode != 0:
        raise CannotEvaluate("git %s failed" % " ".join(args))
    return done.stdout


def decode(raw):
    """Bytes -> str for a path. surrogateescape so undecodable bytes round-trip.

    Paths are bytes on POSIX and git hands them over verbatim under -z. Losing a
    path to a decode error would silently shrink the manifest, which reads as
    "nothing pending" and lets an unreviewed file through.
    """
    return raw.decode("utf-8", "surrogateescape")


def parse_status(prefix):
    """Pending paths from `status --porcelain -uall -z`, as [(xy, path)].

    -z is not a convenience here, it is required: it turns off core.quotepath
    escaping entirely, so paths with spaces or non-ASCII bytes arrive raw and
    need no unquoting.

    Records are `XY<space><path>` NUL-terminated. A rename or copy carries the
    source as ONE EXTRA field, and under -z the order is REVERSED relative to
    the readable form: `R  <dest>NUL<source>NUL`, not `<source> -> <dest>`.
    Consuming that extra field in the wrong place shifts every later record by
    one and quietly corrupts the whole manifest, so the index walk is explicit.
    """
    raw = git_bytes(prefix, ["status", "--porcelain", "-uall", "-z"])
    fields = raw.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()

    entries = []
    i = 0
    while i < len(fields):
        record = fields[i]
        i += 1
        if len(record) < 3:
            continue
        xy = decode(record[0:2])
        # `!!` only appears under --ignored, which we never pass; skip defensively.
        if xy == "!!":
            continue
        entries.append((xy, decode(record[3:])))
        if record[0:1] in (b"R", b"C") or record[1:2] in (b"R", b"C"):
            if i >= len(fields):
                raise CannotEvaluate("truncated rename record in status output")
            # The source path: deleted from its old location, so it is pending
            # in its own right and needs its own manifest entry.
            entries.append(("D ", decode(fields[i])))
            i += 1
    return entries


def head_identities(prefix, paths):
    """path -> blob oid in HEAD, ABSENT where the path is not in HEAD.

    The HEAD identity has to be the same shape as the index identity or the two
    can never compare equal, and comparing them is the entire mechanism that
    lets `git add` happen between atomic commits without invalidating the
    review.

    An unborn HEAD makes ls-tree fail; that just means every path is ABSENT,
    which is the correct answer for a repo with no commits.
    """
    identities = {path: ABSENT for path in paths}
    if not paths:
        return identities

    try:
        # --full-tree, or this lists only the subtree below the cwd and names
        # its entries relative to it. status always reports repo-root-relative
        # paths, so without this the keys silently fail to match whenever the
        # caller stands anywhere but the repo root, every path reads as ABSENT,
        # and the recorded manifest is quietly wrong.
        raw = git_bytes(prefix, ["ls-tree", "-r", "-z", "--full-tree", "HEAD"])
    except CannotEvaluate:
        return identities

    wanted = set(paths)
    for record in raw.split(b"\0"):
        if not record:
            continue
        meta, _, path_raw = record.partition(b"\t")
        path = decode(path_raw)
        if path not in wanted:
            continue
        parts = decode(meta).split()
        if len(parts) == 3:
            # ls-tree prints `<mode> <type> <oid>`.
            identities[path] = tagged(mode_type(parts[0]), parts[2])
    return identities


def index_identities(prefix, paths):
    """path -> blob oid in the index, ABSENT where not staged."""
    # --full-name and the :/ pathspec for the same reason as ls-tree's
    # --full-tree: by default ls-files reports only what is under the cwd, and
    # names it relative to the cwd.
    raw = git_bytes(prefix, ["ls-files", "-s", "-z", "--full-name", "--", ":/"])
    wanted = set(paths)
    staged = {}
    unmerged = {}

    for record in raw.split(b"\0"):
        if not record:
            continue
        meta, _, path_raw = record.partition(b"\t")
        path = decode(path_raw)
        if path not in wanted:
            continue
        parts = decode(meta).split()
        if len(parts) != 3:
            continue
        mode, oid, stage = parts
        if stage == "0":
            staged[path] = tagged(mode_type(mode), oid)
        else:
            # An unmerged path has stages 1/2/3 and no stage 0. Letting that
            # read as ABSENT would be wrong, so build a deterministic composite
            # that can never match a normal entry. Conflicts are already exempt
            # via MERGE_HEAD; this is belt and braces.
            unmerged.setdefault(path, []).append("%s^%s:%s" % (stage, mode, oid))

    identities = {}
    for path in paths:
        if path in staged:
            identities[path] = staged[path]
        elif path in unmerged:
            identities[path] = "unmerged:" + ",".join(sorted(unmerged[path]))
        else:
            identities[path] = ABSENT
    return identities


def recorded_type(index, head, path):
    """The type git already has on record for a path — index first, then HEAD.

    The index wins because it is what `git add` preserves. Returns None when
    neither side knows the path, which is the untracked case.
    """
    for side in (index, head):
        entry = side.get(path, ABSENT)
        if entry != ABSENT and ":" in entry:
            return entry.split(":", 1)[0]
    return None


def symlinks_supported(prefix):
    """Whether git will store what the filesystem says, for symlinks.

    With core.symlinks false git cannot put a link in the worktree, so it writes
    a plain file holding the target and keeps the 120000 mode on `git add`. The
    filesystem then lies about the type and the index tells the truth.

    Defaults to True when unset or unreadable: that is git's own default on
    POSIX, and it is the answer that keeps the filesystem authoritative, so a
    file/symlink swap is still caught. Guessing False would suppress the check.
    """
    try:
        raw = git_bytes(prefix, ["config", "--bool", "core.symlinks"])
    except CannotEvaluate:
        return True
    return decode(raw).strip() != "false"


def worktree_identities(prefix, prefix_cwd, entries, index, head, symlinks_ok):
    """path -> blob oid for the worktree, ABSENT where the file is gone.

    Only paths whose worktree copy might differ from the index get hashed; when
    status says the worktree matches the index, the index oid is already the
    answer and no subprocess is needed. That keeps the usual case at zero extra
    processes and the worst case at exactly one.
    """
    identities = {}
    to_hash = []
    # Paths that hash like a file but must be tagged as a link — see the
    # core.symlinks branch below.
    link_typed = set()

    for xy, path in entries:
        # Second status column: ' ' means the worktree agrees with the index.
        worktree_clean = len(xy) > 1 and xy[1] == " " and xy != "??"
        if worktree_clean and index.get(path, ABSENT) != ABSENT:
            identities[path] = index[path]
            continue

        full = os.path.join(prefix_cwd, path) if prefix_cwd else path
        # islink first: a symlink to a directory would pass isfile, and hashing
        # through it would store the target's content instead of the link.
        #
        # The identity must be git's own blob oid, not a "symlink:<target>" of
        # our own invention: the index reports a staged symlink by its blob oid,
        # and an identity in any other shape could never compare equal to it.
        # That would block the ordinary approve-then-stage flow for a symlink
        # with no way out but re-approving after every `git add`.
        if os.path.islink(full):
            # Tagged TYPE_LINK, which is what stops a symlink from passing as
            # the regular file it replaced: the blob is identical, the tag is
            # not. islink is checked first because a link to a directory would
            # also satisfy isdir.
            identities[path] = tagged(TYPE_LINK, symlink_identity(full))
            continue
        if os.path.isdir(full):
            # A submodule/gitlink. hash-object cannot hash a directory and would
            # abort the whole batch, so take the index's gitlink entry instead.
            identities[path] = index.get(path, ABSENT)
            continue
        if not os.path.isfile(full):
            identities[path] = ABSENT
            continue
        if not symlinks_ok and recorded_type(index, head, path) == TYPE_LINK:
            # A checked-out 120000 entry on a filesystem that cannot hold links.
            # It looks like a plain file and hashes like one, but `git add` will
            # store it as a symlink, so the symlink tag is the honest identity.
            # Without this a plain `git add` of unchanged content false-blocks.
            to_hash.append(path)
            link_typed.add(path)
            continue
        if "\n" in path:
            # --stdin-paths is newline-delimited, so such a path is
            # unrepresentable. ABSENT keeps it unapproved rather than
            # misaligning every response in the batch.
            identities[path] = ABSENT
            continue
        to_hash.append(path)

    if to_hash:
        # One process for the lot. Filters ARE applied per path, so eol/clean
        # normalisation matches what `git add` would store — that comparability
        # is the whole basis of the subset check.
        #
        # Every path here was just checked to be an existing regular file,
        # because a single unhashable path aborts the batch and would cost us
        # every hash in it.
        stdin = "".join(p + "\n" for p in to_hash)
        try:
            done = subprocess.run(
                ["git"] + prefix + ["hash-object", "--stdin-paths"],
                input=stdin.encode("utf-8", "surrogateescape"),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        except OSError as exc:
            raise CannotEvaluate("could not run hash-object: %s" % exc)
        if done.returncode != 0:
            raise CannotEvaluate("hash-object failed")

        oids = decode(done.stdout).split()
        if len(oids) != len(to_hash):
            raise CannotEvaluate("hash-object returned a mismatched number of oids")

        # Every path in this batch was screened to an existing regular file
        # above, so TYPE_FILE is a fact — except where git will store the file
        # back as the symlink it stands in for.
        for path, oid in zip(to_hash, oids):
            tag = TYPE_LINK if path in link_typed else TYPE_FILE
            identities[path] = tagged(tag, oid)

    return identities


def symlink_identity(full_path):
    """A symlink's git identity: the oid of the blob holding its target.

    Git stores a symlink as a blob whose content is the target string.
    Computing the oid here rather than shelling out keeps it off the hash-object
    batch, which cannot hash a link without following it.
    """
    try:
        target = os.readlink(full_path)
    except OSError as exc:
        # NOT ABSENT. "I could not read this link" is not "this path is gone":
        # ABSENT is a value the recorded set may not contain, so guessing it
        # turns an unevaluable state into a confident block, which is the one
        # thing this whole file is not allowed to do.
        raise CannotEvaluate("could not read the symlink %s: %s" % (full_path, exc))
    if isinstance(target, str):
        # Windows hands back 'd\target' for a link git stores as blob 'd/target',
        # so without this the oid is the sha of the wrong bytes and staging the
        # link false-blocks. On POSIX os.sep is '/' and a backslash is a legal
        # filename character, so the replacement must stay Windows-only.
        if os.sep != "/":
            target = target.replace(os.sep, "/")
        target = target.encode("utf-8", "surrogateescape")
    # A git blob oid is sha1 over the object header plus the content.
    digest = hashlib.sha1(b"blob %d\0" % len(target) + target).hexdigest()
    return digest


def build_state(prefix, prefix_cwd):
    """Current pending state: path -> (index identity, worktree identity)."""
    entries = parse_status(prefix)
    paths = []
    for _, path in entries:
        if path not in paths:
            paths.append(path)

    head = head_identities(prefix, paths)
    index = index_identities(prefix, paths)
    worktree = worktree_identities(
        prefix, prefix_cwd, entries, index, head, symlinks_supported(prefix)
    )

    state = {}
    for path in paths:
        state[path] = (
            index.get(path, ABSENT),
            worktree.get(path, ABSENT),
            head.get(path, ABSENT),
        )
    return state


def is_exempt(path):
    """True for prose and repo metadata — the files a code review adds nothing to."""
    name = os.path.basename(path.replace("\\", "/")).lower()
    if name in EXEMPT_EXACT:
        return True
    if name in NOT_PROSE:
        return False
    if name.endswith(EXEMPT_SUFFIXES):
        return True

    # LICENCE, LICENSE.md, COPYING.txt — but NOT licence_check.sh or
    # copying_utils.c. An unanchored prefix match would exempt any file whose
    # name merely begins with one of these words, whatever its type, which is
    # how real code slips through a prose exemption.
    stem, _, extension = name.partition(".")
    if stem in EXEMPT_STEMS:
        return extension == "" or ("." + extension).endswith(EXEMPT_SUFFIXES)
    return False


def read_marker(path):
    """The recorded manifest, or None if there is not a usable one.

    None covers a missing file, the legacy v1 format (a bare sha256 digest),
    corruption, and expiry. All of them mean the same thing — no valid review on
    record — so all of them block, exactly as a missing marker always has.

    That is not a fail-open violation. Fail-open is for states we CANNOT
    evaluate; this is a state we evaluate confidently as unapproved. The cost of
    being wrong is one extra review, once.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None
    except OSError as exc:
        # A marker we cannot READ (permissions, I/O error) is not the same as
        # one that is not there. We genuinely cannot evaluate it, and blocking
        # would be unfixable from the caller's side: --approve writes to this
        # same unreadable path, so the remedy would fail too.
        raise CannotEvaluate("could not read the marker: %s" % exc)
    except ValueError:
        return None

    if not isinstance(data, dict) or data.get("version") != MARKER_VERSION:
        return None
    approved = data.get("approved")
    if not isinstance(approved, dict):
        return None

    created = data.get("created_at")
    if not isinstance(created, (int, float)):
        return None
    if time.time() - created > MAX_MARKER_AGE_SECONDS:
        return None

    return approved


def cmd_record(marker_path, prefix, prefix_cwd):
    state = build_state(prefix, prefix_cwd)

    approved = {}
    for path, (index_id, worktree_id, head_id) in state.items():
        # A set, so the order of the three sides never matters and staging can
        # move the index between them freely.
        approved[path] = sorted({index_id, worktree_id, head_id})

    try:
        head_sha = decode(git_bytes(prefix, ["rev-parse", "HEAD"])).strip()
    except CannotEvaluate:
        head_sha = None  # unborn HEAD; recorded for diagnostics only

    payload = {
        "version": MARKER_VERSION,
        "created_at": int(time.time()),
        "head": head_sha,
        "approved": approved,
    }
    # Write then rename, so a check running concurrently sees either the old
    # marker or the new one, never a half-written file that would read as
    # corrupt and block. ensure_ascii so surrogateescape'd path bytes survive.
    temp_path = marker_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=True, sort_keys=True)
    os.replace(temp_path, marker_path)

    return len(approved)


def cmd_check(marker_path, prefix, prefix_cwd):
    state = build_state(prefix, prefix_cwd)
    approved = read_marker(marker_path)

    if not state:
        # Nothing pending: `git commit --amend --no-edit` and `--allow-empty`.
        #
        # This still requires a marker, and that is not pedantry. The hook sees
        # the tree BEFORE the guarded command runs, so a compound command that
        # writes a file and commits it in one go — `printf x > new.py &&
        # git add -A && git commit` — presents a clean tree here. Allowing an
        # empty state unconditionally would wave that through with no review
        # ever recorded, which is a real bypass whenever content is authored
        # inside the Bash tool rather than via Edit/Write.
        #
        # Requiring a marker keeps `--amend` and `--allow-empty` working inside
        # an approved sequence, where one exists, and blocks the cold case.
        return (ALLOW, []) if approved is not None else (BLOCK, [])

    approved = approved or {}

    unapproved = []
    for path in sorted(state):
        index_id, worktree_id, _ = state[path]
        seen = approved.get(path)
        if not isinstance(seen, list):
            unapproved.append(path)
            continue
        if index_id not in seen or worktree_id not in seen:
            unapproved.append(path)

    if not unapproved:
        return ALLOW, []

    # Filter the UNAPPROVED set rather than short-circuiting on the pending set,
    # so the exemption composes with the manifest: reviewed code plus an
    # unreviewed README tweak still commits.
    blocking = [path for path in unapproved if not is_exempt(path)]
    if not blocking:
        return ALLOW, []
    return BLOCK, blocking


def main():
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[1] != "--marker":
        sys.stderr.write(
            "usage: review-manifest.py {record|check} --marker <path> [-- <git prefix args>]\n"
        )
        return CANNOT_EVALUATE

    mode = argv[0]
    marker_path = argv[2]
    rest = argv[3:]
    if rest and rest[0] == "--":
        rest = rest[1:]
    prefix = rest

    # Status reports repo-root-relative paths, so worktree files must be
    # resolved against the repo root — NOT against our own cwd, which may be a
    # subdirectory (approve mode runs wherever the shell happens to be). Ask git
    # with the same prefix the guarded command uses, so -C is honoured.
    try:
        prefix_cwd = decode(git_bytes(prefix, ["rev-parse", "--show-toplevel"])).strip()
    except CannotEvaluate:
        return CANNOT_EVALUATE
    if not prefix_cwd:
        # A bare repo has no worktree, so there is nothing to review.
        return CANNOT_EVALUATE

    try:
        if mode == "record":
            count = cmd_record(marker_path, prefix, prefix_cwd)
            sys.stdout.write("%d\n" % count)
            return ALLOW
        if mode == "check":
            verdict, paths = cmd_check(marker_path, prefix, prefix_cwd)
            for path in paths:
                sys.stdout.write("%s\n" % path)
            return verdict
    except CannotEvaluate:
        return CANNOT_EVALUATE
    except OSError:
        return CANNOT_EVALUATE

    return CANNOT_EVALUATE


if __name__ == "__main__":
    sys.exit(main())
