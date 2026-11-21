#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
"""Finish a security-audit run: hand-backs, findings.json, derived reports.

    python3 -I tools/security-audit-finish.py handback OUT ID=TRANSCRIPT
        [ID=TRANSCRIPT]... [--force]
    python3 -I tools/security-audit-finish.py findings OUT
    python3 -I tools/security-audit-finish.py derive OUT

handback: TRANSCRIPT is a subagent JSONL transcript (one JSON event per
line). The LAST SubagentHandback tool_use block in any event's
message.content list supplies input.message; one surrounding ``` fence
(with or without a language tag) is stripped, the rest is parsed as JSON and
written to OUT/agents/ID/result.json (indent 1). ID must be a canonical
agent id. An existing result.json is never overwritten without --force (the
whole call is refused before anything is written). One summary line per ID:
a hunter (has "units") shows its dispositions and candidate count; a
verifier ({"decision","record"}) its decision and record verdict; a critic
(has "missing_units") its counts and stop. An ID with no hand-back or a
non-JSON one is reported and the rest are still processed; the exit is 1.

findings: builds OUT/findings.json from OUT/candidates.json (fingerprint ->
{verifier, ...}). Each record is the "record" of
OUT/agents/<verifier>/result.json and must carry its fingerprint. When
OUT/record-verifiers.json maps the fingerprint to a Phase 5 id whose
OUT/agents/<id>/result.json exists: decision "verified" keeps the record;
decision "replace" applies the replacement only if its verdict and
fingerprint equal the current ones, else Fail ("material replacement: needs
a fresh verifier"). A bare evidence file name that is a file in
OUT/agents/<verifier>/artifacts/ becomes "agents/<verifier>/artifacts/<name>";
every evidence path starting "agents/" must exist under OUT. Records are
sorted by fingerprint. Prints the counts by verdict, the Phase 5 decision per
record, and the fingerprints with no Phase 5 result (the run is incomplete
while any exist).

derive: writes OUT/FINDINGS-DETAIL.md (confirmed records) and
OUT/NEEDS-VALIDATION.md (needs_validation records) from OUT/findings.json,
with the who-line from candidates.json and record-verifiers.json. The run
date is the date inside run-metadata.json's run_id, else today (UTC); the
profile and part come from run-metadata.json when present.

Exit 0 done, 1 missing or invalid input or a refusal, 2 usage.
Standard library only.
"""

import datetime
import json
import os
import re
import sys
import tempfile
from pathlib import Path

AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
WIN_DEVICES = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {
    f"lpt{i}" for i in range(1, 10)}
USAGE = ("usage: security-audit-finish.py handback OUT ID=TRANSCRIPT "
         "[ID=TRANSCRIPT]... [--force]\n"
         "       security-audit-finish.py findings OUT\n"
         "       security-audit-finish.py derive OUT")
MODES = ("handback", "findings", "derive")


class Fail(Exception):
    """Exit 1: missing or invalid input, or a refusal."""


# ---------------------------------------------------------------- reading

