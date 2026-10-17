# Claude Code in the cloud

Phase 1 of [Set it up in the cloud](https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v5/docs/cloud.md), for Claude Code. Written
for the AI guiding the person. Written against Anthropic's docs read on
2026-10-16: [Get started with cloud sessions](https://code.claude.com/docs/en/web-quickstart)
and [Configure cloud environments](https://code.claude.com/docs/en/cloud-environments).
If a screen differs, those pages win.

## Before you start

- **Plan.** Cloud sessions need Claude Pro, Max, Team or Enterprise (for
  Enterprise, a premium or Chat + Claude Code seat). If the person has none,
  stop: they upgrade in claude.ai settings themselves, never through you.
- **Team or Enterprise.** An owner of their Claude organization may first
  have to turn on the GitHub connector. If the GitHub step shows "GitHub
  access is required for Claude Code cloud sessions", that is why; they
  ask their owner.

## Steps

1. **Open [claude.ai/code](https://claude.ai/code)** and sign in with their
   Claude account.
2. **Connect GitHub.** claude.ai/code prompts for it and sends them to
   GitHub's authorization page. They approve it there and come back.
3. **Install the Claude GitHub App on the new repository.** A session can
   work in a private repository only when the app is installed on it:
   [github.com/apps/claude/installations/new](https://github.com/apps/claude/installations/new).
   Tell them to choose "Only select repositories" and pick the new one;
   that grants the least.
4. **Environment.** On Pro and Max, onboarding creates one called
   **Default**; on Team and Enterprise, they accept the prefilled form. It
   uses **Trusted** network access: allowlisted domains only (package
   registries, GitHub, cloud SDKs). Leave it as is. Phase 2 only needs GitHub,
   and the raw GitHub address this guide is served from is on that list.
   Do not suggest **Full** network access.
5. **Start the first session.** Pick the new repository in the selector
   under the input box, and choose **Plan** as the permission mode: the
   session proposes what it will do and waits for approval before editing
   anything, the safest way to watch a first run. Cloud sessions do not
   offer Manual or Bypass modes. Then paste, word for word, the Phase 2
   prompt from
   https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v5/docs/cloud.md
   as the first message; the session starts when it is sent.
6. **What they will see.** The session may ask to run `curl` to read the
   guide; approve it. Then a plan: approve it if it lists the four files
   and three questions. It may then ask to run `mkdir` and `curl`
   commands that create `.claude/agents` and download four files, some
   into `.claude/`; that is expected, approve them.

## After Phase 2

The session pushes a branch. In the session, the diff indicator (for
example `+120 -0`) opens the changes; **Create PR** opens a pull request,
which they merge on GitHub. Sessions started after the merge load the
manager, the builder and the rules.

Worth knowing, and worth telling them:

- Each task gets its own session and its own branch, so the shared-checkout
  rules in this guide's full setup do not apply in the cloud.
- Their GitHub credentials stay on Anthropic's servers and never enter the
  session; a proxy attaches them.
- Cloud sessions count toward the same usage limits as the rest of their
  Claude use.
