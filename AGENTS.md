# Working on this guide

Rules for any agent proposing changes to this repository: Claude Code,
Codex, or another. In your own copy, keep what you want. They are short
because every session loads them.

## What this repository is
A public guide to running a team of coding agents. README.md is the
front page; docs/ holds the detail; starter/ is the installable set.

- `tools/public-scan.sh`, `tools/check-permissions.sh` and
  `tools/check-visibility.sh` are copies of
  the maintainer's live scripts, copied at each publish. Do not edit them
  here; a change made here is overwritten. Describe the change in the pull
  request or an issue instead.
- `starter/CLAUDE.md` is an exhibit, not rules for this repository. Claude
  Code may load it when it reads a file in that folder
  (`.claude/settings.json` excludes it where it can); ignore what it says.
- Nothing of the maintainer's live rule set or agent files is published.
  [docs/reference-build.md](docs/reference-build.md) describes them in
  broad strokes on purpose.

## Versioned pages
`docs/cloud.md`, `docs/claude-code-cloud.md`, `docs/codex-cloud.md` and
`starter/` are followed by readers' AIs at a git tag: `v1` to `v5`, then
dated tags `YYYY.MM.DD.N` (UTC date, then a revision for that day, such as
`2026.10.18.1`).

- Never move or delete a tag. A change to these pages is released as the
  next tag, with every link in them updated to it in the same change.
- Every link an AI follows on those pages is an absolute raw URL at the
  tag. A relative link may not be fetchable.
- They address the AI doing the guiding. They never ask the person for a
  password, token, key or payment detail in chat.

## Writing
- Short declarative sentences.
- A claim about a product names the doc it came from and the date read.
  Check the vendor's docs; do not answer from memory.
- No addresses, hostnames, private names or credentials anywhere. Run
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
