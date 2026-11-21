#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
"""Build the agent briefs for a security-audit run.

    python3 -I tools/security-audit-briefs.py OUT ROLE [--skill DIR]
        [--wave N | --final-clean]

ROLE is recon, hunters, verifiers, critic or records. Reads
OUT/run-metadata.json, OUT/architecture.md, OUT/coverage-ledger.json,
OUT/candidates.json and (optionally) OUT/prior-findings.json; writes
OUT/briefs/*.md and prints each brief's path and word count. The skill
directory defaults to tools/security-audit-skill beside this script.

critic: under the quick profile it writes critic-final.md and takes no flag.
Under any other profile exactly one of --wave N (critic-wave-N.md, the
post-wave critic) or --final-clean (critic-final-clean.md, the distinct
final-clean critic) is required.
records: the Phase 5 record verifiers (not under quick, which merges Phase 5
into the candidate verifiers). Reads OUT/findings.json and
OUT/record-verifiers.json (fingerprint -> agent id); one brief per mapped
record, which must be `confirmed` or `needs_validation`.
Optional run-metadata field `sandbox_command`: the one sandbox invocation,
with {TARGET} and {SCRATCH} placeholders, written into the rules of hunters,
verifiers and records when `sandbox_available` is true.
Optional `selftest_commands` (list of strings, {TARGET} filled): the target's own
selftests, named in the harness text in place of the part's selftest.py sentences.
The `_DATA` sentence is kept only when `sandbox_command` contains `_DATA=`. A run
set up with `setup --file` (a target of named files) carries both.

Skill text is copied verbatim and extracted by heading, never by line number:
  "## NAME"   from that line to the next line starting "## ";
  "#### NAME" to the next line starting "#### " or "## Local validation"
              (the fenced blocks inside contain "## " lines);
  "**NAME**"  to the next line starting "**" or "## ".
The blocks come from the skill's own sections ("Rules every brief carries",
"Roles and models", "The run, step by step").

Exit 0 done, 1 missing/invalid input or unknown block reference, 2 usage
(including a flag the role does not take).
Standard library only.
"""

import json
import re
import sys
from pathlib import Path

ROLES = ("recon", "hunters", "verifiers", "critic", "records")
AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
WIN_DEVICES = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {
    f"lpt{i}" for i in range(1, 10)}
USAGE = ("usage: security-audit-briefs.py OUT {recon,hunters,verifiers,critic,records} "
         "[--skill DIR] [--wave N | --final-clean]")
NO_SANDBOX_BLOCKER = "no sandbox on this run; local reproduction not performed"


class Fail(Exception):
    """Exit 1: missing or invalid input, or an unknown block reference."""


class Usage(Exception):
    """Exit 2: a flag the role or profile does not take."""


# ---------------------------------------------------------------- reading

def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as e:
        raise Fail(f"missing input: {path} ({e.strerror})")


def read_json(path):
    text = read_text(path)
    try:
        return json.loads(text)
    except ValueError as e:
        raise Fail(f"invalid JSON in {path}: {e}")


def check_agent_id(value, what):
    if (not isinstance(value, str) or not AGENT_ID.match(value)
            or value in WIN_DEVICES):
        raise Fail(f"{what} is not a canonical agent id: {value!r}")
    return value


def jdump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False)


def fenced(text, lang=""):
    return f"```{lang}\n{text.rstrip()}\n```"


# ------------------------------------------------------------ skill text

