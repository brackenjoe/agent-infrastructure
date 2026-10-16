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
#                  the stage publish-agent-infra.sh checks) (CLAUDE.md, layout)
#   worktrees      no worktree other than the main checkout is older than
#                  a day                                   (CLAUDE.md, worktrees)
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
broken=$(git ls-files '*.md' | grep -v -e '^tools/ardupilot' -e '^tools/ap-' -e '^tools/ExpressLRS' \
    -e '^tools/elrs-' -e '^tools/mLRS' -e 'CHANGELOG.md$' -e '/system/files/' \
    -e '^work/personal/github-agent-ops/public/' | python3 -c '
import os, re, sys
for f in sys.stdin.read().split():
    for m in re.finditer(r"\]\(([^)#\s]+)(#[^)]*)?\)", open(f, encoding="utf-8", errors="replace").read()):
        t = m.group(1)
        if not re.match(r"[a-z]+:", t) and not os.path.exists(os.path.join(os.path.dirname(f), t)):
            print(f"{f} -> {t}")
')
[ -z "$broken" ] && OK "every relative markdown link resolves" \
  || { echo "$broken" | sed 's/^/      /'; FAIL "broken markdown links, listed above"; }

# worktrees
now=$(date +%s)
wt=$(mktemp)
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r w; do
  [ "$w" = "$ROOT" ] && continue
  age=$(( (now - $(stat -c %Y "$w")) / 3600 ))
  if [ "$age" -ge 24 ]; then echo "FAIL  worktree $w is ${age}h old; finish it: merge, push, remove, delete the branch"; fi
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
