#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bracken Systems LLC
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
# Deny list: each non-empty, non-# line of $PUBLIC_SCAN_DENY (default:
# public-scan.deny beside this script) is a term, matched case-insensitively
# as a fixed whole word. A missing file is skipped, so a public copy of this
# script runs without one. The terms are never printed except as matched lines.

set -u
dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: $0 DIR" >&2; exit 2; }

# label|regex, one per line; label|P|regex for a Perl regex (grep -P).
# Loopback 127.0.0.1 and the wildcard 0.0.0.0 identify nothing and pass.
patterns='
IPv4 address|P|\b(?!127\.0\.0\.1\b|0\.0\.0\.0\b)([0-9]{1,3}\.){3}[0-9]{1,3}\b
Tailscale MagicDNS name|[a-z0-9-]+\.ts\.net
email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
US phone number|\b[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}\b
GitHub token|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}
Anthropic key|sk-ant-[A-Za-z0-9_-]{10,}
AWS access key|AKIA[0-9A-Z]{16}
Slack token|xox[abpr]-[A-Za-z0-9-]{10,}
private key block|BEGIN [A-Z ]*PRIVATE KEY
WiFi PSK|psk[=]
assigned password|(password|passwd|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]{4,}
Cloudflare tunnel credentials|Tunnel[S]ecret|Account[T]ag
IPv6 address|P|(?i)(?<![0-9a-f:])(?!2001:0*db8:)(?:[23][0-9a-f]{3}|fd[0-9a-f]{2})(?::{1,2}[0-9a-f]{1,4}){2,}(?![0-9a-f])
MAC address|P|(?i)(?<![0-9a-f])(?!00(?::00){5}(?![0-9a-f]))(?!ff(?::ff){5}(?![0-9a-f]))(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])
'

if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
if [ -f "$deny" ]; then
  terms=$(mktemp) && trap 'rm -f "$terms"' EXIT
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$deny" > "$terms"
  if [ -s "$terms" ]; then
    out=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -HnIiwF -f "$terms" -- 2>/dev/null)
    if [ -n "$out" ]; then
      hits=1
      echo "FAIL  deny-list term"
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
  fi
fi

if [ "$hits" -eq 0 ]; then echo "ok    no public-scan hits in $dir"; exit 0; fi
exit 1
