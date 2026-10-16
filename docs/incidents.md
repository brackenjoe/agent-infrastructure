# Incidents, and the rules they produced

[Back to the README](../README.md). Most rules in [`setup/`](../setup/) exist
because something went wrong first. These are fourteen that produced a
rule and one that has not yet, from six weeks of running this setup
(September and October 2026), newest first. Security details are left
out; the rule each one produced is in the live files.

| Date | What went wrong | How it was caught | Rule now |
|---|---|---|---|
| 2026-10-16 | A builder's test commit, titled "feat" and adding a one-line file named `f`, landed in the guide's source folder in the private repo. The builder is told never to commit; that is an instruction, not a permission. | Reading the publish stage before the push. Reverted; never public. | None yet. The instruction stands, and the publish step shows every file for the owner to read before anything is pushed. |
| 2026-10-16 | The first version of `tools/check-permissions.sh` could report a pass with no evidence that anything had been refused. The revision that fixed it claimed, from the docs' protected-paths list, that the built-in protection skips agent files in worktree copies. Measured on 2.1.289, it refuses them. | A read-only review by an agent with none of the drafting context, in two passes, before the push | The script needs a recorded denial and a negative control, or it reports inconclusive. The worktree claim was measured and corrected, and `tools/check-permissions.sh` runs after every Claude Code update. |
| 2026-10-16 | The published enforcement table, written from reading the docs, was wrong three ways. It said spawning an unlisted agent asks first: `Agent(...)` allow rules do nothing, and spawning never prompts. It said `bypassPermissions` skips ask rules: they hold. It said `Edit(.claude/agents/**)` matches at any depth: it matched only where the session starts, and let a worktree copy through in bypass mode. | A cold review by an agent with none of the drafting context; its findings checked against the [permissions](https://code.claude.com/docs/en/permissions) and [permission modes](https://code.claude.com/docs/en/permission-modes) docs, read 2026-10-16 | The ask rule is `Edit(**/.claude/agents/**)`, and `tools/check-permissions.sh` measures it after each Claude Code update. New or rewritten public prose gets a read-only review by an agent with none of the drafting context before the push. |
| 2026-10-03 | The manager briefed domain agents (Opus) to "build X to the contract" instead of routing code to the cheaper builder. Four direction-finding builds ran 450 to 680 turns each: about a quarter of two weeks' subagent usage (an estimate, weighting turns by model), against 5.5% for the builder. | A review of 14 days of transcripts | Code to a settled design goes to `builder` from every agent; a report names each builder brief or says why there was none. |
| 2026-09-28 | Requests were turned straight into briefs. A 20 mm strap channel in a printed mount would have been briefed as asked, and the strap had nowhere to close. | Not recorded; the example suggests the manager's own review | Every request is reviewed against the source and the measured numbers, and answered approve or push back, before a brief. |
| 2026-09-27 | An overnight review found two exposures in the RF sensor's software, and a closed-loop result that had been read from an agent's report, not rerun. | The manager, with a second model as reviewer | Both exposures fixed; review documents say which checks were rerun and which were read from records. |
| 2026-09-24 | During a TAK Server upgrade the agent built a theory (a filename case mismatch) for an install failure. The file had never been transferred. | Not recorded | `ls` comes before any theory; a transfer step in the procedure. |
| 2026-09-23 | From one failed `ssh` attempt an agent concluded the box could reach no remote server, and wrote it into the machine record's "Decided against" section, the one meant to stop questions being reopened. It had never read `~/.ssh/config`. | Not recorded | Read `~/.ssh/config` before claiming anything about reachability; a measured reachability table; corrections go in as corrections, not quiet edits. |
| 2026-09-20 | To run tests in a worktree, a session symlinked a gitignored directory. The ignore rule did not match a symlink, `git add -A` committed it, and checking it out replaced the real directory: five real flight logs deleted from the box. Copies were held elsewhere. | Not recorded | Never symlink into a worktree; run the main checkout's interpreter by path; add files by explicit path; ignore rules that match symlinks. |
| 2026-09-20 | Four sessions shared one checkout. One took a `git stash` over another session's uncommitted work. | Not recorded | One job, one worktree; never stash in the shared tree; a check fails on any worktree older than a day. |
| 2026-09-20 | Auditing the log analyser for a new firmware, the orchestrating session predicted findings from reading source, and several were wrong. Code it reasoned would fail safe raised an error on all 26 tiles; a claimed data span was 93.9% in a different flight mode; the report printed "No ATT and RATE records" over 9549 ATT and 44372 RATE rows. | Four parallel builders, measuring. Two corrected the orchestrator, one corrected itself, and one stopped at its file-list boundary and handed back the two edits it could not make. | Findings are measured, not predicted; fixes are pinned by browser assertions shown to fail when the fix is stubbed out. |
| 2026-09-20 | Delete buttons in a web app looked guarded in the source and were not: the page's content security policy blocked the inline confirm, so the form submitted. | Clicking one | Real-browser checks for destructive controls. |
| 2026-09-20 | A firmware-upgrade README carried a hand-typed status-bit table wrong from bit 4 up, a link mapping off by one, and nine lost telemetry rates dismissed as "probably GCS residue". | Running the commands the README told the reader to run | Values come from the library's own enums; settings are written and read back after a reboot. |
| 2026-09-17 | A design for pushing missions to TAK had six defects, among them a followed redirect that would resend the client certificate. | A second-model review | Eleven new self-tests; every failure path fails closed ([TAK integration](tak-integration.md#fail-closed)). |
| 2026-09-04 | An afternoon on a recovery watchdog, for a hang the box had never had, produced four successive wrong conclusions. A service reading `active` was taken as evidence it worked; the box hard-hung three minutes after the watchdog was armed. | Measuring the watchdog's timer, which never moved | Verify by exercising the thing, not by seeing that it started; check the base rate before building a mitigation. |

## Four patterns

1. **A claim from reasoning or a single negative, not a measurement:** the
   reachability claim, the predicted audit findings, the watchdog, the
   upgrade theory, the first enforcement table.
2. **A check that existed but did not exercise the act:** the
   guarded-looking delete, the `active` service, the result read from a
   report, the permission check that could pass without a refusal.
3. **Cost from routing, not capability:** the most expensive failure was not
   a wrong answer but the right work done by the wrong model.
4. **An instruction, not a permission:** the builder's commit. The table of
   [what enforces which rule](../README.md#the-rules-and-what-enforces-them)
   is the short list of rules that are not like this.

The cheap, bounded builders checked the stronger orchestrator more often
than the reverse, because their file lists made them measure before they
could change anything.
