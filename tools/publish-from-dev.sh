#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bracken Systems LLC
#
# Publishes the dev repo to the public repo by fast-forward. Run from a clone
# of the private dev repo (agent-infrastructure-dev), whose history is the
# public history plus unpublished commits. Pushing is a public act that
# cannot be undone: the owner approves it each time. Without --push this is a
# dry run and nothing leaves the machine.
#
#   tools/publish-from-dev.sh [--push]
#
# Exit 0 if nothing to publish, or every gate passed; 1 if any gate FAILed
# (a --push is then refused and pushes nothing); 2 on a precondition error.
#
# Preconditions (exit 2): clean working tree; current branch is main; at
# least one term in PUBLIC_SCAN_TERMS (the scan cannot be trusted without the
# private terms); local main equals origin main (publish only merged work);
# a target: PUBLISH_PUBLIC_URL if set, else the URL of a remote named
# public. There is no default, and the target is printed first.
#
# It fetches public main and compares it with HEAD. Equal: nothing to
# publish. Public main not an ancestor of HEAD: public has commits this repo
# lacks, so merge them into main first (exit 2).
#
# Gates, each fail closed: on the tree at HEAD, tools/public-scan.sh clean;
# no em dash in tracked files; every relative markdown link resolves; no
# tracked file named public-scan.deny. Then on the history: every commit in
# public..HEAD (messages, identities, every diff) goes through the scanner,
# after masking email addresses already in public history (and
# @users.noreply.github.com ones), so a new address cannot go public unseen;
# and no message may carry a Claude-Session: line (a cloud session link would
# go public; set attribution.sessionUrl to false and rewrite or squash). A
# dry run also does git push --dry-run, which tests authentication. It then
# lists the commits with author and committer and the diff stat to be
# published.
#
# --push, only if every gate passed: git push --no-follow-tags --atomic
# TARGET SHA:refs/heads/main, with SHA resolved once before the gates. Never
# --force, never tags. Tags are made on GitHub's Releases page.
set -uo pipefail
USAGE="usage: tools/publish-from-dev.sh [--push]"
fail=0
FAIL() { echo "FAIL  $*"; fail=1; }
OK()   { echo "ok    $*"; }

push=0
case "${1:-}" in
  "") ;;
  --push) push=1 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then echo "$USAGE" >&2; exit 2; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "not inside a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean: commit or discard changes first" >&2
  git status --short >&2
  exit 2
fi
branch=$(git symbolic-ref --short -q HEAD || true)
if [ "$branch" != "main" ]; then
  echo "current branch is '${branch:-detached HEAD}', not main: check out main first" >&2
  exit 2