class Skill:
    """Heading-based extraction from the vendored skill files."""

    def __init__(self, directory):
        self.dir = Path(directory)
        self._lines = {}

    def lines(self, name):
        if name not in self._lines:
            if "/" in name or not name.endswith(".md"):
                raise Fail(f"bad skill file name: {name}")
            self._lines[name] = read_text(self.dir / name).split("\n")
        return self._lines[name]

    @staticmethod
    def _join(chunk):
        return "\n".join(chunk).strip("\n")

    @staticmethod
    def _norm(heading):
        # drop one trailing parenthetical: "Core discipline (include in ...)"
        return re.sub(r"\s*\([^()]*\)\s*$", "", heading).strip()

    def h2(self, file, name, required=True):
        lines = self.lines(file)
        for i, line in enumerate(lines):
            if line.startswith("## ") and self._norm(line[3:]) == name:
                j = i + 1
                while j < len(lines) and not lines[j].startswith("## "):
                    j += 1
                return self._join(lines[i:j])
        if required:
            raise Fail(f"unknown section: {file} has no '## {name}'")
        return None

    def h4(self, file, name):
        lines = self.lines(file)
        for i, line in enumerate(lines):
            if line.startswith("#### ") and (line[5:] == name
                                             or line[5:].startswith(name + " ")):
                j = i + 1
                while j < len(lines) and not (lines[j].startswith("#### ")
                                              or lines[j].startswith("## Local validation")):
                    j += 1
                return self._join(lines[i:j])
        raise Fail(f"unknown section: {file} has no '#### {name}'")

    def bold(self, file, name, required=True):
        lines = self.lines(file)
        mark = f"**{name}**"
        for i, line in enumerate(lines):
            if line.startswith(mark):
                j = i + 1
                while j < len(lines) and not (lines[j].startswith("**")
                                              or lines[j].startswith("## ")):
                    j += 1
                return self._join(lines[i:j])
        if required:
            raise Fail(f"unknown block: {file} has no '**{name}**'")
        return None

    def ref(self, ref):
        """Resolve 'FILE.md#Name' to (text, sort_rank). Raises naming the ref."""
        if not isinstance(ref, str) or "#" not in ref:
            raise Fail(f"unknown block reference: {ref!r}")
        file, name = ref.split("#", 1)
        try:
            text = self.h2(file, name, required=False)
            if text is None:
                text = self.bold(file, name, required=False)
        except Fail as e:
            raise Fail(f"unknown block reference: {ref} ({e})")
        if text is None:
            raise Fail(f"unknown block reference: {ref}")
        rank = {"Core discipline": 0, "Universal moves": 2, "Validation rules": 3}.get(name, 1)
        return text, rank

    def first_fence(self, file, after_prefix, lang=None, after_contains=None):
        """Inner text of the first fenced block after a line (startswith or contains)."""
        lines = self.lines(file)
        start = None
        for i, line in enumerate(lines):
            if (after_prefix is not None and line.startswith(after_prefix)) or (
                    after_contains is not None and after_contains in line):
                start = i
                break
        if start is None:
            raise Fail(f"unknown section: {file} has no '{after_prefix or after_contains}'")
        for i in range(start + 1, len(lines)):
            m = re.match(r"^```(\w*)\s*$", lines[i])
            if m and (lang is None or m.group(1) == lang):
                for j in range(i + 1, len(lines)):
                    if lines[j].startswith("```"):
                        return "\n".join(lines[i + 1:j])
                raise Fail(f"unterminated fence after '{after_prefix or after_contains}' in {file}")
        raise Fail(f"no fenced block after '{after_prefix or after_contains}' in {file}")

    def lines_between(self, file, start_prefix, stop_prefix):
        lines = self.lines(file)
        for i, line in enumerate(lines):
            if line.startswith(start_prefix):
                for j in range(i + 1, len(lines)):
                    if lines[j].startswith(stop_prefix):
                        return self._join(lines[i:j])
                raise Fail(f"{file}: no '{stop_prefix}' after '{start_prefix}'")
        raise Fail(f"unknown section: {file} has no '{start_prefix}'")


# -------------------------------------------------------------- run rules

PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def sandbox_command_text(meta, scratch):
    """The fenced sandbox command with {TARGET}/{SCRATCH} filled, or "" when the
    metadata declares none. Any other {NAME} placeholder is a Fail."""
    cmd = meta.get("sandbox_command")
    if not isinstance(cmd, str) or not cmd.strip():
        return ""
    for name in PLACEHOLDER.findall(cmd):
        if name not in ("TARGET", "SCRATCH"):
            raise Fail(f"run-metadata.json: sandbox_command has the placeholder {{{name}}}; "
                       "only {TARGET} and {SCRATCH} are filled")
    cmd = cmd.replace("{TARGET}", meta["target"])
    text = (" Run target code only with exactly this command, editing only the part "
            "after `--`:\n\n")
    if scratch is not None:
        return text + fenced(cmd.replace("{SCRATCH}", str(scratch)), "sh")
    return text + fenced(cmd, "sh") + "\n\nwhere {SCRATCH} is your own scratch path."


