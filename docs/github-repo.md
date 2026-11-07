# The GitHub side

[Back to the README](../README.md). What is set on GitHub for the private
repository the agents work in, for the agent's token, and for a public
repository the agents help maintain. Everything here was read from GitHub's
own settings pages or its API on the dates given; GitHub's docs win where
the screens have changed.

## The private repository

- **Private.** The agents' repository holds host records, captured config
  and work for named people. Check visibility before every push rather
  than assuming it; `check-visibility.sh` from
  [publish-gates](https://github.com/brackenjoe/publish-gates) prints `public`, `private` or `ask`, and `ask`
  means ask the owner.
- **A pre-push hook backs that check** (publish-gates, `git-hooks/pre-push`).
  On a push to a github.com remote it runs the visibility script and lets
  only `private` through. `public`, `ask`, a URL it cannot read, or a
  failure of the check (no network answers `ask`) is refused with the
  reason. The owner's approval goes on the command as an environment
  variable. Set `core.hooksPath` globally on the server, so a fresh clone
  is covered too. A push to a remote that is not on GitHub passes. The same
  hook scans every commit being pushed for a GitHub cross-reference (below)
  unless the target is known public, so the push is the gate for that rule
  too.
- **Its limits.** It catches an agent's mistake; it is not a wall.
  `--no-verify` skips it, and so does any abbreviation git accepts:
  git 2.43.0 takes `--no-verif` and `--no-veri` (`--no-ver` is
  ambiguous). `gh release create` or a `gh api` write reaches a repository
  with no push at all. A repository's own `core.hooksPath`, or one
  given with `git -c`, replaces the global one, so check fork checkouts
  and projects whose install sets one. A GitHub remote reached through an
  SSH host alias is not recognised as GitHub and passes. Here `ask` rules
  in the agents' permission settings are meant to prompt on the approval
  variable, on `--no-veri` (the shortest form), on `hooksPath` in either
  case and on `gh` write forms. `git commit -n`, the short form of
  `--no-verify`, has no rule and skips the commit-msg hook below, as do
  cherry-pick, rebase and `am`; since 2026-11-05 the pre-push scan above
  catches those at the push, except under `git push --no-verify` or when
  the target is known public. The approval rule
  and the `--push` rule below prompt the owner in auto-mode sessions
  (Claude Code 2.1.316 and 2.1.317; the owner's word, 2026-11-03), and so
  did one command for each of the others (the owner, 2026-11-04): a
  `--no-veri` dry-run push, a `-c core.hooksPath=/dev/null` command and
  `gh release list`, which is a read. The rest of the `gh` forms are not
  exercised. These are string matches:
  a variable or a mixed-case key hides the command, and no script checks
  them yet. The agent cannot see a prompt the owner answers, only that
  the command ran: an earlier version of this page said these rules did
  not prompt, from an agent's record that took one for the other. Ask the
  person.
- **One owner merges.** Cloud sessions push their own branches and the
  owner merges; on the server the agents commit to `main` and push. Nothing
  is force-pushed.
- **No cross-references to public repositories in commit messages.**
  `owner/repo#N`, `owner/repo@sha` and a GitHub item URL in a private
  commit message are linked by GitHub into the public item's timeline,
  with the private commit's title visible. Write "owner/repo PR N". A
  `commit-msg` hook (publish-gates) refuses the linked forms in the repos
  listed in git config `gates.privateRepo`, and pre-push refuses the push;
  a fresh clone enables the hooks with `git config core.hooksPath <dir>`,
  and the repo check fails when it is not set.
- **The noreply address** as the commit email. With email privacy on,
  GitHub refuses a push whose commits carry the private address (GH007).
- **The Claude GitHub App on selected repositories only.** A cloud session
  can work in a private repository only when the app is installed on it
  ([Claude Code in the cloud](claude-code-cloud.md)); "Only select
  repositories" grants the least.

## The agent's token

The agent authenticates to GitHub with a fine-grained personal access
token in `~/.git-credentials` (`credential.helper=store`, mode 600), as
its own Unix user ([the agent as its own user](agent-account.md)).

- **Fine-grained, selected repositories, no account permissions.** Here:
  metadata read, contents read and write, workflows read and write
  (needed to push a change under `.github/workflows/`; GitHub refused
  such a push until it was granted, 2026-10-17). Read the token's own
  settings page to know what it reaches; do not trust a record.
- **Expiry is the owner's call.** A token that expires forces a rotation
  the owner has to be around for; here the owner chose none, with the
  reach kept short instead.
- **The token is a lock.** When a public repository is not being
  published, take it off the token. Then no session on the server can
  push there whatever a script or a rule says.
- **Rotation never passes through a session.** The owner writes the new
  token over SSH (`read -rs T`, then `printf` into the file), never in a
  chat. Test it with `curl` against the repository's API URL first (200
  good, 404 no access, 401 bad token): the `store` helper erases the
  credentials file on any failed git authentication, so a failed
  `git ls-remote` destroys the evidence.
- **Two-factor on the GitHub account**, and a passkey on the Claude
  account that the agent server's login belongs to.

## A public repository

This guide's own repository is the example. Set once, read back through
the API rather than exercised, since a test push would be a public act.

- **Rulesets, no bypass actors.** `main`: no deletion, no non-fast-forward
  push. "No new branches": a `creation` rule on every branch but `main`.
  "Version control": `update`, `deletion` and non-fast-forward on
  `refs/tags/v*` and `refs/tags/20*`. With these, a session holding the
  token can push a fast-forward commit to `main`, and cannot create a
  branch, rewrite history or move or delete a tag. It can still create a
  new tag, and with contents write it can create a release; neither is
  blocked here.
- **Secret Protection and push protection on.** Push protection blocks a
  commit carrying a known provider token shape, including a commit made
  in the web editor (GitHub Docs, About push protection, read
  2026-10-17). It knows providers' token shapes only; host names,
  addresses and your own private terms are your scanner's job.
- **Private vulnerability reporting on**, so a security problem has
  somewhere to go that is not an issue ([SECURITY.md](../SECURITY.md)).
- **A checks workflow on every pull request**
  ([`.github/workflows/check.yml`](../.github/workflows/check.yml)): the
  public scan with the scanner taken from the base commit, gitleaks
  pinned by version and checksum with its pinned default config, every
  file readable by the scanner, relative links, and a warning on any
  change to a versioned page or to the workflow itself. It is for
  mistakes, not for a pull request built to hide something; the owner
  reads every one.
- **Published as snapshots.** The public history is a chain of single
  commits by a fixed identity, dated in UTC, each the whole tree at one
  moment of the private source. No private history, author or time zone
  leaves. The publish script is a dry run by default; it runs the gates,
  prints the files that change and an approval hash over the target, the
  base commit, the tree and the message; `--push <hash>` rebuilds, reruns
  everything and pushes only that. The owner's own settings allow the dry
  run and put every `--push` behind an ask rule, which prompts the owner
  (above). The approval hash is an unkeyed
  checksum of the target, base, tree and message: it makes sure what is
  pushed is what the dry run showed, and approves nothing. The ask rule is
  the only approval. A sync guard stops the
  dry run when public `main` has moved (a merged pull request), until the
  change is brought into the private source.
- **Release tags are made by hand** after a publish that changed a
  versioned page: the script names the next tag; the owner creates it
  from the Releases page; a link checker then runs over the tag. Tags are
  never moved, so a reader's AI following a pinned URL sees what was
  reviewed.
