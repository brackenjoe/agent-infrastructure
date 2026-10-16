# Maintaining this guide

How the owner works on this repository from Claude Code in the cloud,
and publishes. Written against Anthropic's cloud docs and GitHub's docs,
read 2026-10-16.

## Two repositories

- `brackenjoe/agent-infrastructure`: this one, public. Readers and their
  AIs use it. Nothing lands here without the owner's approval.
- `brackenjoe/agent-infrastructure-dev`: private. The same history, plus
  work not yet published. Cloud sessions work here, because a cloud
  session pushes its branch as soon as it reaches a stopping point, and a
  branch in a public repository is public.

The dev repository's `main` is what gets published, so nothing private is
ever committed to it. Private terms for the scanner live in the cloud
environment instead (below).

## Link the dev repository to Claude Code in the cloud

One time, in this order.

0. **Create and seed the dev repository.** On GitHub, create
   `agent-infrastructure-dev`: **Private**, with no README, .gitignore or
   licence, so it starts empty. Then, from any clone of this public
   repository: `git push <dev repository URL> main`. The dev repository
   now holds the same history.
1. **Install the Claude GitHub App on both repositories.** At
   [github.com/apps/claude/installations/new](https://github.com/apps/claude/installations/new),
   choose "Only select repositories" and pick `agent-infrastructure-dev`
   and `agent-infrastructure`. If the app is already installed, the same
   page lets you configure it to add them.
2. **Protect the public `main`.** In this repository's Settings, Rules,
   Rulesets: **New ruleset**, **New branch ruleset**. Name it `main`. Set
   **Enforcement status** to **Active** (it starts as Disabled). Under
   Target branches, **Add target**, **Include default branch**. Keep
   **Restrict deletions** and **Block force pushes** ticked, leave the
   bypass list empty, and select **Create**. The cloud GitHub proxy does
   not limit which branch a session pushes to, so this is what stops a
   rewrite of public history. Tags `v*` already have their own ruleset.
3. **Create the environment.** At [claude.ai/code](https://claude.ai/code),
   open the environment selector (the first control under the message
   box), then **New environment**:
   - Name: `agent-infrastructure-dev`.
   - Network access: **Trusted**. It covers GitHub and
     `raw.githubusercontent.com`.
   - Environment variables, two lines:
     `PUBLISH_PUBLIC_URL=https://github.com/brackenjoe/agent-infrastructure.git`
     and `PUBLIC_SCAN_TERMS="term one,term two,..."` with the private
     names, places and identifiers the scanner must refuse. Keep the
     quotes: an unquoted `#` would cut off every term after it. Anyone who
     uses the environment can read them; they are never committed.
   - Setup script: none. git, Python and the shell tools are
     pre-installed.
   - Select **Add environment**.
4. **Check it.** Start a session on `agent-infrastructure-dev` in that
   environment. Ask it to run `tools/public-scan.sh .`; it should pass.
   Then ask it to run these, without printing the terms:
   - `printf '%s' "$PUBLIC_SCAN_TERMS" | tr ',' '\n' | grep -c .` should
     print how many terms you set.
   - `mkdir -p /tmp/t && printf '%s\n' "$PUBLIC_SCAN_TERMS" | tr ',' '\n' | head -1 > /tmp/t/x && tools/public-scan.sh /tmp/t | grep -c '^FAIL  deny-list term'; rm -rf /tmp/t`
     should print `1`. That proves the terms loaded, without any term
     appearing in the chat.

## Day to day

- Start each session on `agent-infrastructure-dev`, in that environment.
  It loads [AGENTS.md](AGENTS.md) through [CLAUDE.md](CLAUDE.md).
- Each session pushes its own branch to the dev repository, which is
  private. Review the diff, select **Create PR**, and merge it in the dev
  repository with **Squash and merge**: one clean commit per change, and
  no session work-in-progress commits on the way to public.
- New or rewritten prose gets a read-only review before it is published:
  ask a fresh session to review the diff, and check what it finds.

## Publish

1. Start a session with **both** repositories attached: the dev
   repository and `agent-infrastructure`.
2. Ask it to run `tools/publish-from-dev.sh`. It checks the tree is clean,
   on `main` and equal to the dev repository's `main`, and that the public
   `main` is already part of this history. It scans the tree and every
   commit and message being published with your private terms, refuses
   commits carrying a session link, checks em dashes and links, and tests
   the push without making it. It then shows the target, the commits with
   their author and committer, and the files, and pushes nothing.
3. Read that list. If it is right, tell it to run
   `tools/publish-from-dev.sh --push`. That fast-forwards the public
   `main`; it never force-pushes and never pushes tags.
4. If the versioned pages changed (see AGENTS.md), make the next tag on
   GitHub, since cloud sessions cannot push tags: this repository,
   **Releases**, **Draft a new release**, **Choose a tag**, type the next
   version (`v3`), **Create new tag**. Under **Target**, pick the commit
   the script just pushed from the recent commits, not just `main`. Add a
   title, then **Publish release**. Check one raw link at the new tag
   returns the page.

## When the public repository moves on its own

A contribution merged here, or a publish from the owner's machine, puts
commits on the public `main` that the dev repository lacks. The publish
script stops and lists them. In a session with both repositories
attached, ask it to merge the public `main` into a branch of the dev
repository and open a pull request there; merge it, then publish as
usual.

`setup/` and `tools/` are maintained on the owner's machine and copied
here when it publishes, so changes to them are made there, not in a cloud
session. That machine's own publish script also stops when this
repository has moved, until the new commits are copied back.