def harness_text(meta):
    """Execution-route sentences for roles that pass a scratch (hunters, verifiers)."""
    target = meta["target"]
    cmds = meta.get("selftest_commands")
    has_data = "_DATA=" in (meta.get("sandbox_command") or "")
    head = (
        "Your scratch directory is writable through the shell (a heredoc or redirect into "
        "it); the Write and Edit tools are not. Write a harness there as harness.py; the "
        "part after `--` in the command runs it. ")
    tail = (
        "A candidate's "
        "validation_plan.local is a bounded local reproduction: attempt it before deciding. "
        "Keep coordinate values out of harness literals and of anything you write: build "
        "test points by offsetting values read from the target's own fixtures, and print "
        "none.")
    if isinstance(cmds, list) and cmds:
        listed = ", ".join(f"`{c.replace('{TARGET}', target)}`" for c in cmds)
        mid = f"The target's own selftests run the same way, with each of {listed} after `--`. "
        if has_data:
            mid += ("The data directory the command's `--env ..._DATA=` names does not exist "
                    "yet: a harness starts with `os.makedirs(os.environ[NAME], exist_ok=True)`, "
                    "NAME being that variable. ")
        return head + mid + tail
    return (
        head
        + "The part's own selftest runs the same way "
        f"with `python {target}/selftest.py` after `--`. The data directory the command's "
        "`--env ..._DATA=` names does not exist yet: a harness starts with "
        "`os.makedirs(os.environ[NAME], exist_ok=True)`, and the selftest runs as "
        f"`sh -c 'mkdir -p \"${{NAME}}\" && exec python {target}/selftest.py'` after `--`, "
        "NAME being that variable. " + tail)


VENV_RULE = ("- The venv in the sandbox command is mounted for the sandbox only: never list, "
             "grep or read it.")
VENV_RULE_SANDBOX = ("- The venv in the sandbox command is mounted for the sandbox only: never list, "
                     "grep or read it. To learn how a dependency behaves, run a harness that "
                     "exercises it inside the sandbox. Write only under your own scratch/ with "
                     "absolute paths.")


def render_rules(meta, scratch=None, harness=False):
    target = meta["target"]
    excluded = meta.get("excluded_paths") or []
    ex = ", ".join(f"`{p}`" for p in excluded) if excluded else "none listed"
    if meta["sandbox_available"]:
        sandbox = (f"- A sandbox is available: {meta.get('sandbox_note') or 'see run-metadata'}; "
                   "run target code only inside it, as the method says. Bash is otherwise for "
                   "ls, find, grep, rg, cat, head, tail, sed -n, wc, diff."
                   + sandbox_command_text(meta, scratch)
                   + ("\n\n" + harness_text(meta) if harness else ""))
    else:
        sandbox = (
            "- No target execution on this run: `sandbox_available` is false. No python, node, "
            "pip, make, uvicorn, selftests or harnesses; Bash is for ls, find, grep, rg, cat, "
            "head, tail, sed -n, wc, diff. Every check is `method: \"source\"`, `artifact: null`, "
            "and no candidate may be proposed `confirmed`; a source-complete defect is "
            f"`needs_validation` with the blocker \"{NO_SANDBOX_BLOCKER}\" and a "
            "`validation_plan.local` naming the exact selftest.")
    out = [
        "## Run rules (binding, read first)",
        "",
        f"- Read only under TARGET (`{target}`), plus this brief. Never open or list a path "
        f"outside it. Never read the excluded paths: {ex}.",
        VENV_RULE_SANDBOX if harness and meta["sandbox_available"] else VENV_RULE,
        sandbox,
        "- No network: no WebFetch, WebSearch, curl, wget, git. No git history. No Agent, "
        "Edit, Write, NotebookEdit. The only writable path is the agent's own `scratch/`, "
        "and nothing there is evidence.",
        "- Dependency CVEs and git history are out of scope; the bullets about them in the "
        "attack-class text are void.",
        "- Never quote a coordinate value; name the fields as `lat`/`lon` in backticks; never "
        "write \"Lat:\" or \"Lon:\" in prose.",
        "- Paths repository-relative to TARGET, never absolute. Re-read every cited line; do "
        "not trust another agent's numbers.",
    ]
    methods = meta.get("excluded_methods") or []
    if methods:
        out.append("- Excluded methods, not to be used on this run: "
                   + ", ".join(f"`{m}`" for m in methods) + ".")
    out.append(f"- All paths in your report are repository-relative to TARGET (`{target}`).")
    return "\n".join(out)


HUNTER_CAP = ("Candidate cap: at most three candidates, consolidate by root cause (a fourth "
              "only if it is clearly a separate root cause with cross-principal impact). "
              "Prefer `covered` plus a hardening note over a speculative candidate. "
              "Verifiers are the scarce reserve.")


# --------------------------------------------------------------- loading

def load_meta(out):
    meta = read_json(out / "run-metadata.json")
    if not isinstance(meta, dict):
        raise Fail("run-metadata.json is not an object")
    if not isinstance(meta.get("target"), str) or not meta["target"]:
        raise Fail("run-metadata.json: missing 'target'")
    if not isinstance(meta.get("sandbox_available"), bool):
        raise Fail("run-metadata.json: 'sandbox_available' must be true or false")
    st = meta.get("selftest_commands")
    if st is not None and not (isinstance(st, list) and all(isinstance(c, str) for c in st)):
        raise Fail("run-metadata.json: 'selftest_commands' must be a list of strings")
    return meta


