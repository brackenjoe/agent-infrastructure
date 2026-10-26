# The agent as its own user

[Back to the README](../README.md). The agent server runs the agents under
a Unix account of their own, locked, with no password and a sudo allowlist,
and the operator keeps a separate account with full root. This page is the
why, the account, the allowlist, and what moving an existing install cost.
Written from the move made here on 2026-10-25 (Ubuntu Server 24.04, sudo
1.9.15p5, adduser 3.137, git 2.43.0, Claude Code 2.1.310); a claim that
was not exercised says so.

## Why

When the agent and the operator are one Unix user, the agent can write
everything the operator's own logins run. Three concrete routes from
there to the operator's access, each closed by the split and by nothing
else:

- `~/.ssh/authorized_keys` is the operator's. The agent can add a key: a
  new way in, which the stop rule exists to prevent and cannot.
- `~/.local/bin` is first on `PATH`, and `~/.bashrc` runs at every login.
  A `sudo` placed there, or a line in `~/.bashrc`, runs at the operator's
  next login and can take the password. A short sudo timestamp
  (`timestamp_timeout=0`) closes the shared-terminal cache, not this.
- The operator's shell history, `sudo` group membership and anything else
  kept in `$HOME` are readable and writable by the agent.

What the split does **not** do: take credentials away from the agent. The
git token, the Claude login and the deploy keys are the agent's working
credentials and move with it. After the split the agent holds all of its
own and none of the operator's.

It also does not stop the agent doing, as itself, anything its allowlist
and its credentials allow. The allowlist is for accidents (a stray
`sudo systemctl restart ssh`); a hostile agent is a different threat and
is not what any of this is built against.

## The account

```
adduser --disabled-password --comment "agent on agent-server" claude
usermod -aG dialout,plugdev claude      # only what the hardware needs
loginctl enable-linger claude           # its user units start at boot
```

- `--comment`, not `--gecos`: adduser 3.137 deprecates the latter (its man
  page).
- Groups: only the ones the work needs (here, serial ports and USB
  devices). Not `sudo`, `adm` or `lxd`. On 24.04, adduser adds nothing
  else by default; check with `id claude`.
- The home is `0750` (`HOME_MODE` in `/etc/login.defs`), so the operator's
  account cannot read the agent's files and the agent cannot read the
  operator's. Both directions matter: see `git worktree repair` below.
- `passwd -S claude` shows `L`: locked, no password. The ways to become it
  are root, `sudo -iu claude` from an account that has sudo, an SSH rule
  that admits it, or a key in its own `authorized_keys` (it has none here).

Then, as that user and at a terminal, once: run `claude` in the repository
to accept its trust prompt (workspace trust is keyed by path in
`~/.claude.json`, per user), and check `claude auth status`. The login file
was copied here; `claude auth login` on a headless second user was not
exercised.

The Remote Control unit from [the agent server](agent-server.md) runs
under this account, with `%h` and `$HOME` in its paths and lingering on.
The operator's account runs no agent at all. Two things measured on the
way:

- `claude remote-control` mints a new environment per process start, so
  the phone lists a new entry; sessions started from the old account's
  entry go nowhere.
- A copied checkout had no `origin/HEAD`, and remote sessions then worked
  on a generated branch instead of `main`. `git remote set-head origin
  main` once, as the agent.

**Reaching the agent's terminals.** The operator's account cannot enter
`/home/claude`, so a bare `tmux attach` no longer works. Three options,
the owner's choice: `sudo -u claude tmux attach -r -t main` (read-only; a
password each time if the operator's sudo timestamp is off), a Tailscale
SSH rule whose `users` names the agent's account, or one narrow sudoers
line, `<you> ALL=(claude) NOPASSWD: /usr/bin/tmux`.

## The sudo allowlist

[`host/90-agent-allowlist`](../host/90-agent-allowlist) is the file,
generalised from the live one. Its shape:

- One `Cmnd_Alias` for reads: `systemctl` with a read verb first and only
  argument-free flags from a fixed list around it, `journalctl` with a
  fixed list of long options, `ss` and `dmesg` with fixed flag sets, LVM
  listings, `ufw status`, `sshd -T`, `apt-get -s ...`. One for
  `apt-get update` and `apt-get --no-remove install` of packages **by
  name only**: no `-o` (an apt option can run a command), no local `.deb`
  path, no `remove` or `purge`, no trailing `-`. Add an alias per service
  the agent operates, with the exact `systemctl start|stop|restart` forms.
- Every spec is a POSIX extended regular expression (`^...$`), which needs
  sudo 1.9.10 or later. Check a spec with `sudo -n -l <command>` as the
  agent: it prints the command if it would be allowed and runs nothing.
- The agent's line is `claude ALL=(root) NOPASSWD: <aliases>`. Nothing in
  the file names the operator, who keeps full root through `%sudo` in
  `/etc/sudoers`, with a password.
- `apt-get install` by package name is still one step from root by
  construction: a package's maintainer scripts run as root. Nothing else
  on the list installs or starts what root runs.

**The first version of this file was wrong four ways**, and a cold review
of this page found it by reading the regular expressions, not the
comments; each was confirmed with `sudo -n -l` on the installed copy. A
`systemctl` rule that allowed leading options let `-p status restart ssh`
through, since `-p` takes an argument and the next word became the verb.
The package-name class allowed a trailing `-`, which is apt's remove
syntax, so `install openssh-server-` would have removed sshd. `journalctl`
and `dmesg` with free arguments can empty the logs; `ss -K` closes
sockets, SSH and Tailscale included.

