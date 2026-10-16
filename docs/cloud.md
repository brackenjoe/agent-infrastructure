# Set it up in the cloud

The simplest way to try this setup: no server, nothing to install. An AI
walks you through it.

**Before you start.** You need a paid plan for the tool. Claude Code in
the cloud needs Claude Pro, Max, Team or Enterprise. Codex in the cloud
needs a ChatGPT plan that includes Codex; check OpenAI's pages. Claude
Code installs its starter agents; Codex writes project instructions in
AGENTS.md.

## For you: three steps

1. **Make a GitHub account** at [github.com/signup](https://github.com/signup),
   if you do not have one.
2. **Open an AI chat you already use** that can open links, such as Claude
   or ChatGPT.
3. **Paste this into it:**

   > Read https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/docs/cloud.md
   > and walk me through setting it up, one step at a time.

It will ask which tool you want, help you make a repository, connect it,
and start your first cloud session. That session installs the Claude Code
starter or writes Codex project instructions, depending on the tool you
chose.

This page gives your AI instructions. It is pinned to version `v2`;
changes go to a new version, not into this one. Skim it first, it is
short. If your AI says it cannot open links, paste the text of this page
and of the product page (`docs/claude-code-cloud.md` or
`docs/codex-cloud.md` in the same repository) into it instead.

---

## For the AI reading this

You are guiding a person who may never have used GitHub or a coding agent.
This is version `v2` of a public guide,
[agent-infrastructure](https://github.com/brackenjoe/agent-infrastructure).
Every link below is the exact URL to open.

### Rules, for every step

- One step at a time. Say what to click or type, then wait for the person
  to say it is done or what they see instead.
- Never ask for a password, token, key, recovery code or card number in
  the chat, and never write one into a file. Sign-ins and payments happen
  in the person's browser; tell them where, then stop until they confirm.
- Do not guess at screens you cannot see. If what they describe differs
  from these steps, say so, and check the product's own docs before
  suggesting anything else.
- Each product page says which docs it was written against. If the
  product has changed since, the product's docs win; say so.

### Phase 1: in this chat

1. Ask which tool they want: **Claude Code** in the cloud, or **Codex** in
   the cloud. If they are unsure, ask which AI subscription they already
   pay for. Explain that Codex uses AGENTS.md rather than the Claude Code
   starter.
2. Have them make a new **private** repository on GitHub
   ([github.com/new](https://github.com/new)) with a short name, and tick
   **Add a README file**, so the repository starts with a main branch.
3. Walk them through the product steps:
   - Claude Code: https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/docs/claude-code-cloud.md
   - Codex: https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/docs/codex-cloud.md
4. The product steps end with the person pasting the Phase 2 prompt as the
   first message of a cloud session on the new repository. Your part ends
   there, unless they come back with a question.

The Phase 2 prompt, for the person to paste:

> Read https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/docs/cloud.md,
> sections "Rules, for every step" and "Phase 2", and do them.

### Phase 2: inside the cloud session

You are now the coding agent, in the person's new repository. For Codex,
read https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/docs/codex-cloud.md
and follow its "Phase 2: inside the Codex cloud task" section. Do not
install
the Claude Code starter. The remaining steps here cover Claude Code only.

1. Download each file byte for byte with `curl -fsSL <url> -o <path>`, not
   with a web-fetch tool that summarises, into these paths at the
   repository root:

   | URL | Path |
   |---|---|
   | https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/starter/CLAUDE.md | `CLAUDE.md` |
   | https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/starter/.claude/settings.json | `.claude/settings.json` |
   | https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/starter/.claude/agents/manager.md | `.claude/agents/manager.md` |
   | https://raw.githubusercontent.com/brackenjoe/agent-infrastructure/v2/starter/.claude/agents/builder.md | `.claude/agents/builder.md` |

   If a file already exists, show the person the difference and ask before
   replacing it.
2. Show the person `.claude/settings.json` in full, either way. It must
   contain only `agent` and `permissions.ask`. If it has `hooks`, `allow`,
   `env` or any other key, stop and tell them something changed upstream.
3. Ask the person three questions, one at a time, and write the answers
   into the "This project" section of `CLAUDE.md`: what the project is;
how
   to check work (a command, or "nothing yet"); what needs their approval
   before it happens.
4. Commit on a branch and push it. Tell the person to open the changes
   with the diff indicator, select **Create PR**, then merge the pull
   request on GitHub. The files take effect in sessions started after the
   merge.
5. Tell them to start a **new** cloud session on the repository and ask:
   "Which agent are you, and how do you route work?" It should answer that
   it is `manager`, reviews each request, and sends code to `builder`.
Then
   ask it for a one-line change to README.md, and check that it pushes a
   branch and that **Create PR** appears. If either fails, the settings
did
   not load or the session lost its push step: check
`.claude/settings.json`
   is on the default branch, and tell them to report it as an issue on the
   guide.
6. Suggest a small first task with a design step and a code step, and tell
   them to read the brief the manager writes and the builder's report.
That
   is the pattern working.

Then point them at the guide's README,
https://github.com/brackenjoe/agent-infrastructure/blob/v2/README.md, for
what to add next: a domain agent when an area keeps coming back, and the
checks in `tools/`.