def load_ledger(out):
    ledger = read_json(out / "coverage-ledger.json")
    if not isinstance(ledger, list) or not all(
            isinstance(u, dict) and isinstance(u.get("coverage_id"), str) for u in ledger):
        raise Fail("coverage-ledger.json is not an array of units with coverage_id")
    return ledger


def load_candidates(out):
    cands = read_json(out / "candidates.json")
    if not isinstance(cands, dict):
        raise Fail("candidates.json is not an object keyed by fingerprint")
    return cands


def schema_branches(skill, indexes):
    schema = read_json(skill.dir / "report-schema.json")
    try:
        one_of = schema["items"]["oneOf"]
        return [one_of[i] for i in indexes]
    except (KeyError, IndexError, TypeError):
        raise Fail("report-schema.json: items.oneOf is not as expected")


def promotion_text(meta):
    """Empty allowlist and zero byte limits unless run-metadata.json declares them
    (optional 'promotion_allowlist' list and 'promotion_byte_limits' object)."""
    files = meta.get("promotion_allowlist") or []
    limits = meta.get("promotion_byte_limits") or {}
    if not files:
        return "empty, byte limits 0."
    return ("scratch-relative files " + ", ".join(f"`{f}`" for f in files)
            + f"; per-file byte limit {limits.get('per_file', 0)}, "
            f"cumulative byte limit {limits.get('cumulative', 0)}.")


def scratch_dirs(out, agent_id):
    root = out / "agents" / agent_id
    (root / "scratch").mkdir(parents=True, exist_ok=True)
    (root / "artifacts").mkdir(parents=True, exist_ok=True)
    return root / "scratch"


def emit(out, name, parts, written):
    briefs = out / "briefs"
    briefs.mkdir(parents=True, exist_ok=True)
    path = briefs / name
    text = "\n\n".join(p.strip("\n") for p in parts if p) + "\n"
    path.write_text(text, encoding="utf-8")
    written.append((path, len(text.split())))


# ----------------------------------------------------------------- recon

def role_recon(out, skill):
    meta = load_meta(out)
    rules = render_rules(meta)
    written = []
    for letter in "abcd":
        prompt = skill.first_fence("RECONNAISSANCE.md", f"**Agent 1{letter}:", "text")
        prompt = prompt.replace("<target>", meta["target"])
        parts = [rules, "## Task", prompt]
        if letter == "d" and not meta["sandbox_available"]:
            parts.append("Items 6 and 7 are answered \"not available on this run\" without "
                         "looking outside TARGET.")
        parts.append("Return only source facts with repository-relative file:line references; "
                     "keep the report under 1,500 words; write no files.")
        emit(out, f"recon-1{letter}.md", parts, written)
    return written


# --------------------------------------------------------------- hunters

def group_blocks(skill, refs):
    """Verbatim blocks, each once, grouped by file: ATTACK-CLASSES.md first, then the
    companions by name; within a file Core discipline, class blocks, Universal moves,
    Validation rules."""
    seen = []
    for r in refs:
        if r not in seen:
            seen.append(r)
    resolved = {}
    for r in seen:
        resolved[r] = skill.ref(r)
    files = sorted({r.split("#", 1)[0] for r in seen},
                   key=lambda f: (f != "ATTACK-CLASSES.md", f))
    parts = []
    for f in files:
        title = ("Ordinary attack-class blocks (ATTACK-CLASSES.md)" if f == "ATTACK-CLASSES.md"
                 else f"Companion blocks ({f})")
        parts.append(f"### {title}")
        in_file = [r for r in seen if r.split("#", 1)[0] == f]
        in_file.sort(key=lambda r: resolved[r][1])  # stable: ledger order within a rank
        for r in in_file:
            parts.append(f"#### Block {r}")
            parts.append(resolved[r][0])
    return parts