fi
terms=$(printf '%s\n' "${PUBLIC_SCAN_TERMS:-}" | tr ',' '\n' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$')
if [ -z "$terms" ]; then
  echo "the private terms are not configured, so the scan cannot be trusted; set PUBLIC_SCAN_TERMS in the cloud environment" >&2
  exit 2
fi

HEAD_SHA=$(git rev-parse HEAD) || exit 2

git fetch -q origin main || { echo "fetch of origin main failed" >&2; exit 2; }
ORIGIN_MAIN=$(git rev-parse FETCH_HEAD) || { echo "cannot read fetched origin main" >&2; exit 2; }
if [ "$HEAD_SHA" != "$ORIGIN_MAIN" ]; then
  echo "local main differs from origin main; publish only merged work" >&2
  exit 2
fi

PUBLIC_URL="${PUBLISH_PUBLIC_URL:-}"
if [ -z "$PUBLIC_URL" ]; then
  PUBLIC_URL=$(git remote get-url public 2>/dev/null || true)
fi
if [ -z "$PUBLIC_URL" ]; then
  echo "no target: set PUBLISH_PUBLIC_URL in the cloud environment or add a remote named public" >&2
  exit 2
fi
echo "target: $PUBLIC_URL"

git fetch -q "$PUBLIC_URL" main || { echo "fetch of $PUBLIC_URL main failed" >&2; exit 2; }
PUB=$(git rev-parse FETCH_HEAD) || { echo "cannot read fetched public main" >&2; exit 2; }
if [ "$HEAD_SHA" = "$PUB" ]; then
  echo "nothing to publish"
  exit 0
fi
if ! git merge-base --is-ancestor "$PUB" "$HEAD_SHA"; then
  FAIL "public main has commits this repo lacks: merge them into main first"
  git log --oneline "$HEAD_SHA..$PUB"
  exit 2
fi

# Gate 1: the scanner
if "$ROOT/tools/public-scan.sh" "$ROOT"; then
  OK "public-scan.sh clean"
else
  FAIL "public-scan.sh reported findings, listed above"
fi

# Gate 2: em dashes in tracked files
dashes=$(git grep -nI -F $'\xe2\x80\x94' -- . 2>/dev/null)
rc=$?
if [ "$rc" -gt 1 ]; then
  FAIL "em dash check did not run"
elif [ -z "$dashes" ]; then
  OK "no em dash in tracked files"
else
  echo "$dashes" | sed 's/^/      /'
  FAIL "em dashes in tracked files, listed above"
fi

# Gate 3: relative markdown links
if ! command -v python3 >/dev/null 2>&1; then
  broken=""
  rc=127
else
  broken=$(git ls-files -z '*.md' | python3 -c '
import os, re, sys
for f in sys.stdin.read().split("\0"):
    if not f:
        continue
    for m in re.finditer(r"\]\(([^)#\s]+)(#[^)]*)?\)", open(f, encoding="utf-8", errors="replace").read()):
        t = m.group(1)
        if not re.match(r"[a-z]+:", t) and not os.path.exists(os.path.join(os.path.dirname(f), t)):
            print(f"{f} -> {t}")
')
  rc=$?
fi
if [ "$rc" -ne 0 ]; then
  FAIL "link check did not run"
elif [ -z "$broken" ]; then
  OK "every relative markdown link resolves"
else
  echo "$broken" | sed 's/^/      /'
  FAIL "broken markdown links, listed above"
fi

# Gate 4: the deny file lists private terms and must never be tracked
denied=$(git ls-files | awk -F/ '$NF == "public-scan.deny"')
if [ -z "$denied" ]; then
  OK "no public-scan.deny is tracked"
else
  echo "$denied" | sed 's/^/      /'
  FAIL "public-scan.deny is tracked; it lists private terms"
fi

# Gate 5: the history. Every commit in PUB..HEAD goes through the scanner, so
# something added and removed again, or written only in a message or an
# identity, is still seen. Email addresses already in public history (and
# @users.noreply.github.com ones) are masked first; any other address still
# trips the scanner's email pattern. Cloud session links must not go public.
tmp=$(mktemp -d) || { echo "cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/scan" || exit 2
EMAIL_RX='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z][A-Za-z]+'
if git log "$PUB" --format='%ae%n%ce%n%B' > "$tmp/public-log.txt"; then
  grep -oiE "$EMAIL_RX" "$tmp/public-log.txt" | tr 'A-Z' 'a-z' | sort -u > "$tmp/public-emails.txt"
  echo "emails already public: $(wc -l < "$tmp/public-emails.txt" | tr -d ' ') (masked before the history scan)"
else
  : > "$tmp/public-emails.txt"
  FAIL "public history could not be read"
fi
if git log -p --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%n%n%B' \
     "$PUB..$HEAD_SHA" > "$tmp/history.raw"; then
  awk -v list="$tmp/public-emails.txt" -v rx="$EMAIL_RX" '
    BEGIN { while ((getline l < list) > 0) ok[l] = 1 }
    { line = $0; out = ""
      while (match(line, rx)) {
        a = substr(line, RSTART, RLENGTH); k = tolower(a)
        if (k in ok || k ~ /@users[.]noreply[.]github[.]com$/) a = "<public-email>"
        out = out substr(line, 1, RSTART - 1) a
        line = substr(line, RSTART + RLENGTH)
      }
      print out line }' "$tmp/history.raw" > "$tmp/scan/history.txt" \
    || FAIL "history could not be masked"
  if "$ROOT/tools/public-scan.sh" "$tmp/scan"; then
    OK "public-scan.sh clean on the history"
  else
    FAIL "public-scan.sh reported findings in the history, listed above"
  fi
else
  FAIL "history could not be read"
fi
# (a file, not a pipe into grep -q: SIGPIPE under pipefail would read as no match)
if ! git log --format=%B "$PUB..$HEAD_SHA" > "$tmp/messages.txt"; then
  FAIL "commit messages could not be read"
elif grep '^Claude-Session:' "$tmp/messages.txt" > /dev/null; then
  FAIL "a commit message has a Claude-Session: line; cloud session links would go public; set attribution.sessionUrl to false and rewrite or squash those commits"
else
  OK "no Claude-Session: line in commit messages"
fi

# Gate 6 (dry run only): would the push be accepted? Tests authentication.
if [ "$push" -eq 0 ]; then
  if out=$(git push --dry-run --no-follow-tags "$PUBLIC_URL" "$HEAD_SHA:refs/heads/main" 2>&1); then
    OK "push would be accepted"
  else
    echo "$out" | sed 's/^/      /'
    FAIL "push would not be accepted, listed above"
  fi
fi

echo
echo "commits to publish (git log ${PUB:0:7}..${HEAD_SHA:0:7}; author | committer | subject):"
git log --format='%h %an <%ae> | %cn <%ce> | %s' "$PUB..$HEAD_SHA"
echo
echo "git diff --stat ${PUB:0:7} ${HEAD_SHA:0:7}:"
git diff --stat "$PUB" "$HEAD_SHA"
echo

if [ "$push" -eq 0 ]; then
  echo "dry run: nothing pushed. With the owner's approval, rerun with --push."
  exit $fail
fi

if [ "$fail" -ne 0 ]; then
  echo "refused: a gate FAILed, nothing pushed" >&2
  exit 1
fi

git push --no-follow-tags --atomic "$PUBLIC_URL" "$HEAD_SHA:refs/heads/main" || { echo "push failed" >&2; exit 2; }
echo "pushed ${PUB:0:7}..${HEAD_SHA:0:7} to $PUBLIC_URL main"
echo "tag a new version, if the AI-followed pages changed, on GitHub's Releases page: cloud sessions cannot push tags"
exit 0
