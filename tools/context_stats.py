#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
"""Context use per Claude Code transcript, aggregates only.

    python3 -I context_stats.py [PROJECT] [--exclude SESSION_PREFIX ...]

PROJECT is a directory of transcripts, or the name of one under
~/.claude/projects (the directory name Claude Code derives from the working
directory, such as -home-user-myproject). With no argument the only project
under ~/.claude/projects is used; if there are several, the names are listed
and the run stops, so the project is always chosen on purpose. Reads every
top-level session transcript and every subagent transcript under it and
prints one row per transcript with at least one assistant turn carrying
usage. Prints no prompt, tool or code content.

Rules:
  context of a turn  input + cache_creation + cache_read tokens of the
                     largest usage.iterations entry of type "message";
                     "advisor_message" entries are a different model's
                     context and are left out. The top-level usage on a
                     multi-iteration turn is the SUM of its iterations, so
                     using it would double-count.
  first              context of the first turn: the fixed overhead plus the
                     first prompt and its attachments
  peak               max context over the transcript
  work               peak - first
  compactions        records with isCompactSummary, or system records of
                     subtype compact_boundary
  tokens             as reported by the API, not converted between models
"""
import glob
import json
import os
import statistics
import sys


def usage_ctx(u):
    def s(x):
        return (x.get("input_tokens", 0) + x.get("cache_creation_input_tokens", 0)
                + x.get("cache_read_input_tokens", 0))
    its = [i for i in (u.get("iterations") or []) if i.get("type") == "message"]
    return max(map(s, its)) if its else s(u)


def scan(path):
    ctx, out, models, comp, ts = [], 0, set(), 0, []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("timestamp"):
                ts.append(d["timestamp"])
            if d.get("isCompactSummary") or (
                    d.get("type") == "system" and d.get("subtype") == "compact_boundary"):
                comp += 1
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            u = msg.get("usage")
            if not u:
                continue
            c = usage_ctx(u)
            if c:
                ctx.append(c)
                out += u.get("output_tokens", 0)
                models.add(msg.get("model"))
    return ctx, out, models, comp, ts


def main(argv):
    excl = []
    args = []
    usage = "usage: context_stats.py [PROJECT] [--exclude SESSION_PREFIX ...]"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--exclude":
            if i + 1 >= len(argv) or not argv[i + 1]:
                print(f"--exclude needs a non-empty session prefix\n{usage}", file=sys.stderr)
                sys.exit(2)
            excl.append(argv[i + 1])
            i += 2
        else:
            args.append(a)
            i += 1
    if len(args) > 1:
        print(usage, file=sys.stderr)
        sys.exit(2)
    default_base = os.path.expanduser("~/.claude/projects")
    base = default_base
    if args:
        root = args[0]
        if "/" not in root and not root.startswith("."):
            root = os.path.join(base, root)
    else:
        names = sorted(d for d in os.listdir(base)
                       if os.path.isdir(os.path.join(base, d))) if os.path.isdir(base) else []
        if len(names) != 1:
            sys.exit(f"give a PROJECT; {len(names)} under {base}:\n  " + "\n  ".join(names))
        root = os.path.join(base, names[0])
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")
    files = glob.glob(os.path.join(root, "*.jsonl")) + glob.glob(
        os.path.join(root, "*", "subagents", "**", "agent-*.jsonl"), recursive=True)
    rows, lo, hi = [], None, None
    for f in sorted(files):
        rel = os.path.relpath(f, root)
        sess = rel.split(os.sep)[0][:8]
        if any(sess.startswith(e[:8]) for e in excl):
            continue
        sub = os.sep + "subagents" + os.sep in f
        kind = "main"
        if sub:
            meta = f[:-len(".jsonl")] + ".meta.json"
            try:
                kind = json.load(open(meta)).get("agentType", "subagent")
            except (OSError, ValueError):
                kind = "subagent"
        ctx, out, models, comp, ts = scan(f)
        if not ctx:
            continue
        if ts:
            lo = min(lo or ts[0], min(ts))
            hi = max(hi or ts[0], max(ts))
        rows.append((kind, sess, ",".join(sorted(m for m in models if m)), len(ctx),
                     ctx[0], max(ctx), max(ctx) - ctx[0], out, comp))
    nroot = os.path.normpath(root)
    src = os.path.basename(nroot)
    if os.path.dirname(nroot) != os.path.normpath(default_base):
        src = os.path.basename(os.path.dirname(nroot)) + "/" + src
    print(f"source {src}  range {lo} .. {hi}  transcripts {len(rows)}")
    print("kind\tsession\tmodel\tturns\tfirst\tpeak\twork\toutput\tcompactions")
    for r in sorted(rows, key=lambda r: (r[0] != "main", r[0], -r[5])):
        print("\t".join(str(x) for x in r))
    for label, sel in (("main", lambda r: r[0] == "main"),
                       ("subagent", lambda r: r[0] != "main")):
        g = [r for r in rows if sel(r)]
        if g:
            print(f"{label}: n={len(g)} first {min(r[4] for r in g)}-{max(r[4] for r in g)} "
                  f"peak median {statistics.median(r[5] for r in g):.0f} max {max(r[5] for r in g)} "
                  f"compactions {sum(r[8] for r in g)}")


if __name__ == "__main__":
    main(sys.argv[1:])
