#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# public-scan.sh DIR
#
# Gate for anything bound for a public remote (CLAUDE.md, Pushing). Scans
# every file under DIR (tracked and untracked-not-ignored files if DIR is a
# git checkout, so files copied in before `git add` are covered; else all
# files, .git excluded) for host identity, contact details and credential
# shapes. Pass or fail only: exit 0 clean, 1 on any hit, 2 on bad usage.
# It does not replace reading the diff; it catches what reading misses.
#
# The email and IPv4 patterns also take an address whose at sign or dots are
# written as a Markdown backslash escape or an HTML character reference, which
# a page renders as a plain address. The password pattern is case-insensitive and
# takes a quoted key and value, so a JSON field and an upper-case shell
# variable are caught as well as a plain assignment.
# Token shapes beyond the vendor-prefixed ones: OpenAI-style, Google API, npm and
# GitLab keys, an Authorization Bearer value, and an assigned API key (a value
# that starts with $, <, { or % is a placeholder and passes).
#
# Deny list: each non-empty, non-# line of $PUBLIC_SCAN_DENY (default:
# public-scan.deny beside this script) is a term, matched case-insensitively
# as a fixed whole word. A missing file is skipped, so a public copy of this
# script runs without one. The terms are never printed except as matched lines.
# $PUBLIC_SCAN_TERMS adds terms, comma or newline separated, for environments
# where a deny file cannot be kept (e.g. a cloud environment variable).

set -u
dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: $0 DIR" >&2; exit 2; }

# label|regex, one per line; label|P|regex for a Perl regex (grep -P).
# Loopback 127.0.0.1 and the wildcard 0.0.0.0 identify nothing and pass.
patterns='
IPv4 address|P|\b(?!127[.]0[.]0[.]1\b|0[.]0[.]0[.]0\b)([0-9]{1,3}(?:\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)){3}[0-9]{1,3}\b
Tailscale MagicDNS name|[a-z0-9-]+\.ts\.net
email address|[A-Za-z0-9._%+-]+(\\?@|&#0*64;|&#[xX]0*40;|&commat;)([A-Za-z0-9-]|\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)+(\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)[A-Za-z]{2,}
US phone number|\b[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}\b
GitHub token|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}
Anthropic key|sk-ant-[A-Za-z0-9_-]{10,}
OpenAI-style key|P|\bsk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}
Google API key|AIza[0-9A-Za-z_-]{35}
npm token|npm_[A-Za-z0-9]{36}
GitLab token|glpat-[A-Za-z0-9_-]{20,}
Bearer header|P|(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}
assigned API key|P|(?i)(?<![A-Za-z0-9])api[_-]?key["\x27]?\s*[:=]\s*["\x27]?(?![$<{%])[^\s"\x27]{8,}
AWS access key|AKIA[0-9A-Z]{16}
Slack token|xox[abpr]-[A-Za-z0-9-]{10,}
Tailscale auth key|tskey-[a-z]+-[A-Za-z0-9-]{10,}
private key block|BEGIN [A-Z ]*PRIVATE KEY
WiFi PSK|psk[=]
assigned password|P|(?i)(password|passwd|secret)["\x27]?\s*[:=]\s*["\x27]?[^\s"\x27]{4,}
Cloudflare tunnel credentials|Tunnel[S]ecret|Account[T]ag
IPv6 address|P|(?i)(?<![0-9a-f:])(?!2001:0*db8:)(?:[23][0-9a-f]{3}|fd[0-9a-f]{2})(?::{1,2}[0-9a-f]{1,4}){2,}(?![0-9a-f])
MAC address|P|(?i)(?<![0-9a-f])(?!00(?::00){5}(?![0-9a-f]))(?!ff(?::ff){5}(?![0-9a-f]))(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])
'

# rev-parse exits 0 and prints "false" inside a .git directory or a bare
# repository, where ls-files lists nothing: only "true" takes the git branch.
if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
  files=$(git -C "$dir" ls-files -z --cached --others --exclude-standard | xargs -0 -I{} printf '%s\n' "$dir/{}")
else
  files=$(find "$dir" -path '*/.git' -prune -o -type f -print)
fi

hits=0
while IFS='|' read -r label rx rest; do
  [ -z "$label" ] && continue
  mode=-E
  if [ "$rx" = "P" ]; then mode=-P; rx=$rest; elif [ -n "$rest" ]; then rx="$rx|$rest"; fi
  out=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -HnI "$mode" -- "$rx" 2>/dev/null)
  if [ -n "$out" ]; then
    hits=1
    echo "FAIL  $label"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
done <<< "$patterns"

deny="${PUBLIC_SCAN_DENY:-$(dirname "$0")/public-scan.deny}"
terms=$(mktemp) && trap 'rm -f "$terms"' EXIT
if [ -f "$deny" ]; then
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$deny" >> "$terms"
fi
if [ -n "${PUBLIC_SCAN_TERMS:-}" ]; then
  printf '%s\n' "$PUBLIC_SCAN_TERMS" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' >> "$terms"
fi
if [ -s "$terms" ]; then
  out=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -HnIiwF -f "$terms" -- 2>/dev/null)
  if [ -n "$out" ]; then
    hits=1
    echo "FAIL  deny-list term"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
fi

if [ "$hits" -eq 0 ]; then echo "ok    no public-scan hits in $dir"; exit 0; fi
exit 1
