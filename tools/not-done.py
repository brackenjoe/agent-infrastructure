#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
"""Collect every "Not done" section from the tracked READMEs under work/.

Read-only. One source of truth stays in each part's README; this only
prints them together.

  tools/not-done.py              every section, under its README's path
  tools/not-done.py --count      items per part, most first, and a total
  tools/not-done.py --untagged   only items naming no trigger or owner
  tools/not-done.py --stale      only items that read as already done
  tools/not-done.py PATH...      limit to READMEs under these paths
  --owner NAME                   a person's name that marks an item as owned
                                 (repeatable; case-insensitive)

collect() is a library entry point for other tools (the maintainer tag needs
a name passed in).

An item is a bullet at column 0 with its indented continuation lines.
"Untagged" is a word check: no trigger or owner word (trigger, owner,
when, until, once, after, next, blocked, wait, need, or an --owner
name), no leading agent name, and no owner line above it ("**Left to
Sam:**" with --owner Sam, or a line naming an agent). A heuristic for the CLAUDE.md rule that each open item carries its
trigger or owner: it finds candidates, a person decides.
"Stale" is a marker check for the other half of that rule (a done line
moves to the part's CHANGELOG.md the day it is done): struck-through
text, "(done", or a done word (done, fixed, deployed, merged, closed,
answered, dropped, deleted) within a few words of a date. Candidates
again; tools/check-repo.sh warns on the count. --stale exits 1 when it
finds any.
Exit 0, or 2 on usage or outside a git checkout.
"""
import argparse
import re
import subprocess
import sys
import textwrap
from pathlib import Path

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
NOT_DONE = re.compile(r"^not done\b", re.I)
BULLET = re.compile(r"^[-*+]\s|^\d+[.)]\s")
# Words that name a trigger or an owner, and an item that opens with an
# agent's name ("- **tak-sme:** ...", the hand-off form).
TAG = re.compile(r"\b(triggers?|owners?|when|until|once|after|next|blocked"
                 r"|waits?|needs?)\b", re.I)
# A line that records its own closing: it belongs in the CHANGELOG.
STALE = re.compile(
    r"~~|\((done|fixed|closed|answered)\b"
    r"|\b(done|fixed|deployed|merged|closed|answered|dropped|deleted)\b"
    r"(?!\s+lines?\b)[^.;]{0,30}\b20\d\d-\d\d-\d\d"
    r"|\b20\d\d-\d\d-\d\d\b[^.;]{0,12}\b(done|fixed|deployed|merged)\b", re.I)
def maintainer_owns(name):
    """Pattern for a maintainer named as the owner or the trigger, not merely
    as the one who decided: "Owner: Sam", "Trigger: Sam's next bench
    session", "(Sam).", "needs Sam"; "Decided (Sam, 2026-11-09)" does not
    match. None when no name is given, so nothing matches. collect() only."""
    if not name:
        return None
    n = re.escape(name)
    return re.compile(
        rf"\bowners?\b[^.;]{{0,50}}?\b{n}\b|\btriggers?\b[^.;]{{0,50}}?\b{n}\b|\({n}\)"
        r"|\b(?:left to|waiting (?:on|for)|waits? for|needs?|asks?|until|once"
        rf"|after|when|before)\s+{n}\b|\b{n}'s (?:yes|go|ok|word|call|approval)", re.I)


AGENT_LEAD = re.compile(r"^[-*+]\s+\**([a-z][a-z0-9-]+)\b")


def agents(root):
    """Agent names from the agents directory, plus "manager"."""
    d = root / ".claude" / "agents"
    names = {p.stem for p in d.glob("*.md")} if d.is_dir() else set()
    return (names | {"manager"}) - {"claude"}


def words(text):
    return set(re.findall(r"[a-z][a-z0-9-]+", text.lower()))


def tagged(ls, names=frozenset(), owners=frozenset()):
    m = AGENT_LEAD.match(ls[0])
    text = " ".join(ls)
    return bool((m and m.group(1) in names) or TAG.search(text) or words(text) & owners)


def owned_group(line, names):
    """A prose line that names an owner ("**Left to Sam:**") covers the
    bullets under it, until the next prose line."""
    return bool(TAG.search(line) or words(line) & names)


def repo_root():
    here = Path(__file__).resolve().parent
    try:
        out = subprocess.run(["git", "-C", str(here), "rev-parse", "--show-toplevel"],
                             check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("not-done: not in a git checkout", file=sys.stderr)
        sys.exit(2)
    return Path(out.strip())


def readmes(root, limits):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", "work/"],
                         check=True, capture_output=True, text=True).stdout
    paths = sorted(p for p in out.split("\0") if p.rsplit("/", 1)[-1] == "README.md")
    if limits:
        pre = [str(Path(l).resolve().relative_to(root)) if Path(l).exists() else l.rstrip("/")
               for l in limits]
        paths = [p for p in paths if any(p == x or p.startswith(x + "/") for x in pre)]
    return paths


def sections(text):
    """Yield the body lines of each Not done section, fences respected."""
    for _, body in sections_at(text):
        yield body


