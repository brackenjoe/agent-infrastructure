#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bracken Systems LLC
#
# Keeps a Claude Code Remote Control server alive inside tmux, started at boot
# by ~/.config/systemd/user/claude-remote.service.
#
# Three things here are load-bearing and were each learned the hard way:
#
# 1. WORKDIR must be a real project directory, never $HOME. The `remote-control`
#    subcommand refuses to start in a home directory ("home-directory trust is
#    never saved") and there is no dialog to accept, so the loop just spins on
#    the error. WORKDIR below is the working root and must be trusted.
#
# 2. The pre-created session is deliberately KEPT. --no-create-session-in-dir
#    stops the empty-session sprawl in the phone list, but it also leaves the
#    tmux console with nothing to type into, and measurement
#    showed there is no recovery from that: no console key spawns a session,
#    and a plain `claude` in the same directory does not register with the
#    running server (Capacity stayed 0/32). A session you can reach from both
#    SSH and the phone beats one fewer empty entry per boot.
#
# 3. --spawn=same-dir. First run in a new project directory otherwise stops on an
#    interactive "Choose [1/2]" spawn-mode prompt, which no boot service can
#    answer. Passing it explicitly makes the launch non-interactive.
#
# Note the flag lives on the `remote-control` SUBCOMMAND, not on the older
# `--remote-control` option form.

set -u

WORKDIR="$HOME/agents"   # your repo root; never $HOME itself
CLAUDE="$HOME/.local/bin/claude"

cd "$WORKDIR" || { echo "FATAL: cannot cd to $WORKDIR" >&2; exit 1; }

# Fail loudly instead of spinning: without trust, every iteration is a certain
# error and no amount of retrying fixes it. This reads hasTrustDialogAccepted
# from ~/.claude.json, an internal format Claude Code does not document: if a
# release changes it, this check reports "not trusted" wrongly. Check by hand.
if ! python3 - "$WORKDIR" <<'PY'
import json, os, sys
try:
    d = json.load(open(os.path.expanduser('~/.claude.json')))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get('projects', {}).get(sys.argv[1], {}).get('hasTrustDialogAccepted') else 1)
PY
then
  echo "FATAL: $WORKDIR is not trusted. Run 'claude' there once and accept the" >&2
  echo "       workspace trust dialog, then: systemctl --user restart claude-remote" >&2
  exit 1
fi

# Back off on rapid repeated failures so a permanent fault logs slowly rather
# than filling the pane at 12 lines a minute.
fails=0
while true; do
  started=$(date +%s)
  "$CLAUDE" remote-control \
    --spawn=same-dir \
    --permission-mode auto \
    --name agent-server
  ran=$(( $(date +%s) - started ))

  if [ "$ran" -ge 60 ]; then
    fails=0
    delay=5
  else
    fails=$(( fails + 1 ))
    delay=$(( 5 * fails ))
    [ "$delay" -gt 300 ] && delay=300
    echo "$(date -Is) remote-control exited after ${ran}s (failure #${fails}), retrying in ${delay}s" >&2
  fi
  sleep "$delay"
done
