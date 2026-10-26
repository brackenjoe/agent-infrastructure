# host

Working copies of the agent server's hand-made files, from the live box with
the paths and names replaced: `$HOME/agents` is the repo root, `agent-server`
the Remote Control name, `claude` the agent's account. [The agent
server](../docs/agent-server.md) and [the agent as its own
user](../docs/agent-account.md) say why each exists. The unit here drops the
live one's `network-online.target` lines, which do nothing in a user unit;
the loop backs off instead. MIT, like the rest of the code here.

| File | Goes to | Does |
|---|---|---|
| `90-agent-allowlist` | `/etc/sudoers.d/`, mode 0440, root | everything the agent's account may run as root: reads with fixed flags, and `apt-get --no-remove install` by package name; install beside any existing file, never over it (its header has the steps and the probes) |
| `claude-remote.service` | the agent's `~/.config/systemd/user/` | starts the Remote Control loop in tmux at boot; `KillMode=process` keeps other tmux sessions alive on stop |
| `claude-remote-loop.sh` | the agent's `~/.local/bin/`, executable | refuses to run in an untrusted directory, then keeps `claude remote-control` running with back-off |
| `claude-tmux.bash` | append to the agent's `~/.bashrc` | a bare `claude` over SSH attaches to or creates a tmux session |
| `99-lid.conf` | `/etc/systemd/logind.conf.d/` | a laptop keeps running with the lid shut |
| `60-panic-reboot.conf`, `61-lockup-panic.conf` | `/etc/sysctl.d/` | a panic or detected lockup reboots the box |
| `10-hardening.conf` | `/etc/ssh/sshd_config.d/` | no password or root logins, no agent or TCP forwarding; sorts before `50-cloud-init.conf`, whose `yes` would otherwise win |

**As the operator, root** (`sudo -s`; the agent's account has no password
and none of this is on its allowlist):

    adduser --disabled-password --comment "agent on agent-server" claude
    usermod -aG dialout,plugdev claude
    loginctl enable-linger claude
    # the sudoers file, by the steps in its header
    # the /etc drop-ins above, then:
    sysctl --system && sshd -t && systemctl reload ssh
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

Test `sshd -t` and a second SSH login before closing the one you are in.

**As the agent** (`sudo -iu claude`, then
`export XDG_RUNTIME_DIR=/run/user/$(id -u)` so `systemctl --user` has a
bus): put the unit, the loop script and the shell function in place, then
once by hand in the working directory run
`claude remote-control --spawn=same-dir`, answer `y` to
`Enable Remote Control?` and to the trust question if it asks, and stop it
with Ctrl-C. The unit cannot answer them. Then:

    systemctl --user daemon-reload && systemctl --user enable --now claude-remote

Read the Remote Control pane, not the unit: as the operator,
`sudo -u claude tmux attach -r -t main`.
