# agent-infrastructure

A guide for AI agent setup in [Claude Code](https://code.claude.com/docs/en/overview)
or [ChatGPT Codex](https://chatgpt.com/codex/). A manager reviews each
request before any work starts, a cheaper builder writes code once the
design is settled, a read-only reviewer reads what leaves, and other
agents take the repetitive tasks you hand them. Checks are rerun, not
taken on an agent's word. On a machine of its own, the agent runs as a
Unix user of its own, with a short list of what it may do as root.

It scales from one cloud session with no server to a network of your own
machines. It was written from the Claude Code setup Bracken Systems runs,
and every practice here came from running it: the
[incidents](docs/incidents.md) are thirty-one failures from nine weeks,
twenty-nine of them with the rule they produced.
[The reference build](docs/reference-build.md) is the setup they came
from, in broad strokes, and why it is shaped that way. Codex is covered
for the cloud path.

## Pick a starting point

| You want | Start with | You need |
|---|---|---|
| To try it, with no server | [Set it up in the cloud](https://github.com/brackenjoe/agent-infrastructure/blob/2026.10.26.1/docs/cloud.md): paste its prompt into the AI chat you already use, and it walks you through Claude Code in the cloud, or Codex | a GitHub account, and Claude Pro, Max or Team, or an Enterprise premium or Chat + Claude Code seat ([cloud sessions](https://code.claude.com/docs/en/claude-code-on-the-web), read 2026-10-17); for Codex, a ChatGPT plan that includes it, which [its page](https://github.com/brackenjoe/agent-infrastructure/blob/2026.10.26.1/docs/codex-cloud.md) covers |
| To run it on your own computer | [On one machine](#on-one-machine), below | Claude Code with a Claude plan or a Console account ([quickstart](https://code.claude.com/docs/en/quickstart), read 2026-10-17), and a git repository |
| Agents running without you at the keyboard | [The agent server](docs/agent-server.md), then [the agent as its own user](docs/agent-account.md) | a spare Linux machine, and a Pro, Max, Team or Enterprise plan: Remote Control needs a claude.ai login (`/login`), API keys are not supported, and on Team and Enterprise an Owner must turn it on ([Remote Control](https://code.claude.com/docs/en/remote-control), read 2026-10-17) |
| Agents that deploy to other machines | [Network and access](docs/network.md), [the web server](docs/web-server.md), and [TAK Server integration](docs/tak-integration.md) if you run TAK | a private network such as Tailscale, and the machines |

The first two rows are two ways to start with the same starter (Codex
writes `AGENTS.md` instead). Each row after them adds to the one before
it. Whatever the row, [the GitHub side](docs/github-repo.md) covers the
repository the agents work in, the token they hold, and what to set on a
public repository they help maintain. The last two rows are how it runs
here: [the reference build](docs/reference-build.md) shows the machines,
the agents and the reasons for each.

## How it works

1. **Review before brief.** The manager checks each request against the
   code, the README and any measured numbers, and answers approve or push
   back before anything is briefed. A choice that is yours waits for you.
   A 20 mm strap channel in a printed mount would have been briefed as
   asked, with nowhere for the strap to close
   ([incidents](docs/incidents.md)).
2. **Route bounded code to a cheaper builder.** Design, deploys and live
   hardware stay with the manager or a domain agent (one agent per area of
   work), and an edit of a few minutes stays with whoever holds it. Code to
   a settled design goes to `builder` on a cheaper model, with a brief: the
   files it may edit, the data shape, the pattern to copy and the checks
   to run. Routing is where the cost is. Over two weeks here, four builds
   briefed to the expensive domain agents instead of the builder took
   about a quarter of all subagent usage (an estimate, weighting turns by
   model); the builder, doing most of the code, took 5.5%. So every report
   names each builder brief, or why there was none.
3. **No check passes on an agent's word.** The builder reports each check
   with its pass and fail counts, and a check that did not run as not run.
   Whoever briefed it reruns those checks before reporting anything as
   passed. [`examples/brief-and-report.md`](examples/brief-and-report.md)
   is a real brief and report.
4. **A cold read before anything leaves.** New or rewritten public prose,
   a rule change, and any claim about security or permissions get one
   round from `reviewer`, an agent with none of the drafting context that
   can read and run checks but not edit. Its findings are checked against
   sources like any report. Two cold reviews of this setup's records, each
   a fresh session with none of the context, found the three security
   items on the incidents page that six weeks of its own checks had not;
   the cold review of this page found four holes in a sudo allowlist that
   its author's comments said were closed.
5. **Verify by exercising the thing.** A service that says `active`, a
   driver that bound or a file that exists proves nothing. A watchdog that
   read `active` never moved its timer, and the agent server hung three
   minutes after it was armed. A firewall whose unit was enabled had never
   been on.
6. **One job, one branch.** Where several sessions share a checkout, each
   job gets its own worktree. One session's `git stash` once took another's
   live edits, and a symlink into a worktree once deleted real flight logs.
7. **Stop before credentials and public acts.** Anything touching
   credentials or the ways into a machine, and anything that makes
   something public, waits for you, every time. A bug the agent finds in
   someone else's code or service is reported to you as possibly
   reportable; you decide what happens next.
8. **The agent is not you.** On a machine of its own it runs as a locked
   Unix account with its own credentials and a sudo allowlist. Your keys,
   your shell and your sudo are out of its reach by file permissions, and
   what it may run as root is a file, not a sentence
   ([the agent as its own user](docs/agent-account.md)).
9. **Know what is enforced.** Most of these are instructions the model is
   trusted to follow. [The table below](#the-rules-and-what-enforces-them)
   says which are not.

The manager runs at the session's model (`model: inherit`). The routing
failure in item 2 happened at that model and was fixed by a rule, not a
model change. A cheaper manager has not been tried.

## On one machine

You do not need a server for any of the above. On any machine with Claude
Code and a git repository:

1. Copy [`starter/`](starter/) into your repository: its `CLAUDE.md` at
   the root and its `.claude/` beside it. The commands below overwrite an
   existing `CLAUDE.md`, `.claude/settings.json`,
   `.claude/agents/manager.md`, `.claude/agents/builder.md` or
   `.claude/agents/reviewer.md`; if you have any of those, copy the
   starter somewhere else and merge by hand. From the repository root:

   ```
   git clone --depth 1 --branch 2026.10.26.1 \
     https://github.com/brackenjoe/agent-infrastructure /tmp/ai
   cp /tmp/ai/starter/CLAUDE.md .
   cp -R /tmp/ai/starter/.claude .
   ```

   The starter is the core with no domains in it: a manager, a builder, a
   reviewer, a short rule set with the delegating rule, and the settings
   below. Fill in the rule set's "This project" section.
2. Its `.claude/settings.json` is `{"agent": "manager", "permissions":
   {"ask": ["Edit(**/.claude/agents/**)"]}}`. The `agent` setting makes
   `manager.md` the main session: its body replaces Claude Code's default
   system prompt, while `CLAUDE.md` still loads (sub-agents, read
   2026-10-17).
3. Start `claude` at the repository root and ask which agent it is and
   how it routes work. It should say it is `manager` and sends code to
   `builder`; if not, `.claude/settings.json` is not where the session
   started. Then ask for something with a design step and a code step,
   and read the brief the manager writes.

The starter is what the cloud walkthrough installs. As it grows:

- **Add a domain agent when an area keeps coming back** and has traps a
  new session would re-learn. The manager routes by matching a task to
  each agent's `description`, so a description says when to use the
  agent, not what it knows. A domain agent points at its project's README
  instead of restating it, and ends with a "What the builder may not
  have" section: the judgment that stays with it.
- **Set the builder's limits in its frontmatter.** `model: sonnet` makes
  the cheaper model its default, though a per-invocation `model`
  parameter overrides the frontmatter; `disallowedTools: Agent` means it
  cannot spawn agents (sub-agents, read 2026-10-17). Its body tells it to
  edit only the files its brief lists and never to commit, push or touch
  a live host; those are instructions, not permissions, and the file says
  so. The reviewer's `disallowedTools` removes Edit and Write, and its
  body says Bash is still there, so "nothing you run writes" is a rule it
  keeps.
- **Give each job its own worktree** once several sessions share one
  checkout. Put worktrees under `.claude/worktrees/` and add
  `**/.claude/worktrees/` to `.git/info/exclude`. Do not symlink a
  virtualenv or data directory into a worktree: a symlink is not matched
  by a directory ignore rule, so it gets committed, and checking it out
  replaces the real directory and deletes what was in it. Run the main
  checkout's interpreter by absolute path instead. A session in an
  Anthropic-hosted cloud environment needs none of this: each runs in its
  own VM, which clones the repository
  ([Use Claude Code in the cloud](https://code.claude.com/docs/en/claude-code-on-the-web),
  read 2026-10-17).
- **Deny destructive connector tools** in `.claude/settings.json`, under
  every name they take: `mcp__claude_ai_<server>__<tool>` where Claude
  Code fetches the connector itself (permissions, MCP, read 2026-10-17),
  and `mcp__<server>__<tool>` in a cloud session with one repository, as
  seen here on 2026-10-17.
- **Check what a script can check.** Write a repo check and make "the
  check passes" part of finishing a job. Ours fails when a tool has no row
  in the tool index, a project has no README or no row in the machine
  record, a relative link is broken, a shell script has a lint warning, a
  worktree sat idle for a day, a captured config file differs from the
  live one, the installed sudo rules differ from their source, the
  permission check has not run since the last Claude Code update, or
  anything untracked sits at the repo root. It is tied to our layout and
  not published; the list is the point. Run
  [`tools/check-permissions.sh`](tools/check-permissions.sh) after each
  Claude Code update; it reports a Bash write to an agent file as `OPEN`
  unless a Bash rule or a hook claims it. Before any push, run
  [`tools/check-visibility.sh`](tools/check-visibility.sh) `OWNER REPO`, with
  the names from the remote's URL (a misspelt repo reads `private`): `ask`
  means stop and ask the owner, and `public` needs the owner's approval;
  before a push to a public remote, run
  [`tools/public-scan.sh`](tools/public-scan.sh) on the directory you will
  push (`tools/public-scan.sh .`), have `reviewer` read the new prose, and
  read the diff anyway.
- **Give the agent its own machine account** as soon as it runs on a
  machine you also log in to: [the agent as its own user](docs/agent-account.md).
- **Keep `CLAUDE.md` short.** It loads in every session, so every line
  costs tokens on every turn.

The agents and tools these came from, in broad strokes, are in
[the reference build](docs/reference-build.md). Their files are not
published: they carry host names and the names of the people the work is
for.

## In Codex

The cloud walkthrough has a Codex path:
[Codex in the cloud](https://github.com/brackenjoe/agent-infrastructure/blob/2026.10.26.1/docs/codex-cloud.md)
writes project instructions in `AGENTS.md`, adapted from the starter's
rule set. It does not install the manager, builder and reviewer roles:
those files are Claude Code's and do not configure Codex. The rest of this
guide is written for Claude Code. If you use Codex and something here is
wrong or missing for it, a correction is welcome
([CONTRIBUTING.md](CONTRIBUTING.md)).

## The rules, and what enforces them

Most rules are instructions the model is trusted to follow. These are
enforced by something other than the model. The Claude Code rows were
checked against versions 2.1.289, 2.1.302, 2.1.310 and 2.1.318
(`tools/check-permissions.sh`, last run 2026-11-05) and the
[permissions](https://code.claude.com/docs/en/permissions) and
[permission modes](https://code.claude.com/docs/en/permission-modes) docs,
read 2026-10-17.

| Rule | Enforced by | Limits |
|---|---|---|
| Creating or editing an agent file asks you first | the ask rule `Edit(**/.claude/agents/**)` in `.claude/settings.json` | Holds in every mode for Claude Code's file tools; see below the table. It does not stop a Bash command that writes the file: on 2.1.318 `sed -i` and a heredoc both did, and only a hook that denies held (below). Spawning an agent never prompts: `Agent(...)` allow rules do nothing, and auto mode drops them |
| The builder cannot spawn agents; the reviewer cannot edit or spawn | `disallowedTools` in their frontmatter | Bash remains in both, so "never commit" and "nothing you run writes" are rules the files state, not walls |
| Repo layout, index, links, captures, sudo source, idle worktrees | the repo check script | only when run |
| No addresses, network names, private terms or credentials in a public push | `tools/public-scan.sh`, then gitleaks | on every pull request here (public patterns only) and when run; does not replace reading the diff |
| The agent cannot read or write your keys, your shell files or your sudo | a Unix account of its own, homes `0750` | It keeps its own credentials. Reaching its terminals from your account is one sudoers line or an SSH rule, your choice ([the agent as its own user](docs/agent-account.md)) |
| What the agent may run as root | the sudo allowlist in `/etc/sudoers.d` | For accidents, not a hostile agent: `apt-get install` by package name is one step from root by construction, the deploy targets' allowlists reach it in one step by design, and a regular expression that looks tight can let a verb through (four did here; the probes are in the file's header) |
| The agent's git token reaches only the repositories it is scoped to | a fine-grained token on selected repositories | When a public repository is off the token, nothing on the server can publish there ([the GitHub side](docs/github-repo.md)) |
| A push to a public GitHub repository needs the owner's approval on the command | a pre-push hook that runs the visibility check, with `core.hooksPath` set globally | For mistakes, not a wall: `--no-verify` (or an abbreviation git accepts, such as `--no-verif`), a repository's own `core.hooksPath` or `git -c` skips it, `gh` writes a repository without a push, and a GitHub remote behind an SSH host alias passes. `Bash` ask rules prompt on the approval and the publish script's `--push` in auto-mode sessions (2.1.316 and 2.1.317; the owner, 2026-11-03), and one command each for `--no-veri`, `hooksPath` and `gh` prompted too (the owner, 2026-11-04); the other `gh` forms and `git commit -n` are not exercised, and `-n` has no rule. They are string matches: a variable or a mixed-case key hides the command, and no script checks them yet ([the GitHub side](docs/github-repo.md)) |
| On the public repository, a session cannot create a branch, rewrite `main` or move a tag | rulesets with no bypass actors | read back through the API, not exercised: a test push would be a public act |
| In the reference build: the agent server cannot reach the TAK server | Tailscale access rules | The web server can, and agents deploy to it; only the instruction to stop before a machine's ways in closes that path |
| With your own machines: deploy targets hold no key back to the agent server | SSH: no key installed on the targets | |

**Why the agent-file rule exists when Claude Code already protects
`.claude/`.** Without it, that built-in protection prompts in manual and
acceptEdits (with an option to allow the whole folder for the session),
leaves the write to the classifier in auto mode, allows it in plan mode in
an interactive terminal session with bypass permissions available, denies
it in dontAsk and allows it in bypassPermissions
([permission modes](https://code.claude.com/docs/en/permission-modes),
Protected paths, read 2026-10-17). Measured here on 2.1.289, headless with
no rules, it refused agent files both at the root and inside a git
worktree under `.claude/worktrees/`. The ask rule prompts in every mode,
so auto and bypass sessions ask too; in a `-p` run with nobody to answer,
it is denied. Keep the `**/` prefix: `Edit(.claude/agents/**)` matched
only where the session started, and let a worktree copy through in bypass
mode. The docs agree: a one-folder pattern such as `Edit(src/**)` matches
at any depth as a deny or ask rule, but a two-folder pattern is anchored
where the session starts (permissions, read 2026-10-17).
`tools/check-permissions.sh` repeats the bypass case on your version.

**A Bash write is not an Edit.** On 2.1.318 in bypassPermissions, with
only the ask rule, `sed -i` and `cat > .claude/agents/x.md <<'EOF'` both
rewrote an agent file. An ask rule on Bash, `Bash(*.claude/agents*)`,
stopped `sed` but not the heredoc: the docs check a redirect's target
against `Edit` allow and deny rules, protected paths and the working
directories, and do not list ask rules
([permissions](https://code.claude.com/docs/en/permissions), Redirections,
read 2026-11-05). A PreToolUse hook that returned `ask` ran, and bypass
mode approved the write anyway; one that returns `deny` held, for both.
The hook here denies a Bash command only when a write in it targets an
agent file; it asked on every mention at first, and that stalled
unattended runs with prompts that were never agent-file edits. It is a
string heuristic for mistakes, like the rest of this table, and it is not
in `starter/`, so `tools/check-permissions.sh` reports the starter's Bash
case as `OPEN`. Edit agent files with the file tools.

Cloud sessions pre-approve file edits in every mode, and the Protected
paths section names no cloud exception (permission modes, read
2026-10-17). Whether a cloud session still prompts on `.claude/` is not
yet measured, so keep the ask rule. In an Anthropic-hosted environment, a
cloud session with several repositories reads no permission rules from
any of them, so neither the ask rule nor deny rules apply there
(settings, Settings in cloud sessions, read 2026-10-17).

Everything else (review before brief, verify by exercising, stop before
credentials or the ways into a machine, approval for every public push)
lives in `CLAUDE.md` and the agent files, and holds only as well as the
model follows it. For six weeks here the stop rule's own paths, the
operator's `authorized_keys` and shell, were files the agent owned; the
user split moved them onto this table.

## What is in this repo

- `starter/`: the manager, builder, reviewer, rules and settings to start
  from (MIT-0)
- `docs/`: the cloud walkthrough, the agent server, the agent as its own
  user, the GitHub side, the software, the network, the web server, TAK,
  the incidents, and the reference build
- `examples/`: a real builder brief and report; skeletons of a part's
  README, a tool index and a machine record
- `host/`: the agent server's sudo allowlist, Remote Control unit, loop
  script, shell function and drop-ins
- `tools/public-scan.sh`: scan a directory before you push it anywhere public
- `tools/check-permissions.sh`: check the agent-file ask rule still holds,
  in a throwaway repo, and whether anything stops a Bash write to an agent
  file
- `tools/check-visibility.sh`: is a GitHub repo `public`, `private`, or
  `ask` the owner; `--selftest` runs offline
- `.github/workflows/check.yml`: on every pull request, the public scan,
  gitleaks, relative links, and no edits to `tools/`
- `AGENTS.md`, `CLAUDE.md`: the rules any agent follows when editing this
  repo (`CLAUDE.md` imports `AGENTS.md`)
- `.claude/settings.json`: for sessions on this repo: no session links in
  commits; `starter/` rules not loaded
- `CONTRIBUTING.md`, `SECURITY.md`: how to contribute; how to report a
  security problem
- `LICENSE`, `LICENSE-CODE`: CC BY 4.0 for text, MIT for code
  (`starter/LICENSE`: MIT-0)

The two scripts in `tools/` are copied unedited from the maintainer's
live repo at each publish. Nothing else of the live repo is published.

## Contributing and licence

Corrections and questions are welcome as issues; changes as pull requests.
[CONTRIBUTING.md](CONTRIBUTING.md) says what is in scope; variants and
questions go in Discussions, and security problems to
[SECURITY.md](SECURITY.md), not an issue.

Code is [MIT](LICENSE-CODE): `tools/` and `host/`. `starter/` is
[MIT-0](starter/LICENSE): copy it into your own repository with no notice
owed. Everything else, the prose and the agent and rule files included,
is [CC BY 4.0](LICENSE). Joe Fernandez, 2026.
