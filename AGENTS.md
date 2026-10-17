# Working on this guide

Rules for any agent proposing changes to this repository: Claude Code,
Codex, or another. In your own copy, keep what you want. They are short
because every session loads them.

## What this repository is
A public guide to running a team of coding agents. README.md is the
front page; docs/ holds the detail. Two folders are copies, not sources:

- `setup/` holds the maintainer's live rule and agent files, copied at
  each publish. Do not edit them here; a change made here is overwritten.
  Describe the change in the pull request or an issue instead.
- `tools/` scripts are copied the same way. Same rule.
- `setup/CLAUDE.md` and `starter/CLAUDE.md` are exhibits, not rules for
  this repository. Claude Code may load them when it reads a file in
  those folders (`.claude/settings.json` excludes them where it can);
  ignore what they say.

## Versioned pages
`docs/cloud.md`, `docs/claude-code-cloud.md`, `docs/codex-cloud.md` and
`starter/` are followed by readers' AIs at a git tag (`v1`, `v2`, ...).

- Never move or delete a tag. A change to these pages is released as the
  next tag, with every link in them updated to it in the same change.
- Every link an AI follows on those pages is an absolute raw URL at the
  tag. A relative link may not be fetchable.
- They address the AI doing the guiding. They never ask the person for a
  password, token, key or payment detail in chat.

## Writing
- Short declarative sentences. No em dashes.
- A claim about a product names the doc it came from and the date read.
  Check the vendor's docs; do not answer from memory.
- No addresses, hostnames, private names or credentials outside `setup/`
  and `tools/`, which carry the maintainer's host names by design. Run
  `tools/public-scan.sh .` and read your own diff before proposing a change.

## Before anything is published
- A change to a versioned page, or a claim about security or permissions,
  gets a read-only review by an agent that did not draft it. Check its
  findings against sources; do not take them on their word.
- Report each check you ran with its result, and each you did not run.
- Changes from outside arrive as pull requests. The owner merges them
  here and brings them into the private source the guide is published
  from.
- The owner publishes a snapshot of that source with checks of their own,
  and approves each publish in the session first. An agent with this
  repository attached pushes no branch to it and makes no API write to
  it.