def role_hunters(out, skill):
    meta = load_meta(out)
    arch = read_text(out / "architecture.md").strip("\n")
    ledger = load_ledger(out)
    owned = {}
    for u in ledger:
        if u.get("status") == "in_progress":
            aid = u.get("agent_id")
            if not aid:
                raise Fail(f"unit {u['coverage_id']} is in_progress with no agent_id")
            owned.setdefault(check_agent_id(aid, f"agent_id of {u['coverage_id']}"), []).append(u)
    if not owned:
        raise Fail("coverage-ledger.json has no in_progress unit with an agent_id")

    method = skill.h4("HUNTING.md", "Core hunting method")
    promo = skill.h4("HUNTING.md", "Promotion procedure")
    validation = skill.h4("HUNTING.md", "Core validation rules")
    structured = skill.h2("HUNTING.md", "Structured hunter result")
    conf, nv = schema_branches(skill, (0, 1))

    carried = meta.get("carried_exclusions") or []
    written = []
    for aid in sorted(owned):
        units = sorted(owned[aid], key=lambda u: u["coverage_id"])
        scratch = scratch_dirs(out, aid)
        rules = render_rules(meta, scratch, harness=True)
        own_ids = {u["coverage_id"] for u in units}

        assigned = [{
            "coverage_id": u["coverage_id"],
            "surface": u.get("surface"),
            "boundary": u.get("boundary"),
            "subsystem": u.get("subsystem"),
            "attack_class": u.get("attack_class"),
            "starting_paths": u.get("starting_paths", []),
            "ordinary_attack_class_block": u.get("ordinary_attack_class_block"),
            "selected_companion_blocks": u.get("selected_companion_blocks") or [],
            "excluded_blocks": u.get("excluded_blocks") or [],
            "priority_note": u.get("priority_note"),
        } for u in units]

        refs = []
        excluded = []  # (block, reason) distinct
        for a in assigned:
            if a["ordinary_attack_class_block"]:
                refs.append(a["ordinary_attack_class_block"])
            refs.extend(a["selected_companion_blocks"])
            for e in a["excluded_blocks"]:
                pair = (e.get("block"), e.get("reason"))
                if pair not in excluded:
                    excluded.append(pair)
        block_parts = group_blocks(skill, refs)

        if excluded:
            ex_lines = [f"- `{b}`: {r}" for b, r in excluded]
        else:
            ex_lines = ["- none recorded on the assigned units"]
        ex_lines.append("- Every other ATTACK-CLASSES.md block is owned by a peer unit or deferred.")

        peers = [u["coverage_id"] for u in ledger
                 if u.get("status") in ("in_progress", "planned")
                 and u["coverage_id"] not in own_ids]
        carried_txt = jdump(carried) if carried else "none"
        peers_txt = jdump(peers) if peers else "none"

        preamble = (
            f"You are hunter `{aid}`, and your goal is to find source-grounded security "
            "invariant failures in the coverage units assigned to you below. You must return "
            "exactly one JSON object matching the structured-result contract at the end of "
            "this prompt, with no surrounding prose.")

        parts = [
            "# Hunter brief: " + aid,
            preamble,
            rules,
            "## 2. Architecture\n\n" + arch,
            "## 3. Assigned units\n\n" + fenced(jdump(assigned), "json"),
            f"Agent id: `{aid}`\n\nScratch path: `{scratch}/` (the only writable path; "
            "nothing there is evidence).",
            "Promotion allowlist: " + promotion_text(meta),
            "## 4. Selected blocks (verbatim)",
        ] + block_parts + [
            "## 5. Excluded blocks\n\n" + "\n".join(ex_lines),
            "## 6. Core hunting method and promotion procedure\n\n" + method + "\n\n" + promo,
            "## 7. Core validation rules\n\n" + validation,
            "## 8. Carried exclusions and peer-owned units\n\n"
            "Carried prior exclusions:"
            + ("\n\n" + fenced(carried_txt, "json") if carried else " none")
            + "\n\nPeer-owned coverage ids (do not duplicate):"
            + ("\n\n" + fenced(peers_txt, "json") if peers else " none"),
            "## 9. Result contract\n\n" + HUNTER_CAP,
            structured,
            "A candidate record is shaped like the `confirmed` branch below (when "
            "`proposed_verdict` is `confirmed`) or the `needs_validation` branch (when it is "
            "`needs_validation`), with `proposed_verdict` in place of `verdict`.",
            "### `confirmed` branch of report-schema.json\n\n" + fenced(jdump(conf), "json"),
            "### `needs_validation` branch of report-schema.json\n\n" + fenced(jdump(nv), "json"),
        ]
        emit(out, f"{aid}.md", parts, written)
    return written


# ------------------------------------------------------------- verifiers

