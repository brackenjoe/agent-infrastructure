# Contributing

This repo is a working setup written up, so the most useful contributions
are the ones that make it more correct or easier to copy.

**Welcome**

- Corrections: a claim that is wrong on your Claude Code, Codex, Ubuntu,
  Tailscale, Cloudflare or TAK Server version. Use the Correction issue
  template: the version, the command and what it printed. Most of the
  guide is written for Claude Code, so a correction from a Codex user is
  especially useful.
- Gaps: a step you had to work out yourself that the guide should have said.
- Your own variant: how you split the domain agents, or a rule the harness
  can enforce that this setup leaves to instructions. Post it in
  Discussions, not issues.
- A security problem: not in an issue. See [SECURITY.md](SECURITY.md).

**Out of scope**

- Edits to `setup/` or `tools/`. Those files are copied from the live
  repo on each publish, so a change made only here is overwritten. Open an
  issue and it goes into the live file instead.
- Rewording for style alone.

**Before a pull request**

- Run `tools/public-scan.sh .` and read your own diff: no addresses,
  hostnames you did not mean to publish, or credentials.
- No em dashes; the prose style is short declarative sentences.
- Contributions are accepted under the licence of the file you change:
  MIT for `tools/`, `host/` and `setup/.claude/settings.json`, MIT-0 for `starter/`, CC BY 4.0
  for everything else.