def read_json(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        raise Fail(f"missing input: {path} ({e.strerror})")
    try:
        return json.loads(text)
    except ValueError as e:
        raise Fail(f"invalid JSON in {path}: {e}")


def check_agent_id(value, what):
    if (not isinstance(value, str) or not AGENT_ID.match(value)
            or value in WIN_DEVICES):
        raise Fail(f"{what} is not a canonical agent id: {value!r}")
    return value


def write_json(path, obj):
    """Write atomically: a temp file in the same directory, then rename."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=1, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_object(path, what):
    obj = read_json(path)
    if not isinstance(obj, dict):
        raise Fail(f"{path} is not an object ({what})")
    return obj


# --------------------------------------------------------------- handback

def last_handback(transcript):
    """The message of the last SubagentHandback tool_use block, or None."""
    try:
        fh = open(transcript, encoding="utf-8")
    except OSError as e:
        raise Fail(f"missing input: {transcript} ({e.strerror})")
    msg = None
    with fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            content = (ev.get("message") or {}).get("content") if isinstance(ev, dict) else None
            if not isinstance(content, list):
                continue
            for b in content:
                if (isinstance(b, dict) and b.get("type") == "tool_use"
                        and b.get("name") == "SubagentHandback"):
                    inp = b.get("input")
                    m = inp.get("message") if isinstance(inp, dict) else None
                    if isinstance(m, str):
                        msg = m
    return msg


def strip_fence(text):
    s = text.strip()
    if s.startswith("```"):
        lines = s.split("\n")
        lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        s = "\n".join(lines)
    return s


def summarize(aid, r):
    if "units" in r:
        units = r["units"] if isinstance(r["units"], list) else []
        disp = [u.get("disposition") if isinstance(u, dict) else None for u in units]
        cands = r.get("candidates")
        return f"{aid}: hunter dispositions {disp} candidates {len(cands) if isinstance(cands, list) else 0}"
    if "decision" in r and "record" in r:
        rec = r["record"] if isinstance(r["record"], dict) else {}
        return f"{aid}: verifier decision {r['decision']} record verdict {rec.get('verdict', '-')}"
    if "missing_units" in r:
        def n(k):
            v = r.get(k)
            return len(v) if isinstance(v, (list, dict)) else 0
        return (f"{aid}: critic missing_units {n('missing_units')} reassign_ids {n('reassign_ids')} "
                f"resolved_prior_leads {n('resolved_prior_leads')} stop {r.get('stop')}")
    return f"{aid}: result with keys {sorted(r)}"


def cmd_handback(out, pairs, force):
    items = []
    seen = set()
    for pair in pairs:
        if "=" not in pair:
            raise Fail(f"not ID=TRANSCRIPT: {pair!r}")
        aid, transcript = pair.split("=", 1)
        check_agent_id(aid, "hand-back ID")
        if aid in seen:
            raise Fail(f"hand-back ID given twice: {aid}")
        seen.add(aid)
        dest = out / "agents" / aid / "result.json"
        if dest.exists() and not force:
            raise Fail(f"{dest} exists; pass --force to overwrite")
        items.append((aid, transcript, dest))
    bad = 0
    for aid, transcript, dest in items:
        msg = last_handback(transcript)
        if msg is None:
            print(f"{aid}: NO HANDBACK in {transcript}")
            bad += 1
            continue
        try:
            r = json.loads(strip_fence(msg))
        except ValueError as e:
            print(f"{aid}: NOT JSON ({e})")
            bad += 1
            continue
        if not isinstance(r, dict):
            print(f"{aid}: NOT JSON (hand-back is not an object)")
            bad += 1
            continue
        write_json(dest, r)
        print(summarize(aid, r))
    if bad:
        raise Fail(f"{bad} of {len(items)} hand-backs missing or not JSON")


# --------------------------------------------------------------- findings

def fix_evidence(out, rec, verifier):
    art = out / "agents" / verifier / "artifacts"
    fixes = []
    ev = rec.get("evidence", [])
    if not isinstance(ev, list):
        raise Fail(f"record {rec.get('fingerprint')}: evidence is not a list")
    for e in ev:
        if not isinstance(e, dict) or not isinstance(e.get("file"), str):
            continue
        f = e["file"]
        if "/" not in f and "\\" not in f and (art / f).is_file():
            e["file"] = f = f"agents/{verifier}/artifacts/{f}"
            fixes.append(f)
        if f.startswith("agents/"):
            p = os.path.normpath(f)
            if p.startswith("..") or not os.path.isfile(out / p):
                raise Fail(f"record {rec.get('fingerprint')}: evidence path {f} "
                           f"does not exist under {out}")
    return fixes


def cmd_findings(out):
    cands = load_object(out / "candidates.json", "fingerprint -> candidate")
    rv_path = out / "record-verifiers.json"
    rv = load_object(rv_path, "fingerprint -> agent id") if rv_path.exists() else {}
    for fp in rv:
        if fp not in cands:
            raise Fail(f"record-verifiers.json maps {fp}, which is not in candidates.json")
    records, decisions, missing, fixes = [], {}, [], 0
    for fp in sorted(cands):
        c = cands[fp]
        v = c.get("verifier") if isinstance(c, dict) else None
        check_agent_id(v, f"candidates.json[{fp}].verifier")
        res = load_object(out / "agents" / v / "result.json", "verifier result")
        rec = res.get("record")
        if not isinstance(rec, dict):
            raise Fail(f"agents/{v}/result.json has no record")
        if rec.get("fingerprint") != fp:
            raise Fail(f"agents/{v}/result.json: record fingerprint "
                       f"{rec.get('fingerprint')!r} is not {fp!r}")
        pid = rv.get(fp)
        p5 = None
        if pid is not None:
            check_agent_id(pid, f"record-verifiers.json[{fp}]")
            p5path = out / "agents" / pid / "result.json"
            if p5path.exists():
                p5 = load_object(p5path, "Phase 5 result")
        if p5 is None:
            missing.append(fp)
        else:
            d = p5.get("decision")
            if d == "verified":
                if p5.get("fingerprint", fp) != fp:
                    raise Fail(f"{pid}: verified {p5.get('fingerprint')!r}, expected {fp!r}")
            elif d == "replace":
                new = p5.get("record")
                if not isinstance(new, dict):
                    raise Fail(f"{pid}: replace has no record")
                if new.get("verdict") != rec.get("verdict") or new.get("fingerprint") != fp:
                    raise Fail(f"material replacement: needs a fresh verifier "
                               f"({fp}: {pid} changes verdict {rec.get('verdict')!r} -> "
                               f"{new.get('verdict')!r} or fingerprint {new.get('fingerprint')!r})")
                rec = new
            else:
                raise Fail(f"{pid}: unknown Phase 5 decision {d!r}")
            decisions[fp] = f"{pid} {d}"
        fixes += len(fix_evidence(out, rec, v))
        records.append(rec)
    write_json(out / "findings.json", records)
    counts = {}
    for r in records:
        counts[r.get("verdict")] = counts.get(r.get("verdict"), 0) + 1
    print(f"{len(records)} records: " + ", ".join(f"{k} {n}" for k, n in sorted(counts.items(), key=str)))
    print(f"evidence paths fixed: {fixes}")
    for fp in sorted(decisions):
        print(f"phase 5: {fp}: {decisions[fp]}")
    if missing:
        mp = out / "run-metadata.json"
        prof = (load_object(mp, "run metadata") if mp.exists() else {}).get("profile")
        if prof == "quick":
            # VALIDATION-AND-REPORTING.md: under quick, Phase 3 and Phase 5
            # merge; the Phase 3 verifier's record is the final one.
            print("quick profile: Phase 5 merged into Phase 3 for: " + ", ".join(missing))
        else:
            print("No Phase 5 result for: " + ", ".join(missing))
            print("These make the run incomplete.")


# ----------------------------------------------------------------- derive

def run_date(out):
    p = out / "run-metadata.json"
    meta = load_object(p, "run metadata") if p.exists() else {}
    m = re.search(r"\d{4}-\d{2}-\d{2}", str(meta.get("run_id") or ""))
    date = m.group(0) if m else datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return date, meta


def cmd_derive(out):
    F = read_json(out / "findings.json")
    if not isinstance(F, list):
        raise Fail("findings.json is not an array of records")
    c = load_object(out / "candidates.json", "fingerprint -> candidate")
    rvp = out / "record-verifiers.json"
    rv = load_object(rvp, "fingerprint -> agent id") if rvp.exists() else {}
    date, meta = run_date(out)
    profile = meta.get("profile") or "standard"
    part = meta.get("part") or "(part not recorded)"

    def tr(r):
        return "\n".join(f"{i}. `{t['file']}:{t['line']}` ({t['kind']}, {t['scope']}): {t['description']}"
                         for i, t in enumerate(r["trace"], 1))

    def ev(r):
        return "\n".join(f"- `{e['file']}:{e['line']}`: {e['description']}" for e in r["evidence"])

    def who(fp):
        cf = c.get(fp)
        if not isinstance(cf, dict):
            raise Fail(f"candidates.json has no {fp}")
        s = f"Hunter {cf['hunter']}; Phase 3 verifier {cf['verifier']}"
        if cf.get("attempts"):
            s += f" (earlier attempt {', '.join(a['verifier'] for a in cf['attempts'])} archived)"
        if profile == "quick" and fp not in rv:
            return s + " (quick: Phase 5 merged into Phase 3)."
        return s + f"; Phase 5 {rv.get(fp, 'not run (budget)')}."

    try:
        d = [f"# Findings detail, {date} {profile} run\n",
             "Derived from `findings.json`; the JSON is authoritative. Paths are relative to "
             f"`{part}`. Artifacts are under `agents/<id>/artifacts/` beside this file.\n"]
        for r in [x for x in F if x.get("verdict") == "confirmed"]:
            s = r["severity"]
            d += [f"\n## {r['title']}\n",
                  f"Fingerprint `{r['fingerprint']}`. Severity: likelihood {s['likelihood']['score']}, "
                  f"impact {s['impact']['score']}, overall **{s['overall_severity']}**. "
                  f"Confidence {r['confidence']['score']}. {who(r['fingerprint'])}\n",
                  r["description"] + "\n",
                  "**Root cause.** " + r["root_cause"] + "\n",
                  "**Intended behaviour.** " + r["intended_behavior"] + "\n",
                  "**Trace**\n\n" + tr(r) + "\n",
                  "**Evidence**\n\n" + ev(r) + "\n",
                  "**Observed result.** " + r["execution"]["observed_result"] + "\n",
                  "**Conditions.** " + " ".join(f"{x['kind']}: {x['description']}" for x in r["conditions"]) + "\n",
                  "**Remediation.** " + r["remediation"]["strategy"] + "\n",
                  f"**Severity reasons.** Likelihood: {s['likelihood']['reason']} "
                  f"Impact: {s['impact']['reason']}\n"]
        n = [f"# Needs validation, {date} {profile} run\n",
             "Derived from `findings.json`. No severity is assigned to these records. Local steps run "
             "in the sandbox (`tools/security-audit-sandbox.sh`); owner checks are observations, "
             "never audit traffic against the deployment.\n"]
        for r in [x for x in F if x.get("verdict") == "needs_validation"]:
            vp = r.get("validation_plan") or {}
            n += [f"\n## {r['title']}\n",
                  f"Fingerprint `{r['fingerprint']}`. {who(r['fingerprint'])}\n",
                  r["description"] + "\n",
                  "**Claimed root cause.** " + r["claimed_root_cause"] + "\n",
                  "**Trace**\n\n" + tr(r) + "\n",
                  "**Evidence**\n\n" + ev(r) + "\n",
                  "**Blockers**\n\n" + "\n".join("- " + b for b in r["blockers"]) + "\n"]
            if vp.get("local"):
                n.append("**Local step.** " + vp["local"] + "\n")
            if vp.get("deployment"):
                n.append("**Owner check.** " + vp["deployment"] + "\n")
    except (KeyError, TypeError) as e:
        raise Fail(f"findings.json: a record lacks or mistypes the field {e}")
    (out / "FINDINGS-DETAIL.md").write_text("\n".join(d), encoding="utf-8")
    (out / "NEEDS-VALIDATION.md").write_text("\n".join(n), encoding="utf-8")
    print(f"wrote {out / 'FINDINGS-DETAIL.md'} and {out / 'NEEDS-VALIDATION.md'}")


# ------------------------------------------------------------------- main

def main(argv):
    args = argv[1:]
    force = False
    pos = []
    for a in args:
        if a == "--force":
            force = True
        elif a.startswith("-"):
            return usage()
        else:
            pos.append(a)
    if len(pos) < 2 or pos[0] not in MODES:
        return usage()
    mode, out = pos[0], Path(pos[1])
    if force and mode != "handback":
        return usage()
    if mode == "handback" and len(pos) < 3:
        return usage()
    if mode != "handback" and len(pos) != 2:
        return usage()
    try:
        if not out.is_dir():
            raise Fail(f"missing input: OUT directory {out}")
        if mode == "handback":
            cmd_handback(out, pos[2:], force)
        elif mode == "findings":
            cmd_findings(out)
        else:
            cmd_derive(out)
    except Fail as e:
        print(f"security-audit-finish: {e}", file=sys.stderr)
        return 1
    return 0


def usage():
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
