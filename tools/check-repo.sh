#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bracken Systems LLC
#
# Checks that the repo's own rules are being kept. Run before finishing a
# job; CLAUDE.md says finishing means this passes. Exit 1 on any FAIL.
#
# An example tied to one layout: it expects work/, BRACKENCLAUDEBOX.md and
# tools/README.md at the repo root, so it fails on a repo without them,
# including the public agent-infrastructure repo as published. Adapt the
# checks to your own layout.
#
#   tools/check-repo.sh
#
# The two host checks (system capture, $HOME) run only on the box named by
# CHECK_REPO_BOX (default brackenclaudebox) and print skip elsewhere, so a
# cloud session on a fresh VM is not failed by a machine it is not on.
#
# What it checks, each against the rule it enforces:
#   tools index    every tracked entry directly under tools/ is named in
#                  tools/README.md                       (CLAUDE.md, tools)
#   job records    every work/<project>/ has a README.md and a row in Parts
#                  made in BRACKENCLAUDEBOX.md; in an index (a README with
#                  the "| part | what | was |" table, at any depth) every
#                  subdirectory has a README.md and a link from the index
#                                                          (CLAUDE.md, finishing)
#   links          every relative markdown link in our own .md files
#                  resolves (CHANGELOGs, captures, third-party trees and
#                  the public guide's source, whose links resolve only in
#                  the stage publish-agent-infra.sh checks, are left out).
#                  File names are read NUL-separated, so a space is fine;
#                  a checker that exits nonzero is a FAIL, never a pass
#                                                              (CLAUDE.md, layout)
#   script lint    every tracked .sh under tools/, at any depth, has no
#                  finding from the linter at warning level or above (notes and
#                  style findings do not fail); runs wherever shellcheck is
#                  installed; on the box a missing shellcheck is a FAIL,
#                  elsewhere the check is skipped     (tools/README.md, Checkers)
#   worktrees      no worktree other than the main checkout has been idle
#                  for a day: the newest file in it, .git aside, is under
#                  24 h old                                (CLAUDE.md, worktrees)
#   system capture every file under system/files/ matches the live file it
#                  was copied from                         (system/README.md)
#   $HOME          holds dotfiles and the repo and nothing else (CLAUDE.md)
#   repo root      nothing untracked sits at the top of the repo; scratch
#                  files go in a scratch directory         (CLAUDE.md, Scope)
set -uo pipefail
shopt -s nullglob
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0
FAIL() { echo "FAIL  $*"; fail=1; }
OK()   { echo "ok    $*"; }
SKIP() { echo "skip  $*"; }
BOX="${CHECK_REPO_BOX:-brackenclaudebox}"
ONBOX=0; [ "$(hostname)" = "$BOX" ] && ONBOX=1

# tools index
missing=()
for e in $(git ls-files tools | cut -d/ -f2 | sort -u); do
  [ "$e" = "README.md" ] && continue
  grep -q -- "$e" tools/README.md || missing+=("$e")
