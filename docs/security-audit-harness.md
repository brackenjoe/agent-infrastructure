# The security-audit harness

The `security-audit-*` scripts and `test-security-audit-run.sh` in
[`tools/`](../tools/) are the harness the
[reference build](reference-build.md#under-evaluation) uses to run
[cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill)
(MIT) with its target's code under an OS-enforced sandbox. They are copied
unedited from the maintainer's live repo at each publish and are a
reference implementation: the sandbox and the promote tool stand on their
own; the run, briefs and finish scripts assume the live repo's layout and
are there to read and adapt.

Tested on Ubuntu 24.04 (kernel 6.8) with bubblewrap 0.9.0, systemd 255 and
Python 3.12.

## What is here

| File | What it does |
|---|---|
| `security-audit-sandbox.sh` | Runs one command under bubblewrap inside a `systemd-run --user --scope`: no network but an isolated `lo`, a cleared environment, the target, an optional venv and the agent's scratch directory read-only, the host's `/usr` and a short list of `/etc` files read-only, one size-capped tmpfs as the only writable place, not kept. The scope caps memory (no swap), CPU, tasks and wall clock; `prlimit` caps file size; stdout and stderr are each capped. `selfcheck` runs each of 24 controls: the containment ones with an attempt that must be refused, the rest (start, exit status, loopback, environment with a canary that must be absent) with a run that must succeed, and an unrunnable command must exit 125. |
| `security-audit-promote.py` | Copies a file from an agent's scratch to its kept `artifacts/`: retained directory descriptors, no-follow walks, `fstat` before and after, exclusive creation; refuses symlinks, hard links, FIFOs, sockets, devices, changing or oversized files. Standard library only. `selfcheck` plants each refused kind it can make without root and checks the device case against `/dev/null`. It is the promotion step the briefs name; nothing stops an agent with a shell copying into `artifacts/` another way. |
| `security-audit-run.sh` | The mechanical half of a run: set up a detached worktree and output directory, install the skill for the run, validate and check the output, land the reports, tear down. |
| `test-security-audit-run.sh` | Offline test of the run script against a throwaway fixture repo. Needs the skill (below), git, jq and node. |
| `security-audit-briefs.py` | Builds each agent's brief from the skill's method files and the run's metadata. |
| `security-audit-finish.py` | The parent's finishing steps: agent results, `findings.json`, the derived reports. |

## Threat model

The sandbox is for code you are auditing: a hostile upstream tree, run by
an agent to confirm a finding. It stops that code reaching the network,
reading the host's files other than the target, venv and scratch, `/usr`
and the listed `/etc` files (`passwd`, `group`, `hosts`, the loader cache
and a few more; the list is `ETC_FILES` in the script), and writing
anywhere but its tmpfs.

It refuses the operator's own mistakes, among them: a target, scratch or
venv that is `/`, is or contains the home directory, or is, contains or
sits under a credential directory (`~/.ssh`, `~/.gnupg`, `~/.aws` and the
rest of the list in the script's header); a path under `/usr`, `/etc`,
`/proc`, `/sys`, `/dev`, `/run` or `/tmp`; an overlap between target,
scratch and venv; a symlinked scratch, one not owned by you, one another user
can write by its mode bits, or one carrying any access ACL; and loader
variables (`--env LD_*`). The full list is in the header. The credential
directories are a list, not a rule: a directory under home that is not on
it (a browser profile, say) is accepted as a target.

What it does not cover:

- **The kernel.** Target code runs on the host kernel with its full system
  call surface; there is no seccomp filter. A kernel exploit is out of
  scope. For code you believe is actively hostile, use a virtual machine.
- **A socket file already inside a bound directory.** The network is cut,
  but a Unix socket that exists under the target, venv or scratch can
  still be connected to; the read-only mount does not stop that. Don't
  point the sandbox at a directory holding live sockets.
- **Your keyrings.** The command keeps your session and user kernel
  keyrings (measured: `KEYCTL_DESCRIBE` on both succeeds inside); without a
  seccomp filter that cannot be cut. Don't run audits from a session that
  holds keys.
- **Your terminal.** stdin is passed through, so a command run from a
  terminal can read what you type there. Redirect stdin from `/dev/null`
  when you don't mean to feed it.
- **A hostile process running as your own user outside the sandbox.** It
  can already read and change your files. Two checks narrow that case
  anyway: the target, scratch and venv are held open on descriptors from
  the check to the launch, and a guard inside the sandbox compares each
  mounted directory's device and inode with the one that was checked
  before the command runs. The guard is there because bubblewrap 0.9.0's
  `--ro-bind-fd` reads the descriptor back to a path name and mounts the
  name (seen in `strace`), so a descriptor alone does not pin the
  directory.
- **The agent that drives the audit.** An agent with a shell as your user
  can run anything outside the sandbox. Keep it to the tools its briefs
  name, and review what it lands. While a run is live the skill is
  installed for the whole account, so every other session of that user
  sees it too.

## Setup on Ubuntu 24.04

Prerequisites: at least two CPUs (the CPU control cannot be measured on
one), a systemd user manager for the account and `XDG_RUNTIME_DIR` set
(a normal login gives both; under `su` or `sudo -u`, run
`loginctl enable-linger USER` and export
`XDG_RUNTIME_DIR=/run/user/$(id -u)`, or nothing starts), `/usr/bin/python3`
(every run uses it for the ACL check), the persistent user journal Ubuntu has by default (the
memory and wall-clock controls read the scope's result from it), and
`bubblewrap`.

Ubuntu 24.04 refuses unprivileged user namespaces to any program without
an AppArmor profile (`kernel.apparmor_restrict_unprivileged_userns = 1`),
and no profile attaches to `/usr/bin/bwrap` by default, so bwrap fails with
"setting up uid map: Permission denied". Canonical ships a profile for it,
disabled, in the `apparmor-profiles` package. Installing that package also
installs other profiles into `/etc/apparmor.d/`, so take the one file out
of the package instead:

    d=$(mktemp -d) && cd "$d"
    apt-get download apparmor-profiles
    dpkg-deb -x apparmor-profiles_*.deb x
    sha256sum x/usr/share/apparmor/extra-profiles/bwrap-userns-restrict
    sudo install -m 0644 -o root -g root x/usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/
    sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
    cd - && rm -rf "$d"

In `4.0.1really4.0.1-0ubuntu0.24.04.9` the file's sha256 starts
`11d39094f044f0cd`; a later package may differ, so read it before loading.
In that profile bwrap keeps its capabilities inside its namespace and its
children run with none. It applies to every user's bwrap on the machine,
not only yours: it relaxes Ubuntu's user-namespace restriction for bwrap
host-wide. The installed file belongs to no package, so updates never
replace it; repeat these steps to take a newer one.

Then, as the user who will run audits, from the repository root:

    tools/security-audit-sandbox.sh selfcheck

Every line must read `ok`; the `refusals` line names any case it had to
skip (no supplementary group, no `setfacl`), so read it. Run it again after any bwrap, kernel or
AppArmor change. The run script refuses to set up a sandboxed run unless
the selfcheck passes.

## Running a command

    tools/security-audit-sandbox.sh run \
      --target DIR --scratch AGENT/scratch [--venv DIR] [--env NAME=VALUE]... -- CMD [ARGS...]

`defaults` prints the limits (512 MiB memory, 2 cores, 120 s, 128 tasks,
64 MiB per file, 128 MiB disk, 1024 KiB each of stdout and stderr); each
has a flag. The disk may be at most half the memory (tmpfs pages are
charged to it) and the file size at most the disk, so raise `--mem` with
`--disk`.

The exit status is the command's own, except:

- 125: the sandbox could not start, CMD cannot be run, or a bound
  directory is not the checked one;
- 137: the wall clock or the memory limit killed it, or it died by a
  signal with no exit status;
- 143: the wrapper was interrupted;
- 2: usage, or a refused path (nothing ran, and no summary line).

A command can return any of these itself, and it can also print lines
that look like the wrapper's notes, so neither the number nor a note proves
the cause when the command is hostile. Only the final `sandbox: exit N
after ...` line is certainly the wrapper's: it is written after the
command's output has been drained. The notes, written just above it, are
`memory limit ... reached`, `wall clock ... reached`, `killed by signal N
with no exit status`, `setup failed`, `bwrap never started`, `mounted is not
the checked directory` and `cannot run`. An interrupt (143) prints
`interrupted; killed` and no final line; a refusal (2) and a failure to
make the wrapper's own temporary files (125) print no final line either.
A memory kill of a child process while the command itself still exits
returns the command's status with the memory note. Hitting the file-size
limit gives 153 (death by `SIGXFSZ`), or the command's own `EFBIG` error if
it ignores that signal, with no note.

## What repeated runs taught

From seven re-audits here between 2026-11-21 and 2026-11-23. The skill's
method has a parent agent spawn reconnaissance agents, then hunters that
look for defects, verifiers that reproduce each one, and a critic;
`land` copies a finished run's records into the repository.

- **Scope a re-audit from what earlier runs covered, not from a summary.**
  Compare the file list with every landed run's `target_files`. A README
  here said four batches had been audited, and one had never been in any
  run's targets. An earlier run's own fixes had not been hunted either.
- **A second run on one day needs its own landing name.** `setup` builds
  the run id from the part, the date and a counter, and the counter
  starts again once a run is torn down. Name each later landing yourself:
  `land` refuses a directory that exists.
- **The reproduction harness stays as it is.** One verifier wrote its fix
  check over its own `harness.py`, and the promoted file no longer
  matched its output. Hunters repeatedly ran the deciding check from a
  second file, which is not promoted, so that check stood as a source
  read. Say both in the briefs: the deciding run is `harness.py`, and a
  fix check goes in a name that is not on the promotion list.
- **A test written for an audit's fix goes into the next run's scope.**
  One was a denylist where an allowlist belonged, and the next run
  confirmed it.
- **When a fix states an invariant, the next run checks every caller.**
  One fix put "nothing changes the screen while an approval is pending"
  in one function; the next run found a second path to the same sink.
- **Read the verifier's fix, not the hunter's.** One hunter's fix would
  have mislabelled the owner's own uses of the same operation; the
  verifier found it.
- **A budget of 10 covers one unit:** four reconnaissance agents, one
  hunter, two verifiers and one critic, with two in reserve.

## The skill

The skill is not published here. The run and briefs scripts read it from
`tools/security-audit-skill/` beside them: the contents of the skill
repository's `skills/security-audit/` plus its `LICENSE`, at commit
`c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`, committed into your own
repository. Setup refuses the directory when it has no tracked files or
an uncommitted change. The commit recorded in a run's metadata is the
constant `SKILL_COMMIT` in `security-audit-run.sh`, not read from the
copy: if you vendor another commit, change it too; a different commit may
also change the layout the scripts read. The sandbox and the promote tool
need none of this. The skill is installed into `~/.claude/skills/` for a
run and removed after: its description matches any security question, so
a standing install would change every agent's security answers.
