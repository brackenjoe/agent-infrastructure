#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# Is a GitHub repo public? A push to a public remote needs the owner's
# approval every time, so this decides "public", "private" or "ask".
#
#   tools/check-visibility.sh OWNER REPO
#   tools/check-visibility.sh --selftest     offline, curl replaced by a stub
#
# Prints exactly one word on stdout:
#   public    status 200 and the body has "visibility": "public"
#   private   status 200 and the body has "visibility": "private", or the
#             status is 404 with no visibility field. An unauthenticated
#             request to a private repo is a 404, but so is one to a repo
#             that does not exist: a misspelt name also prints "private".
#             Check against the remote's own URL, not a name typed by hand.
#   ask       anything else: 403, 5xx, 000 (no connection), an empty or
#             unparsable answer, a visibility field that is neither, or a
#             body holding both. Ask the owner. Do not push, and do not
#             read it as private.
# Exit status: 0 public or private, 2 ask, 1 bad usage.
#
# Proxy caveat (Claude Code on the web, observed 2026-10-17): through the
# session's git proxy a private repo can answer 200, and a repo not attached
# to the session answers 403 even when public. A 200 is still judged by its
# body, so "public" and a 200 "private" hold; a "private" from a 404 proves
# less there. Either way, read the diff for credentials before the push.
#
# A visibility field is believed only with status 200; the same field with
# any other status is "ask".
set -uo pipefail

# visibility OWNER REPO -> prints the word, returns 0 or 2
visibility() {
  local out status body
  out=$(curl -s --max-time 20 -w '\n%{http_code}\n' "https://api.github.com/repos/$1/$2" 2>/dev/null) || true
  # the last non-empty line is the status; everything before it is the body
  status=$(printf '%s\n' "$out" | awk 'NF {s = $0} END {print s}')
  body=$(printf '%s\n' "$out" | sed '$d')
  local pub=0 priv=0
  printf '%s' "$body" | grep -Eq '"visibility"[[:space:]]*:[[:space:]]*"public"' && pub=1
  printf '%s' "$body" | grep -Eq '"visibility"[[:space:]]*:[[:space:]]*"private"' && priv=1
  if [ "$status" = 200 ] && [ $pub -eq 1 ] && [ $priv -eq 0 ]; then
    echo public; return 0
  elif [ "$status" = 200 ] && [ $priv -eq 1 ] && [ $pub -eq 0 ]; then
    echo private; return 0
  elif [ "$status" = 404 ] && ! printf '%s' "$body" | grep -q '"visibility"'; then
    echo private; return 0
  fi
  echo ask; return 2
}

selftest() {
  local pass=0 failn=0 got rc STUB
  # curl is shadowed by a function that answers with the case's stub text
  curl() { printf '%s' "$STUB"; }
  # each case: name, wanted word, wanted exit, stub output
  check() {
    STUB=$4
    got=$(visibility o r); rc=$?
    if [ "$got" = "$2" ] && [ "$rc" -eq "$3" ]; then
      pass=$((pass + 1)); echo "ok    $1"
    else
      failn=$((failn + 1)); echo "FAIL  $1: got '$got' rc=$rc, want '$2' rc=$3"
    fi
  }
  check "public body"            public  0 $'{\n  "id": 1,\n  "private": false,\n  "visibility": "public"\n}\n\n200\n'
  check "private body"           private 0 $'{\n  "private": true,\n  "visibility": "private"\n}\n\n200\n'
  check "bare 404"               private 0 $'{"message": "Not Found"}\n\n404\n'
  check "404 with empty body"    private 0 $'\n404\n'
  check "403"                    ask     2 $'{"message": "rate limit"}\n\n403\n'
  check "000 and empty body"     ask     2 $'\n000\n'
  check "wholly empty"           ask     2 ''
  check "500"                    ask     2 $'oops\n\n500\n'
  check "200 unparsable"         ask     2 $'<html>proxy</html>\n\n200\n'
  check "200 internal visibility" ask    2 $'{"visibility": "internal"}\n\n200\n'
  check "403 with visibility"    ask     2 $'{"visibility": "public"}\n\n403\n'
  check "404 with visibility"    ask     2 $'{"visibility": "public"}\n\n404\n'
  echo "$pass passed, $failn failed"
  [ "$failn" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ] && [ $# -eq 1 ]; then
  selftest; exit $?
fi
re='^[A-Za-z0-9_.][A-Za-z0-9._-]*$'   # no leading dash: an option, not a name
# "." and ".." pass the pattern but collapse out of the URL path.
if [ $# -ne 2 ] || ! [[ $1 =~ $re ]] || ! [[ $2 =~ $re ]] \
   || [[ $1 == . || $1 == .. || $2 == . || $2 == .. ]]; then
  echo "usage: $0 OWNER REPO | --selftest" >&2
  exit 1
fi
visibility "$1" "$2"
