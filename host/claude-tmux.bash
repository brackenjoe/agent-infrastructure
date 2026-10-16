# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bracken Systems LLC
# Append to ~/.bashrc. A bare `claude` over SSH attaches to (or creates) a
# tmux session named work, so a dropped connection loses nothing; with
# arguments it runs claude as normal.
claude() {
  if [ $# -eq 0 ] && [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t work 2>/dev/null; then
      tmux attach -t work
    else
      tmux new-session -s work -c "$HOME/agents" \
        "$HOME/.local/bin/claude --permission-mode auto --remote-control work"
    fi
    return
  fi
  command claude "$@"
}
