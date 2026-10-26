# The agent server

[Back to the README](../README.md). Working copies of the files described here are in [`host/`](../host/).


**OS.** Use Ubuntu Server 24.04 LTS on LVM, leaving free extents in the volume group for snapshots. On a laptop, ignore the lid in a logind drop-in and mask the sleep, suspend, hibernate and hybrid-sleep targets.

**Claude Code.** Install it with the native installer (`~/.local/bin/claude`) and log in once with a claude.ai subscription account: without an eligible login, `claude remote-control` exits with an error (Remote Control docs). To reach it from a phone or laptop, start a Remote Control server at boot with no login:

```ini
# ~/.config/systemd/user/claude-remote.service
[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=process
ExecStart=/usr/bin/tmux new-session -d -s main %h/.local/bin/claude-remote-loop.sh
ExecStop=/usr/bin/tmux kill-session -t main

[Install]
WantedBy=default.target
```

Run all of this as the agent's own account, not yours ([the agent as its own user](agent-account.md)), and enable lingering for it (`loginctl enable-linger claude`) so it starts at boot. The loop script enters your working directory, exits if that directory is not trusted, then runs `claude remote-control --spawn=same-dir --permission-mode auto --name agent-server` forever, backing off up to 300 s on repeated failures. Before you enable the unit, run `claude remote-control --spawn=same-dir` once by hand in that directory, answer its one-time `Enable Remote Control? (y/n)` prompt and its trust question if it asks, and stop it with Ctrl-C. The loop exits on an untrusted directory, and in a detached tmux pane the enable prompt would wait with nobody to answer it; the docs give no unattended way past it (Remote Control docs, read 2026-10-17). Set `"remoteControlAtStartup": true` in `~/.claude/settings.json` so every session shows in the app. For SSH, wrap `claude` in a shell function that attaches or creates a tmux session, so a dropped connection loses nothing. This held on Claude Code 2.1.260 to 2.1.289; recheck on yours. The unit, the loop script (with the trust check and back-off), the shell function and the drop-ins below are in [`host/`](../host/README.md).

Each of these broke a boot here:

- `remote-control` refuses to run in `$HOME`. Run it from a project directory you have trusted once.
- Without `--spawn=same-dir`, the first run stopped on a spawn-mode prompt no service can answer. Current docs list `same-dir` as the default, so this may be fixed on yours; the flag costs nothing.
- Without `KillMode=process`, stopping the unit kills the tmux server and every session on it.
- `systemctl status` said `active (exited)` while the loop failed every 5 s. Read the pane, not the unit.

**One directory.** Keep everything in one git repository; `$HOME` holds dotfiles only. Commit often: git is a better undo than filesystem snapshots.

**Access.** sshd takes keys only, no root login, no agent or TCP forwarding (`host/10-hardening.conf`); a password-disabling drop-in must sort before `50-cloud-init.conf`, which sets `yes`, and the first value wins. ufw: deny incoming, allow outgoing, allow everything on `tailscale0` and 22/tcp from the LAN, `IPV6=yes`. Enable it behind a timed revert (`systemd-run --on-active=10m --unit=ufw-revert ufw disable`), prove it from another host (a connection that should work, and a blocked one that logs `[UFW BLOCK]`), then stop the revert unit. Here ufw had sat installed with its unit enabled and `ENABLED=no` for six weeks while the record said it was on ([incidents](incidents.md)). Purge what listens and is not needed (here cups and avahi, which answered on 5353 on every interface).

**Capture host config into git.** Keep a script that copies a fixed list of hand-made files (sshd drop-ins, units, sysctl files, the ufw rules, the Remote Control unit and loop, `.bashrc`, `~/.claude/settings.json`) into `system/files/` under their absolute paths, with listings of manual packages, enabled units, storage, `sudo -n -l` as the agent and the sshd authentication methods a loopback probe is offered. Run it after touching `/etc`, a unit or a dotfile, and commit; have the repo check fail when a captured file differs from the live one or the sudo listing differs from its source. Never capture the Git token, `~/.claude/.credentials.json`, host keys, `~/.ssh/` or Tailscale state, and keep that list in the capture's own README so the next person does not add one.

**Imaging.** Take one verified whole-disk image (Clonezilla `savedisk`; the LVM partition alone does not boot). It holds every credential, so store it end-to-end encrypted. It goes stale: the capture plus a push is the live backup. Take an LVM snapshot just before a risky change and drop it after; one left standing here reached 81% of its copy-on-write space.

**Lessons this box paid for:**

- unattended-upgrades did not install a new kernel here. Check `apt list --upgradable` and run `apt full-upgrade` yourself.
- A password-disabling sshd drop-in must sort before `50-cloud-init.conf`, which sets `yes`; the first value wins.
- `credential.helper=store` erases the file on any auth failure. Test a new token with curl first.
- Set `kernel.panic=10` and the lockup panics so a hang reboots itself. Do not build hardware recovery for a failure that has never happened.
- A unit that started, a driver that bound or an image that exists proves nothing. Exercise it.
