## This machine
Headless Ubuntu 24.04 sandbox, driven from a phone or a second laptop.
Nobody sits at it. It is disposable: rebuilding costs an afternoon.

In a cloud session (hostname not brackenclaudebox) none of that is here:
no tailnet, hosts, deploy keys, venvs, ArduPilot trees or flight logs.
Do no deploys and no ssh; a step that needs the box goes in the job's
README under "Not done". Work lands on the session's branch; I merge.

## Where things live, and which to read
Everything is under ~/bracken. $HOME holds dotfiles and nothing else.

  CLAUDE.md            rules for every agent. A domain's rules live in its
                       agent file; neither goes in memory or a README.
                       Loaded every session, so it stays short.
  tools/README.md      every tool and how to invoke it. Read it before
                       building something that may already exist.
  tools/               our scripts, tracked. Third-party checkouts sit
                       here too, gitignored, and stay: their venvs and
                       ~/.local/bin symlinks hardcode these paths.
  BRACKENCLAUDEBOX.md  the machine: what is installed, what was rejected,
                       what not to relitigate. Read on demand.
  work/<project>/      README.md is an index: a "| part | what | was |"
                       table, one line and a link per part. An index may
                       hold indexes (drones/<aircraft>/<job>).
  work/<project>/<part>/
                       one job. Its README.md is the current state: what
                       it is, how to run, check and deploy it, what was
                       measured, what is not done. Dated history goes in
                       git or a CHANGELOG.md beside it; plans and
                       reference in docs/. A print for no project goes in
                       prints/, a job of Joe's that is not Bracken's in
                       personal/.
  system/              captured host config. Regenerate, never hand-edit.
  .claude/agents/      one agent per domain, thin: they point at the files
                       above rather than restating them.

Any agent may edit any of these; the split is by content, not by author.
Finishing a job means its part's README (and its line in the project
index if the part is new), the project's ONE row in Parts made in
BRACKENCLAUDEBOX.md edited in place and dated, and tools/check-repo.sh
clean. The row is not a summary; the README is.

Adding a tool means adding its row to tools/README.md in the same commit.

## Worktrees
One job, one worktree: several sessions share this checkout, and a shared
tree has cost a stash taken over another session's live edits. Never stash
here. Small manager edits, a README or a tracker row, stay here.

A worktree has no `.venv`, `node_modules` or ArduPilot trees. **Do not
symlink them in:** a symlink is not matched by the ignore entry, gets
committed, and checked out over the real directory it deletes it (the
real flight logs, 2026-09-20). Run the main checkout's interpreter against
the worktree's code:

    cd <worktree>/work/web-apps/postflight
    /home/joe/bracken/work/web-apps/postflight/.venv/bin/python selftest.py

Add files by explicit path, never `git add -A` or `git add .`: that is how
the symlink got committed.

A worktree is finished in the session that made it: fast-forward the
branch into main, push, remove the worktree, delete the branch.

## Scope
Work inside the current part's directory. Reaching into another part or a
third-party tree: say what and why first. A design I am doing in another
session gets no derived work here until I say it is settled.

A new script is either reusable, committed in tools/ and indexed, or a
one-shot deleted once it has run. Every agent starts in the shared
checkout: run anything that writes to the current directory from a
scratch directory. Nothing untracked is left at the repo root.

## Delegating
Code to a settled design goes to `builder`, from every agent, the manager
included; only an edit of a few minutes stays with whoever holds it. No
asking first. The brief: the design, the files it may edit, the data
shape, the pattern to copy, the checks to run, one deliverable per brief.
A report names each builder brief and what was kept, or why there was
none. Rerun its checks yourself; never report a check as passed on its
word. The README and the finishing stay with you. The manager routes
across domains and spawns any agent; every other agent spawns only
`builder` and sends out-of-domain work back up. Each agent file names
what it must not hand over.

A request from me is reviewed before it becomes a brief: checked against
the source, the README, the measured numbers and the open items, answered
with approve or push back (what breaks, the alternative). A push-back that
needs my answer waits for it. A value I measured or a decision I made
passes straight through, flagged once if it conflicts with a record.

## Deliverables
Slicing happens on my laptop; STLs leave this box, each with a PNG
preview, since I review from a phone. No preview, not finished.
Say what you measured and what you assumed, with sources.
Which material goes in promo, real or simulated, is my call; blur what I
name. This box never posts; I do.
A new page follows the visitor's light or dark setting, no toggle, built from
work/brand/design-system/project/, its rules copied, not imported.
External data comes from open, no-key sources; name the licence.

## Acting
Act on reversible operations instead of asking. Stop and ask before
anything touching credentials, Tailscale or sshd: those are the paths in.
The same stop rule covers brackenwebserver (`ssh webhost`), its ufw rules
and tunnel config. Its record is work/web-apps/web-server/README.md; after
touching its /etc, run tools/capture-webhost-config.sh and commit.

Verify by exercising the thing, not by seeing that it started. Permission
rules too: after a Claude Code update, run tools/check-permissions.sh.

## Pushing
Push to a private remote as part of finishing; don't ask. A public remote
needs my approval every time: publishing cannot be undone. Check
visibility, don't assume it (gh is not installed):

  curl -s -w '\n%{http_code}\n' https://api.github.com/repos/<owner>/<repo> | grep -E '"visibility"|^[0-9]{3}$'

Public if that prints "public". Private if it prints "private", or only
404. Anything else (403, 5xx, 000, nothing) proves nothing: ask. Through a
cloud session's proxy a private repo also answers 200, and a repo not
attached to the session answers 403 even when public. Either way, read
the diff for credentials first; the exclusion list is in system/README.md.
New or rewritten public prose gets a read-only review, before the push, by
an agent with none of the drafting context; for the agent guide, only its
versioned pages and claims about security or permissions need one. A
review of the guide's own checks (its pull-request checks and the publish
script) is briefed with their threat model: they catch mistakes, not a
hostile contributor. One round; a second only if the first found something
that must be fixed, and only on what changed. The review's findings are
checked like any report.
