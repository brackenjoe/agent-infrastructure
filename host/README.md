# host

Working copies of the agent server's hand-made files, from the live box with
the paths and names replaced: `$HOME/agents` is the repo root, `agent-server`
the Remote Control name. [The agent server](../docs/agent-server.md) says
why each exists. The unit here drops the live one's `network-online.target`
lines, which do nothing in a user unit; the loop backs off instead. MIT,
like the rest of the code here.

| File | Goes to | Does |
|---|---|---|
| `claude-remote.service` | `~/.config/systemd/user/` | starts the Remote Control loop in tmux at boot; `KillMode=process` keeps other tmux sessions alive on stop |
| `claude-remote-loop.sh` | `~/.local/bin/`, executable | refuses to run in an untrusted directory, then keeps `claude remote-control` running with back-off |
| `claude-tmux.bash` | append to `~/.bashrc` | a bare `claude` over SSH attaches to or creates a tmux session |
| `99-lid.conf` | `/etc/systemd/logind.conf.d/` | a laptop keeps running with the lid shut |
| `60-panic-reboot.conf`, `61-lockup-panic.conf` | `/etc/sysctl.d/` | a panic or detected lockup reboots the box |
| `10-hardening.conf` | `/etc/ssh/sshd_config.d/` | no password logins; sorts before `50-cloud-init.conf`, whose `yes` would otherwise win |

Then:

    systemctl --user daemon-reload && systemctl --user enable --now claude-remote
    loginctl enable-linger "$USER"
    sudo sysctl --system && sudo sshd -t && sudo systemctl reload ssh

Test `sshd -t` and a second SSH login before closing the one you are in.
Mask the sleep targets separately:
`sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