def sections_at(text, by_newline=False):
    """Yield (index of the body's first line in the file, 0-based, body)."""
    lines = ([l[:-1] if l.endswith("\r") else l for l in text.split("\n")]
             if by_newline else text.splitlines())
    fence = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("```"):
            fence = not fence
        m = None if fence else HEADING.match(line)
        if m and NOT_DONE.match(m.group(2)):
            level = len(m.group(1))
            body, i, inner = [], i + 1, False
            first = i
            while i < len(lines):
                l = lines[i]
                if l.lstrip().startswith("```"):
                    inner = not inner
                h = None if inner else HEADING.match(l)
                if h and len(h.group(1)) <= level:
                    break
                body.append(l)
                i += 1
            while body and not body[-1].strip():
                body.pop()
            while body and not body[0].strip():
                body.pop(0)
                first += 1
            yield first, body
            continue
        i += 1


def items(body):
    """Split a section body into top-level items (bullets) and prose."""
    out, cur = [], None
    for l in body:
        if BULLET.match(l):
            cur = [l]
            out.append(("item", cur))
        elif l.startswith((" ", "\t")) and cur is not None:
            cur.append(l)
        elif not l.strip():
            if cur is not None:
                cur.append(l)
        else:
            cur = None
            out.append(("prose", [l]))
    for _, ls in out:
        while ls and not ls[-1].strip():
            ls.pop()
    return out


def walk(parts, names=frozenset(), owners=frozenset(), maintainer=None):
    """Classify the parts of one section. Yields (kind, lines, flags) with
    flags stale, untagged, maintainer; prose carries only stale. maintainer
    is a name; without one the maintainer flag is never set."""
    pat = maintainer_owns(maintainer)
    mwords = words(maintainer) if maintainer else set()
    group, gmaint = False, False
    for kind, ls in parts:
        stale = bool(STALE.search(" ".join(l.strip() for l in ls)))
        if kind == "prose":
            group = owned_group(ls[0], names | owners)
            gmaint = bool(mwords) and mwords <= words(ls[0])
            yield kind, ls, {"stale": stale, "untagged": False, "maintainer": False}
            continue
        maint = bool(pat and pat.search(" ".join(l.strip() for l in ls))) \
            or (group and gmaint)
        untagged = not group and not tagged(ls, names, owners)
        yield kind, ls, {"stale": stale, "untagged": untagged, "maintainer": maint}


def item_text(ls):
    """The item as written: first-line bullet marker stripped, continuation
    lines dedented."""
    first = re.sub(r"^(?:[-*+]|\d+[.)])\s+", "", ls[0])
    rest = textwrap.dedent("\n".join(ls[1:])).split("\n") if len(ls) > 1 else []
    return "\n".join([first] + [l.rstrip() for l in rest])


def collect(texts, names=frozenset(), owners=frozenset(), maintainer=None):
    """Pure: no git, no file I/O, no printing. texts is [(readme_path, text)].
    Returns one entry per README with a Not done section:
    {"readme": path, "items": [{"text", "tag", "line"}]}. tag is stale, maintainer
    (the item or the owner line above it names the maintainer; only with a
    maintainer name), tagged (any other
    trigger or owner word) or untagged, in that precedence; line is the
    item's first line in the README, 1-based."""
    out = []
    for rel, text in texts:
        found, its = False, []
        for start, body in sections_at(text, True):
            found, ptr = True, 0
            for kind, ls, f in walk(items(body), names, owners, maintainer):
                pos = body.index(ls[0], ptr)
                ptr = pos + len(ls)
                if kind != "item":
                    continue
                tag = ("stale" if f["stale"] else "maintainer" if f["maintainer"]
                       else "untagged" if f["untagged"] else "tagged")
                its.append({"text": item_text(ls), "tag": tag,
                            "line": start + pos + 1})
        if found:
            out.append({"readme": rel, "items": its})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--count", action="store_true", help="items per part, and a total")
    g.add_argument("--untagged", action="store_true", help="items naming no trigger or owner")
    g.add_argument("--stale", action="store_true", help="items that read as already done")
    ap.add_argument("--owner", action="append", default=[], metavar="NAME",
                    help="a person's name that marks an item as owned (repeatable)")
    ap.add_argument("paths", nargs="*", help="limit to READMEs under these paths")
    a = ap.parse_args()

    root = repo_root()
    names = agents(root)
    owners = {o.lower() for o in a.owner}
    counts, shown = [], 0
    for rel in readmes(root, a.paths):
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        for body in sections(text):
            parts = items(body)
            n = sum(1 for k, _ in parts if k == "item")
            counts.append((n, rel))
            if a.count:
                continue
            if a.untagged or a.stale:
                hits = [ls for _, ls, f in walk(parts, names, owners)
                        if f["stale" if a.stale else "untagged"]]
                if not hits:
                    continue
                print(f"== {rel}  ({len(hits)} of {n})")
                for ls in hits:
                    print("\n".join(ls))
                shown += len(hits)
            else:
                print(f"== {rel}  ({n} item{'s' if n != 1 else ''})")
                print("\n".join(body))
                shown += n
            print()

    if a.count:
        for n, rel in sorted(counts, key=lambda c: (-c[0], c[1])):
            print(f"{n:4d}  {rel}")
    total = sum(n for n, _ in counts)
    files = len({r for _, r in counts})
    tail = f"{shown} {'stale' if a.stale else 'untagged'} of " if a.untagged or a.stale else ""
    print(f"-- {tail}{total} items in {files} READMEs", file=sys.stderr if not a.count else sys.stdout)
    return 1 if a.stale and shown else 0


if __name__ == "__main__":
    sys.exit(main())