def role_verifiers(out, skill):
    meta = load_meta(out)
    arch = read_text(out / "architecture.md").strip("\n")
    ledger = load_ledger(out)
    cands = load_candidates(out)
    prior_path = out / "prior-findings.json"
    prior = read_json(prior_path) if prior_path.exists() else []
    if not isinstance(prior, list):
        raise Fail("prior-findings.json is not an array")
    by_id = {u["coverage_id"]: u for u in ledger}
    quick = meta.get("profile") == "quick"
    sandbox = meta["sandbox_available"]

    verifier_prompt = skill.first_fence("VALIDATION-AND-REPORTING.md", "#### Candidate-verifier prompt", "text")
    promo = skill.first_fence("VALIDATION-AND-REPORTING.md", None, "text",
                              after_contains="Copy this promotion procedure verbatim")
    phase5 = skill.lines_between("VALIDATION-AND-REPORTING.md",
                                 "For `confirmed`, require it to check:",
                                 "Each verifier returns exactly one JSON object")
    ordinary_rules = "\n".join(skill.lines("ATTACK-CLASSES.md")[:5]).strip("\n")
    branches = schema_branches(skill, (0, 1, 2))

    seen_ids = {}
    written = []
    for fp in sorted(cands):
        rec = cands[fp]
        if not isinstance(rec, dict):
            raise Fail(f"candidates.json[{fp}] is not an object")
        vid = rec.get("verifier")
        if not vid:
            continue
        check_agent_id(vid, f"verifier of candidate {fp}")
        if vid in seen_ids:
            raise Fail(f"verifier id {vid} is assigned to both {seen_ids[vid]} and {fp}")
        seen_ids[vid] = fp
        linked = rec.get("linked_units") or []
        units = []
        for cid in linked:
            if cid not in by_id:
                raise Fail(f"candidate {fp} links unit {cid}, which is not in coverage-ledger.json")
            units.append(by_id[cid])
        scratch = scratch_dirs(out, vid)
        rules = render_rules(meta, scratch, harness=True)

        checks = {u["coverage_id"]: u.get("local_checks", []) for u in units}
        same = [p for p in prior if isinstance(p, dict) and p.get("fingerprint") == fp]

        companions = []
        for u in units:
            ref = (u.get("canonical_refs") or {}).get("attack_class", "")
            f = ref.split("#", 1)[0] if "#" in ref else ""
            if f and f != "ATTACK-CLASSES.md" and f not in companions:
                companions.append(f)
        comp_parts = []
        for f in companions:
            comp_parts.append(f"### {f}")
            comp_parts.append(skill.ref(f"{f}#Core discipline")[0])
            comp_parts.append(skill.ref(f"{f}#Validation rules")[0])

        preamble = (
            f"You are verifier `{vid}`, a fresh verifier: you did not write the candidate "
            f"below (hunter `{rec.get('hunter', 'unknown')}` did) and you must try to refute "
            "it from repository source"
            + (" and bounded local evidence" if sandbox else "") + ". "
            + ("This run is under the quick profile, so you also perform the Phase 5 record "
               "checks listed below on your own record. " if quick else "")
            + "Return exactly one JSON object, `{\"decision\": ..., \"record\": {...}}`, and "
            "no surrounding prose.")
        if sandbox:
            decision_rule = ("Decision is `confirmed`, `needs_validation` or `rejected`; "
                             "`confirmed` needs a promoted local artifact and a bounded "
                             "observed result.")
        else:
            decision_rule = (
                "Decision is `needs_validation` or `rejected`; `confirmed` is unreachable on "
                "this run. Keep the blocker '" + NO_SANDBOX_BLOCKER + "'.")

        parts = [
            "# Verifier brief: " + vid,
            preamble,
            rules,
            decision_rule,
            "## Candidate-verifier prompt\n\n" + verifier_prompt,
            "## Promotion procedure\n\n" + promo,
            f"Agent id: `{vid}`\n\nScratch path: `{scratch}/`. Promotion allowlist: "
            + promotion_text(meta),
        ]
        if quick:
            parts.append("## Phase 5 record checks (quick profile)\n\n" + phase5)
        parts += [
            f"## Candidate\n\nFingerprint: `{fp}`\n\n" + fenced(jdump(rec.get("candidate")), "json"),
            "## Linked units' local_checks\n\n" + fenced(jdump(checks), "json"),
            "## Prior records with this fingerprint\n\n"
            + (fenced(jdump(same), "json") if same else "none"),
            "## Architecture\n\n" + arch,
            "## Validation rules\n\n### Ordinary (first five lines of ATTACK-CLASSES.md)\n\n"
            + ordinary_rules,
        ] + comp_parts + [
            "## Schema branches (report-schema.json)",
            "### `confirmed`\n\n" + fenced(jdump(branches[0]), "json"),
            "### `needs_validation`\n\n" + fenced(jdump(branches[1]), "json"),
            "### `rejected`\n\n" + fenced(jdump(branches[2]), "json"),
        ]
        emit(out, f"{vid}.md", parts, written)
    if not written:
        raise Fail("candidates.json has no candidate with a verifier id")
    return written


