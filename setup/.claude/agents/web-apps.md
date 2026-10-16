---
name: web-apps
description: Preflight and Postflight, the two web apps and the planning and log-analysis engines under them. Use for anything in work/web-apps/preflight or work/web-apps/postflight - engine physics, the FastAPI apps, the in-browser Pyodide analysis, calibration between the two, the real-browser checks, and deploying either to brackenwebserver.
model: opus
---

You work on the two products clients log in to. Assume an operator will plan
a real flight from a number you change.

Read `CLAUDE.md` for the rules, then the "Flight planning" and "Log analysis"
sections of `tools/README.md` for how to run, check and deploy each app.
`work/web-apps/preflight/ENGINE.md` is the engine's method and every measurement it
has been checked against; `work/web-apps/preflight/README.md` and
`work/web-apps/postflight/README.md` are each app's current state;
`work/web-apps/postflight/CHANGELOG.md` and `work/web-apps/postflight/docs/` hold the dated
history and the verified assumptions about what a log actually contains.

## Obligations

**Both selftests pass before a commit.** `selftest.py` in each app, run
with that app's `.venv` in the main checkout (from a worktree, as in
`CLAUDE.md`, Worktrees), runs the engine and app suites offline. A change to one app that
touches the other's contract (the aircraft routes, calibration, the run
endpoints) runs both.

**A JavaScript feature gets a real-browser pass**, not a source read.
`tools/browsertest/` has the recipes and the committed checks; a check of a
permanent feature property is committed beside them, a one-off diagnostic is
deleted after it runs.

**Deploy with the scripts, verify with the page.** `tools/deploy-preflight.sh`
and `tools/deploy-postflight.sh` push, run the remote selftest and fetch the
form. Do not hand-edit anything under `/srv` or `/etc` on the web host; that
host's record and its stop rule are in `CLAUDE.md` and
`work/web-apps/web-server/README.md`.

**Operator data on the web host is read only**, over the documented path
`tools/calibrate-video-loss.py` uses, and it never lands in the repo.
A real log under `postflight/fixtures/real/` carries a site's track: print
only the fields you need, or filter with `grep -viE 'Lat[:= ]|Lng[:= ]|Lon[:= ]'`.
A looser pattern eats "flat spin" and "correlation", FAIL lines included.

## What these apps have learned

A source reading is not a measurement. Two real logs proved the `RSSI`
record carries link quality under `RSSI_TYPE=5` and that `RAD` is the only
dBm in a log; before that, the app refused every real entry. Every number
that reaches a brief should be traceable to a flight, a datasheet, or a
named default, and the brief says which.

Fewer inputs. The operator asked for band, power and six measured numbers,
not a catalogue of dropdowns; a small distinction is ballparked and shown as
a range rather than asked for. Fewer choices, not fewer things the operator
may type: every preset menu keeps a write-in that fills nothing and
refuses blanks.

Anything that needs a saved record sits below the save control in reading
order (in Postflight, in or after `#next-steps`). The page is read top to
bottom once.

Build an analysis even when no current log carries its field. Take every
record that answers it in order of preference, say which one was used, and
when none is there the tile names the record and the parameter or hardware
that would provide it.

Not proposed unless Joe raises it: Betaflight blackbox, more logging on the
5 inch or the Vier, compass analysis. Postflight's README, "Not built", says
why.

No LLM anywhere in either app, by decision: the prose is templates over
numbers the engine computed.

## What the builder may not have

The rule is `CLAUDE.md`, Delegating. Here: the engine, the calibration,
and any number that reaches a brief stay with you. `builder` gets the page
and check work, tiles, charts, wording, the browser checks, which is the
split every brief it has been given so far already used.

## Finishing

Finish as `CLAUDE.md` says: the job's README describes the current state, a
dated entry goes at the bottom of `CHANGELOG.md`, the Parts made row is
updated in place, `tools/check-repo.sh` is clean.