**The corrected forms were wrong three more ways**, found before any host
ran them by matching each spec with the C library's `regcomp`, the engine
sudo uses, against the arguments joined by single spaces, as sudo joins
them. An empty argument (`journalctl -u ssh "" --vacuum-time=1s`) leaves a
double space, and a free-argument class that began `[^-]` matched the
second space; that sudo keeps the double space was measured with
`sudo -n -l`. `ss -D FILE` writes a file as root. A package version could
still end in `-`. The file in `host/` has these fixed too, and drops
dmesg's `-H`, which starts a pager. Both of this setup's hosts have run
the corrected forms since 2026-10-26: installed by the owner from a root
shell held open, then probed from a second login with `sudo -n -l`, every
form meant to be refused refused and every read form listed. Write the
probes you mean to refuse into the install steps and run them after every
install.

**Installing it is the one lockout point.** A parse error in any file
under `/etc/sudoers.d` makes sudo refuse every invocation; root has no
password on Ubuntu by default; nobody sits at the box. Measured here: two
files that both define an alias of the same name (`BOX_READ` in each) do
not parse, `visudo -cf` on the new file alone passes, and the tree then
refuses. So:

1. Name the aliases apart from any existing file's, and check the pair
   together: `cat old new | visudo -cf -`.
2. Install the new file **beside** the old one, never over it:
   `install -m 0440 -o root -g root new /etc/sudoers.d/90-agent-allowlist`,
   then `visudo -c`.
3. Hold the root shell open in its own window. From a second login prove:
   `sudo -v` as the operator asks for and takes the password; as the
   agent, `sudo -n -l` prints the allowlisted forms, `sudo -n /usr/bin/id`
   is refused, and so is each probe the file's header names.
4. Only then remove the old file, and `visudo -c` again.

Keep the source of the file in the repository and have a check compare
`sudo -n -l` against it, both ways, so a hand edit of `/etc/sudoers.d`
cannot leave the source behind.

## Root runs no agent-owned file unattended

Found while inventorying the move: a nightly root timer ran a backup
script straight out of the agent's checkout. The agent could edit what
root runs next, one step to root and outside the allowlist entirely;
after the move it would have been root executing a file owned by an
unprivileged user, which is worse. The rule: a script root runs on a timer
or at boot is a root-owned copy in `/usr/local/sbin`, installed by an
installer that refuses an uncommitted source, and the unit points there.
The same holds on every deploy target ([the web server](web-server.md)).

An installer or an update script the operator runs by hand under `sudo`
from the agent's checkout is still an agent-owned file running as root.
That is a deliberate exception, and it has a condition: the operator reads
it, or diffs it against the commit that was reviewed, before running it.

## Moving an existing install

New installs skip this: create the account first. Moving one, by copy, in
place, with the old tree left untouched until every proof passed:

- **A Python venv is not movable.** Its scripts carry an absolute shebang
  ("environments are inherently non-portable", Python 3.12 docs, venv,
  How venvs work). `pip freeze` each one first, then recreate at the new
  path and diff the freeze. One made with `--system-site-packages` froze
  80 distribution-packaged lines PyPI does not serve; rebuild it with the
  flag and only the local packages.
- **Build caches record absolute paths** (CMake, waf, PlatformIO, Gradle).
  Leave them behind with rsync excludes and build clean when next needed.
- **`git worktree repair`** follows the copied `gitdir:` lines and
  rewrites whatever they point at. Run as the agent with the old tree
  unreadable (`0750`), it repairs the copy and leaves the old one alone;
  run where the old tree is reachable, it rewrites the old tree's files
  (scratch test). Count your worktrees first: the plan said five, there
  were seven.
- **Per-user Claude state** is keyed by path and by process: the
  path-keyed history, sessions, daemon files and tokens stay behind; the
  login and settings move. Grep the copy for `*.key`, `*token*` and the
  credentials file before going on; it should print nothing.
- **Symlinks** in `~/.local/bin` are absolute; rewrite them in one loop
  and diff the listing against the one taken before.
- **Credentials move by hand**, by the owner: the git token, the Claude
  login, the deploy keys with `~/.ssh/config` and `known_hosts`. Not
  `authorized_keys`: that is the operator's way in and stays put.
- **Rollback** until the old copy is retired: stop the new unit, put the
  root files back (the sudoers file from its source in the repository,
  the rest from their captured texts), start the old unit. No LVM
  snapshot: the untouched old tree is the data rollback, and a snapshot
  held across a 30 GB copy would fill its copy-on-write space.

**The proofs before retiring the old copy**, each run, not assumed: the
operator's own logins over LAN and tailnet and `sudo -v`; the agent's
`sudo -n -l` and a refused `sudo -n id`; each deploy key with
`ssh -o BatchMode=yes <host> true`; the git token with `curl` against the
repository's API URL before any `git` command (the `store` helper erases
the file on a failed auth), then a dry-run push; every venv's selftest; a
browser launch; the worktree listing; the Remote Control bridge in the
debug log and a session from the phone landing in the new home; the
config capture rerun as the agent and committed; a reboot, then the
bridge and the repo check again; and a grep of the tracked tree for the
old home path, with the remaining hits listed and explained (dated logs
and data files stay as written).

A deferred-reboot script that counts the agent's sessions must count the
new user's. Writing this list found that a display manager's greeter
session had held every pending reboot off for ten days on a headless
server ([incidents](incidents.md)).