# ---------------------------------------------------------------- critic

def role_critic(out, skill, opts):
    meta = load_meta(out)
    quick = meta.get("profile") == "quick"
    wave = opts.get("wave")
    final_clean = opts.get("final_clean", False)
    if quick and (wave is not None or final_clean):
        raise Usage("critic: --wave and --final-clean are not used under the quick profile")
    if not quick and (wave is None) == (not final_clean):
        raise Usage("critic: exactly one of --wave N or --final-clean is required "
                    "under this profile")
    arch = read_text(out / "architecture.md").strip("\n")
    ledger = load_ledger(out)
    cands = load_candidates(out)
    rules = render_rules(meta)
    shape = skill.first_fence("HUNTING.md", "## Coverage-critic waves", "json")
    prior_runs = meta.get("prior_runs") or []
    if prior_runs:
        gap = ("Prior-ledger gap summary: prior runs recorded in run-metadata.json:\n"
               + "\n".join(f"- {p if isinstance(p, str) else json.dumps(p)}" for p in prior_runs))
    else:
        gap = "Prior-ledger gap summary: none"
    fps = []
    for fp in sorted(cands):
        pv = (cands[fp].get("candidate") or {}).get("proposed_verdict") if isinstance(
            cands[fp], dict) else None
        fps.append(f"- `{fp}`" + (f" (proposed {pv})" if pv else ""))
    if quick:
        name = "critic-final"
        who = "You are the final coverage critic."
        note = ("Profile note: this is the quick profile. Nothing you propose will be hunted "
                "this run; accepted `missing_units` are recorded as `deferred` with reason "
                "`quick_profile_final_critic`.")
    else:
        profile = meta.get("profile") or "standard"
        if final_clean:
            name = "critic-final-clean"
            who = ("You are the distinct final-clean coverage critic; a post-wave critic "
                   "already returned no accepted work.")
            note = (f"Profile note: this is the {profile} profile. Coverage is complete only "
                    "if you also return no accepted `missing_units` and no `reassign_ids`; "
                    "any work you find is queued for another wave.")
        else:
            name = f"critic-wave-{wave}"
            who = f"You are the post-wave coverage critic for hunter wave {wave}."
            note = (f"Profile note: this is the {profile} profile. Accepted `missing_units` "
                    "and legitimate `reassign_ids` enter the ranked queue for a further hunter "
                    "wave if the budget can fund it; set `stop` to true only when you accept "
                    "no `missing_units` and no `reassign_ids`.")
    preamble = (
        who + " You review coverage, not findings: you read "
        "source, write nothing, and return exactly one JSON object of the shape below with "
        "no surrounding prose.")
    parts = [
        f"# Critic brief: {name}",
        preamble,
        rules,
        "You have no scratch path; write no files.",
        note,
        "## Current candidate fingerprints\n\n" + ("\n".join(fps) if fps else "none"),
        gap,
        "## Architecture\n\n" + arch,
        "## Coverage ledger\n\n" + fenced(jdump(ledger), "json"),
        "## Required JSON shape\n\n" + fenced(shape, "json"),
        "You may add one optional top-level `notes` array of strings (for example, "
        "fingerprint-placement notes where a unit's own checks support them); every other "
        "key stays as shown.",
    ]
    written = []
    emit(out, f"{name}.md", parts, written)
    return written


# --------------------------------------------------------------- records

