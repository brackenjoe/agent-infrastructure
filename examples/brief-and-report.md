# A builder brief and its report

A real pair from this setup, the job that extended `tools/public-scan.sh`.
Paths are shortened and the private terms replaced; nothing else is edited.
The manager wrote the brief; `builder` (Sonnet) did the work; the manager
then reran the checks before reporting anything as passed.

## The brief

> Work directory: the repo root (main checkout; small change, no worktree).
> Joe asked for the public repo to be scrubbed; this brief adds three
> checks to its gate script.
>
> **File you may edit:** `tools/public-scan.sh` ONLY. Do not edit
> `tools/README.md` (the manager owns it), do not commit or push. Fixtures
> go in a scratch directory and are deleted at the end.
>
> **Pattern to copy:** the existing `patterns` heredoc (`label|regex`, or
> `label|P|regex` for `grep -P`) and the existing hit-reporting loop.
>
> **Design (settled):**
> 1. IPv6 pattern, label `IPv6 address`, `grep -P`, case-insensitive. Match
>    global unicast (first group `2xxx` or `3xxx`) and ULA (`fdxx`, which
>    covers Tailscale's own prefix) followed by at least two more
>    groups. The documentation prefix `2001:db8:` must pass; `::1`, a clock
>    time like `12:34:56`, and `fe80::1` must pass.
> 2. MAC address pattern: six colon-separated hex pairs.
>    `00:00:00:00:00:00` and `ff:ff:ff:ff:ff:ff` must pass.
> 3. Deny list. Path = `$PUBLIC_SCAN_DENY` if set, else
>    `public-scan.deny` beside the script. Every non-empty line not starting
>    with `#` is a term, matched case-insensitively as a fixed string. A hit
>    prints `FAIL  deny-list term` with the hits. A missing file is skipped
>    silently (the public copy of the script has no deny file).
>
> Do not change the file selection logic or the exit codes (0 clean,
> 1 hit, 2 usage).
>
> **Checks to run, report each with pass/fail counts:**
> a. A fixture per case: each positive must FAIL with its label, each
>    negative in a directory of its own must exit 0.
> b. `PUBLIC_SCAN_DENY=/nonexistent` on a clean dir: exit 0.
> c. The existing 12 patterns still fire, one fixture line each.
> d. `bash -n` clean; no arguments exits 2.
> e. The scanner on a clone of the public repo, which still contains a
>    private term: report exactly what it prints.

## The report (abridged)

> Edited only `tools/public-scan.sh`; nothing committed; fixture dir deleted.
>
> **Changed:** header comment (4 lines on the deny list); two `-P` pattern
> rows; a deny block after the pattern loop that strips comments and blanks
> into a temp file removed by an `EXIT` trap, runs `grep -HnIiF -f` over the
> same file list, and sets `hits=1` on a hit.
>
> **Checks:** a, positives 4 of 4 FAIL with the right label; negatives 7 of 7
> exit 0. b exit 0. c all 12 old labels fired. d clean, exit 2. e exit 1,
> one `deny-list term` hit in an agent file, nothing else.
>
> **Not verified:** not run on a git checkout, so the untracked-file path is
> not exercised with the new checks. The IPv6 pattern is not tested against
> full 8-group addresses. If a scanned tree contains the deny file itself,
> the file matches its own terms.

The "not verified" section is the useful part: it told the manager which
checks to add when rerunning them, rather than which to trust.