done
[ ${#missing[@]} -eq 0 ] && OK "every tools/ entry is in tools/README.md" \
  || FAIL "tools/ entries with no row in tools/README.md: ${missing[*]}"

# job records
# An index is a directory whose README.md holds the table header
# "| part | what | was |" (CLAUDE.md, layout): every subdirectory is then a
# part, or another index, and needs a README and a link from the index.
check_index() {
  local t="$1" p
  grep -qx '| part | what | was |' "$t/README.md" 2>/dev/null || return
  for p in $(git ls-files "$t" | sed "s|^$t/||" | grep / | cut -d/ -f1 | sort -u); do
    [ -f "$t/$p/README.md" ] || FAIL "$t/$p has no README.md"
    grep -q -- "]($p/" "$t/README.md" || FAIL "$t/$p has no link in $t/README.md"
    check_index "$t/$p"
  done
}
for d in work/*/; do
  t="${d%/}"
  [ -f "$t/README.md" ] || FAIL "$t has no README.md"
  grep -q -- "\`$t\`" BRACKENCLAUDEBOX.md || FAIL "$t has no row in Parts made"
  check_index "$t"
done
projects=(work/*/)
OK "job records checked (${#projects[@]} projects)"

# links
# Names are NUL-separated (git ls-files -z, grep -z), so a name with a space
# survives. The checker's exit status is read: a crash is a FAIL, not an empty
# list that reads as a pass. PIPESTATUS is [git, grep, python3]; grep exits 1
# when it drops every name, which is not an error.
lk=$(mktemp)
git ls-files -z '*.md' | grep -z -v -e '^tools/ardupilot' -e '^tools/ap-' -e '^tools/ExpressLRS' \
    -e '^tools/elrs-' -e '^tools/mLRS' -e 'CHANGELOG.md$' -e '/system/files/' \
    -e '^work/personal/github-agent-ops/public/' | python3 -c '
import os, re, sys
for n in sys.stdin.buffer.read().split(b"\0"):
    if not n:
        continue
    f = os.fsdecode(n)
    for m in re.finditer(r"\]\(([^)#\s]+)(#[^)]*)?\)", open(f, encoding="utf-8", errors="replace").read()):
        t = m.group(1)
        if not re.match(r"[a-z]+:", t) and not os.path.exists(os.path.join(os.path.dirname(f), t)):
            print(f"{f} -> {t}")
' >"$lk"
st=("${PIPESTATUS[@]}")
rc=${st[2]}; [ "$rc" -eq 0 ] && rc=${st[0]}
broken=$(<"$lk"); rm -f "$lk"
[ -n "$broken" ] && echo "$broken" | sed 's/^/      /'
if [ "$rc" -ne 0 ]; then FAIL "link checker failed (exit $rc)"
elif [ -n "$broken" ]; then FAIL "broken markdown links, listed above"
else OK "every relative markdown link resolves"; fi

# Script lint. Every tracked .sh under tools/, at any depth (a plain pathspec
# * crosses slashes); the third-party trees under tools/ are skipped because
# they are untracked. -S warning leaves notes and style findings alone.
# --norc: an rc file in a parent directory could otherwise disable every
# check. In-file disable directives still apply and stay visible in review.
# Exit 0 is clean, 1 is findings; anything else, or findings claimed with no
# output, means it did not run. No tracked script at all means git failed.
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -d '' -t shfiles < <(git ls-files -z "tools/*.sh")
  if [ ${#shfiles[@]} -eq 0 ]; then
    FAIL "shellcheck: no tracked .sh under tools/ found (git ls-files failed?)"
  else
    sc=$(shellcheck --norc -S warning -f gcc "${shfiles[@]}" 2>&1); rc=$?
    if [ "$rc" -gt 1 ] || { [ "$rc" -ne 0 ] && [ -z "$sc" ]; }; then
      [ -n "$sc" ] && echo "$sc" | sed 's/^/      /'
      FAIL "shellcheck did not run (exit $rc)"
    elif [ -n "$sc" ]; then
      echo "$sc" | sed 's/^/      /'
      FAIL "shellcheck warnings in tools/, listed above"
    else
      OK "shellcheck: no warnings in ${#shfiles[@]} tracked .sh under tools/"
    fi
  fi
elif [ "$ONBOX" -eq 1 ]; then
  FAIL "shellcheck is not installed (apt install shellcheck)"
else
  SKIP "shellcheck: not installed here, not on $BOX"
fi

# worktrees
# Idle time, not folder age: a folder's mtime moves only when a top-level
# entry is added or removed, so a worktree under daily edits would read old.
# Idle is now minus the newest mtime of any file, .git excluded; 0 from awk
# means find saw no file (a missing or empty worktree), which is also a FAIL.
now=$(date +%s)
wt=$(mktemp)
git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print}' | while read -r w; do
  [ "$w" = "$ROOT" ] && continue
  newest=$(find "$w" -name .git -prune -o -type f -printf '%T@\n' 2>/dev/null \
    | awk '$1 > m {m = $1} END {printf "%d\n", m}')
  if [ "$newest" -eq 0 ]; then echo "FAIL  worktree $w has no files; remove it: git worktree remove, or git worktree prune"; continue; fi
  idle=$(( (now - newest) / 3600 ))
  if [ "$idle" -ge 24 ]; then echo "FAIL  worktree $w idle for ${idle}h (newest file); finish it: merge, push, remove, delete the branch"; fi
done | tee "$wt" ; grep -q FAIL "$wt" && fail=1; rm -f "$wt"
OK "worktrees checked"

# system capture (host check: only on the box)
if [ "$ONBOX" -eq 1 ]; then
  drift=()
  while IFS= read -r f; do
    rel="${f#system/files/}"; live="/$rel"
    [ -r "$live" ] || { drift+=("$live (unreadable here)"); continue; }
    cmp -s "$f" "$live" || drift+=("$live")
  done < <(git ls-files system/files)
  [ ${#drift[@]} -eq 0 ] && OK "system/ capture matches the live files" \
    || FAIL "system/ capture is stale for: ${drift[*]}; run tools/capture-system-config.sh"
else
  SKIP "system/ capture: not on $BOX"
fi

# $HOME (host check: only on the box)
if [ "$ONBOX" -eq 1 ]; then
  # the main checkout's name, also from a worktree
  MAIN=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
  stray=$(find "$HOME" -maxdepth 1 -mindepth 1 ! -name '.*' ! -name "$MAIN" -printf '%f ')
  [ -z "$stray" ] && OK "\$HOME holds only dotfiles and $MAIN/" \
    || FAIL "loose entries in \$HOME: $stray"
else
  SKIP "\$HOME: not on $BOX"
fi

# repo root
# Untracked, non-ignored entries directly at the root: top-level files, and
# top-level directories (listed once, with a trailing slash). Deeper paths
# have a slash before the end and are other checks' business.
loose=$(git ls-files --others --exclude-standard --directory | grep -Ev '/.' | tr '\n' ' ')
[ -z "$loose" ] && OK "nothing untracked at the repo root" \
  || FAIL "untracked entries at the repo root: ${loose% }; delete them or move them to a scratch directory"

exit $fail