def role_records(out, skill, opts):
    meta = load_meta(out)
    if meta.get("profile") == "quick":
        raise Fail("records: the quick profile merges Phase 5 into the candidate verifiers")
    arch = read_text(out / "architecture.md").strip("\n")
    ledger = load_ledger(out)
    findings = read_json(out / "findings.json")
    if not isinstance(findings, list) or not all(isinstance(r, dict) for r in findings):
        raise Fail("findings.json is not an array of records")
    mapping = read_json(out / "record-verifiers.json")
    if not isinstance(mapping, dict):
        raise Fail("record-verifiers.json is not an object of fingerprint -> agent id")
    by_fp = {}
    for r in findings:
        by_fp.setdefault(r.get("fingerprint"), r)

    checks_text = skill.lines_between("VALIDATION-AND-REPORTING.md",
                                      "For `confirmed`, require it to check:",
                                      "Each verifier returns exactly one JSON object")
    contract = skill.lines_between("VALIDATION-AND-REPORTING.md",
                                   "Each verifier returns exactly one JSON object",
                                   "Do not apply a Phase 5 replacement")
    branches = schema_branches(skill, (0, 1, 2))
    sandbox = meta["sandbox_available"]

    seen_ids = {}
    written = []
    for fp in sorted(mapping):
        aid = check_agent_id(mapping[fp], f"record verifier of {fp}")
        if aid in seen_ids:
            raise Fail(f"record verifier id {aid} is assigned to both {seen_ids[aid]} and {fp}")
        seen_ids[aid] = fp
        rec = by_fp.get(fp)
        if rec is None:
            raise Fail(f"record-verifiers.json maps {fp}, which is not in findings.json")
        verdict = rec.get("verdict")
        if verdict not in ("confirmed", "needs_validation"):
            raise Fail(f"record {fp} has verdict {verdict!r}; only confirmed and "
                       "needs_validation records get a Phase 5 verifier")
        scratch = scratch_dirs(out, aid)
        rules = (render_rules(meta, scratch)
                 + "\n- You may also read, read-only, the files under "
                 f"`{out}/agents/*/artifacts/` that this record's evidence cites; nothing "
                 "else outside TARGET.")
        checks = {u["coverage_id"]: u.get("local_checks", []) for u in ledger
                  if fp in (u.get("result_fingerprints") or [])}
        preamble = (
            f"You are record verifier `{aid}`, a fresh Phase 5 verifier: you did not hunt this "
            "unit, perform its Phase 3 validation, or propose any replacement of it. You check "
            "the structured record below against repository source"
            + (" and bounded local evidence" if sandbox else "")
            + ", not the hunter's write-up. Return exactly one JSON object and no surrounding "
            "prose.")
        parts = [
            "# Record-verifier brief: " + aid,
            preamble,
            rules,
            "## Phase 5 record checks\n\n" + checks_text,
            "## Return contract\n\n" + contract,
            f"Agent id: `{aid}`\n\nScratch path: `{scratch}/`. Promotion allowlist: "
            + promotion_text(meta),
            f"## Record\n\nFingerprint: `{fp}`\n\n" + fenced(jdump(rec), "json"),
            "## Linked units' local_checks\n\n" + fenced(jdump(checks), "json"),
            "## Architecture\n\n" + arch,
            "## Schema branches (report-schema.json)",
            "### `confirmed`\n\n" + fenced(jdump(branches[0]), "json"),
            "### `needs_validation`\n\n" + fenced(jdump(branches[1]), "json"),
            "### `rejected`\n\n" + fenced(jdump(branches[2]), "json"),
        ]
        emit(out, f"{aid}.md", parts, written)
    if not written:
        raise Fail("record-verifiers.json maps no record")
    return written


# ------------------------------------------------------------------ main

def main(argv):
    args = argv[1:]
    skill_dir = Path(__file__).resolve().parent / "security-audit-skill"
    pos = []
    opts = {}
    i = 0

    def usage():
        print(USAGE, file=sys.stderr)
        return 2

    while i < len(args):
        a = args[i]
        if a == "--skill":
            if i + 1 >= len(args):
                return usage()
            skill_dir = Path(args[i + 1])
            i += 2
        elif a.startswith("--skill="):
            skill_dir = Path(a.split("=", 1)[1])
            i += 1
        elif a == "--wave" or a.startswith("--wave="):
            if a == "--wave":
                if i + 1 >= len(args):
                    return usage()
                val = args[i + 1]
                i += 2
            else:
                val = a.split("=", 1)[1]
                i += 1
            if "wave" in opts or not re.fullmatch(r"[0-9]+", val) or int(val) < 1:
                return usage()
            opts["wave"] = int(val)
        elif a == "--final-clean":
            if opts.get("final_clean"):
                return usage()
            opts["final_clean"] = True
            i += 1
        elif a.startswith("-"):
            return usage()
        else:
            pos.append(a)
            i += 1
    if len(pos) != 2 or pos[1] not in ROLES:
        return usage()
    if opts and pos[1] != "critic":
        return usage()
    out = Path(pos[0]).resolve()
    role = pos[1]
    try:
        if not out.is_dir():
            raise Fail(f"missing input: OUT directory {out}")
        skill = Skill(skill_dir)
        roles = {"recon": role_recon, "hunters": role_hunters,
                 "verifiers": role_verifiers, "critic": role_critic,
                 "records": role_records}
        if role in ("critic", "records"):
            written = roles[role](out, skill, opts)
        else:
            written = roles[role](out, skill)
    except Usage as e:
        print(f"security-audit-briefs: {e}\n{USAGE}", file=sys.stderr)
        return 2
    except Fail as e:
        print(f"security-audit-briefs: {e}", file=sys.stderr)
        return 1
    for path, words in written:
        print(f"{path}  {words} words")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
