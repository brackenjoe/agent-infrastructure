#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# Claude Code PreToolUse hook (matcher Bash): refuses Bash commands that write
# to the agent files, .claude/agents. Any other command that names them passes
# with no decision. An earlier version asked on every mention (dropped by the
# maintainer, 2026-11-05): an ask on every mention stalls unattended runs. In
# one session it fired 20 times, none for an agent-file edit, mostly from
# subagents in separate checkouts whose commands merely named an audit's agents/ folder.
#
# Why deny and not ask: bypassPermissions ignores a hook's "ask" (measured by
# a permission check such as check-permissions.sh, published beside it, on
# 2.1.318, 2026-11-04: the hook ran, returned ask for a heredoc write, and the
# write landed). Bypass mode does honour a deny. Nothing needs a Bash write to
# an agent file: real edits go through the Edit tool, whose ask rule the
# maintainer answers.
#
# Why it exists: Claude Code strips an output redirect from the command text
# before matching Bash rules, and checks the redirect target only against Edit
# allow and deny rules, never ask rules. An earlier setup had an ask rule on
# Bash commands naming .claude/agents; the docs check a redirect's target
# against Edit rules only, so a heredoc write (`cat > .claude/agents/x.md
# <<'EOF'`) got past it while `sed -i` on the same file was stopped. This hook
# is what replaced it.
# Wire it as a Bash PreToolUse hook with onFailure: block (needs Claude Code
# 2.1.295 or later) so a hook crash blocks the call.
# Docs: code.claude.com/docs/en/permissions, "Redirections", read 2026-11-04.
#
# This is a string heuristic that catches mistakes. It is not a script that
# writes the file itself, and a command built to hide the path (variables,
# encoding, a path assembled in code) gets past it. Within what it can see it
# leans to deny: a false deny refuses one command and harms nothing, since the
# same change goes through the Edit tool.
#
# The rule (maintainer, 2026-11-05: the first version denied any command that both
# mentioned an agent file and wrote anything anywhere, and refused `rm
# /tmp/x; cat <agent file>`, read-only python -c that named .claude, and
# heredocs that edited settings.json): deny only a write that TARGETS an agent
# file.
#   An agent path is a token or redirect target containing ".claude/agents"
#   (quotes and a leading ./ ignored; ".claude/projects/.../subagents" does not
#   match). Also a relative "agents" or "agents/..." when the same command cds
#   into a path ending ".claude", and, after a cd into .claude/agents itself,
#   any relative path.
#   Deny when:
#     a. an output redirect (not /dev/null, not an fd like 2>&1) targets an
#        agent path;
#     b. a command word among tee, cp, mv, rm, rmdir, touch, install, ln,
#        truncate, dd, chmod, chown, mkdir, patch, rsync (first word, or any
#        word after sudo, env, xargs, nohup, time, command, exec, find -exec)
#        has an agent path among the other words of its pipeline stage; after
#        xargs, an agent path anywhere in the pipeline counts; and find with
#        -delete and an agent path;
#     c. sed or perl in place (-i, --in-place) with an agent path argument;
#     d. git checkout, restore, apply, am, mv, rm, stash or reset: apply, am
#        and stash always (the patch or stash content is unknown); mv and rm
#        with an agent path or a whole-tree argument (. * :/ --all); checkout,
#        restore and reset also with no path-like argument at all (no word
#        containing / . or *), since `git checkout -f` or `git reset --hard`
#        touches the whole tree. So `git checkout main` in a command that
#        mentions agent files is denied; `git checkout feature/x` is not;
#     e. an interpreter given code (python, perl, ruby, node with -c, -e, -p,
#        --eval, --print; sh, bash, zsh, dash with -c) whose quoted code text
#        contains an agent path AND a write-shaped operation (below);
#     f. a heredoc feeding an interpreter (`python3 - <<EOF`, `bash <<EOF`)
#        whose body contains an agent path AND a write-shaped operation.
#   Write-shaped: open( with a w, a, x mode; write; >; rm; unlink; replace(;
#   rename; shutil; tee, cp, mv, touch, truncate, install, ln, rsync, chmod, dd,
#   patch as words; sed -i. A body or code that only reads an agent file passes.
#   Heredoc bodies are cut out before a-d, so text inside one is not a command.
#   Not covered: a cd into a deeper path inside .claude/agents, a stage that
#   reads agent paths from a file, an interpreter script file that writes them.
#
# Input: the hook JSON on stdin.
#   Not Bash: exit 0, no output.
#   Bash whose command contains ".claude/agents", or both ".claude" and
#   "agents", is a mention; any other Bash: no output, exit 0.
#     A mention with a write to an agent path (above): "deny", exit 0.
#     Any other mention: no output (logged as "pass"), exit 0.
#   Unparseable input or no string command: reason on stderr, exit 2, which
#   blocks the call.
#
# Run as: python3 -I tools/claude-hooks/agent-file-guard.py < hook.json
# Test: tools/test-agent-file-guard.sh
import json
import os
import re
import sys

DENY_REASON = ("Bash writes to agent files are refused; edit them with the Edit "
               "tool, which asks the maintainer")

# Command words that write, remove or change files.
WRITERS = {"tee", "cp", "mv", "rm", "rmdir", "touch", "install", "ln", "truncate",
           "dd", "chmod", "chown", "mkdir", "patch", "rsync"}
# Tokens after which the next words are commands too (and their flags and
# arguments, so `sudo -u user rm` still counts: leaning to deny).
WRAPPERS = {"xargs", "sudo", "env", "nohup", "time", "command", "exec", "!",
            "-exec", "-execdir"}
GIT_WRITES = {"checkout", "restore", "apply", "am", "mv", "rm", "stash", "reset"}
GIT_ALWAYS = {"apply", "am", "stash"}
GIT_NEEDS_PATH = {"checkout", "restore", "reset"}
WHOLE_TREE = {".", "*", ":/", ":/*", "--all"}
SH = {"sh", "bash", "zsh", "dash"}

# An output redirect: optional fd or &, '>' or '>>', optional '|', optional '&',
# optional space, then the target word.
REDIRECT = re.compile(r"(?:\d+|&)?>>?\|?(&?)\s*([^\s;|&<>()]*)")
# Splits a command into simple commands (pipelines); '|' then splits stages.
SEPARATORS = re.compile(r"&&|\|\||[;&\n()`]")
HEREDOC = re.compile(r"<<(?!<)-?[ \t]*(['\"]?)([A-Za-z_]\w*)\1")
# An interpreter, its flags, then a code flag and the space before the code.
CODE_FLAG = re.compile(
    r"(?:^|[\s;&|(`])(?:\S*/)?(python[\d.]*|perl|ruby|node|sh|bash|zsh|dash)"
    r"((?:\s+-\S+)*?)\s+(-[A-Za-z]*[cep]|--eval|--print)\s+")
WRITE_SHAPE = re.compile(
    r"""open\([^)]*['"][wax][+bt]*['"]|write|>|\brm\b|unlink|replace\(|rename|shutil"""
    r"""|\b(?:tee|cp|mv|touch|truncate|install|ln|rsync|chmod|dd|patch)\b|sed\s+-[A-Za-z]*i""")


def log(line):
    # AGENT_FILE_GUARD_LOG, set only by a permission check such as check-permissions.sh: append one
    # line per invocation, then one for the decision, so the probe can tell "the
    # hook never ran" from "it ran and its decision was not honoured". Best
    # effort; never blocks.
    path = os.environ.get("AGENT_FILE_GUARD_LOG")
    if path:
        try:
            with open(path, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


def segments(cmd):
    """Pipelines, each a list of stages, each a list of tokens."""
    out = []
    for pl in SEPARATORS.split(cmd):
        stages = []
        for st in pl.split("|"):
            toks = [t.strip("'\"").lstrip("\\") for t in st.split()]
            toks = [t for t in toks if t]
            if toks:
                stages.append(toks)
        if stages:
            out.append(stages)
    return out


def split_heredocs(cmd):
    """(cmd with heredoc bodies cut out, [(text before the <<, body)])."""
    docs = []
    pos = 0
    while True:
        m = HEREDOC.search(cmd, pos)
        if not m:
            return cmd, docs
        nl = cmd.find("\n", m.end())
        if nl < 0:
            docs.append((cmd[:m.start()], ""))
            pos = m.end()
            continue
        end_re = re.compile(r"^[ \t]*" + re.escape(m.group(2)) + r"[ \t]*$", re.M)
        t = end_re.search(cmd, nl + 1)
        body = cmd[nl + 1:t.start()] if t else cmd[nl + 1:]
        docs.append((cmd[:m.start()], body))
        cmd = cmd[:nl] + cmd[t.end() if t else len(cmd):]
        pos = m.end()


def cwd_context(pipelines):
    """(cd into a path ending .claude, cd into .claude/agents)."""
    in_claude = in_agents = False
    for pl in pipelines:
        for toks in pl:
            if toks[0] in ("cd", "pushd") and len(toks) > 1:
                d = toks[-1].rstrip("/")
                in_claude = in_claude or d.endswith(".claude")
                in_agents = in_agents or d.endswith(".claude/agents")
    return in_claude, in_agents


def is_agent_path(tok, ctx):
    t = tok.strip("'\"")
    while t.startswith("./"):
        t = t[2:]
    if ".claude/agents" in t:
        return True
    if ctx[0] and re.match(r"agents(/|$)", t):
        return True
    return bool(ctx[1] and t and t[0] not in "/~$-")


def has_agent(text, ctx):
    return ".claude/agents" in text or bool(
        ctx[0] and re.search(r"(?<![\w/.-])agents(/|\b)", text))


def redirects_to_agent(cmd, ctx):
    for m in REDIRECT.finditer(cmd):
        amp, target = m.group(1), m.group(2).strip("'\"")
        if amp and (target.isdigit() or target == "-"):
            continue  # >&2, 2>&1, >&-
        if target and target != "/dev/null" and is_agent_path(target, ctx):
            return True
    return False


def code_text(cmd, start):
    """The quoted (or single-word) code argument beginning at cmd[start]."""
    if start >= len(cmd):
        return ""
    q = cmd[start]
    if q == "'":
        end = cmd.find("'", start + 1)
        return cmd[start + 1:end if end >= 0 else len(cmd)]
    if q == '"':
        i = start + 1
        while i < len(cmd) and cmd[i] != '"':
            i += 2 if cmd[i] == "\\" else 1
        return cmd[start + 1:i]
    words = cmd[start:].split()
    return words[0] if words else ""


def writes_to_agent(cmd):
    cmd, docs = split_heredocs(cmd)
    pls = segments(cmd)
    ctx = cwd_context(pls)
    # a. redirect
    if redirects_to_agent(cmd, ctx):
        return True
    for stages in pls:
        pipeline_agent = any(is_agent_path(t, ctx) for st in stages for t in st)
        for toks in stages:
            base = [t.rsplit("/", 1)[-1] for t in toks]
            stage_agent = any(is_agent_path(t, ctx) for t in toks)
            # b. writer command words: first word after env assignments, or any
            # word after a wrapper
            wrapped = False
            first = True
            for i, t in enumerate(base):
                if first and re.match(r"^\w+=", t):
                    continue
                if (first or wrapped) and t in WRITERS:
                    if stage_agent or ("xargs" in base[:i] and pipeline_agent):
                        return True
                first = False
                if t in WRAPPERS:
                    wrapped = True
            if "find" in base and "-delete" in toks and stage_agent:
                return True
            for i, b in enumerate(base):
                after = toks[i + 1:]
                # c. in-place edit
                if b in ("sed", "perl") and stage_agent and any(
                        re.match(r"^-[A-Za-z]*i", a) or a == "--in-place"
                        or a.startswith("--in-place=") for a in after):
                    return True
                # d. git
                if b == "git":
                    for j, a in enumerate(after):
                        if a not in GIT_WRITES:
                            continue
                        args = after[j + 1:]
                        if a in GIT_ALWAYS:
                            return True
                        if any(is_agent_path(x, ctx) or x in WHOLE_TREE for x in args):
                            return True
                        if a in GIT_NEEDS_PATH and not any(
                                not x.startswith("-") and re.search(r"[/.*]", x)
                                for x in args):
                            return True
                        break
    # e. interpreter given code
    for m in CODE_FLAG.finditer(cmd):
        interp, flag = m.group(1), m.group(3)
        if interp in SH and not re.match(r"^-[A-Za-z]*c$", flag):
            continue
        code = code_text(cmd, m.end())
        if has_agent(code, ctx) and WRITE_SHAPE.search(code):
            return True
    # f. heredoc feeding an interpreter
    for head, body in docs:
        last = (segments(head) or [[[]]])[-1][-1]
        interp = any(re.match(r"^(python[\d.]*|perl|ruby|node)$", t.rsplit("/", 1)[-1])
                     or t.rsplit("/", 1)[-1] in SH for t in last)
        if interp and has_agent(body, ctx) and WRITE_SHAPE.search(body):
            return True
    return False


def main():
    log("invoked")
    try:
        data = json.load(sys.stdin)
        if not isinstance(data, dict):
            raise ValueError("hook input is not a JSON object")
    except Exception as e:
        print(f"agent-file-guard: cannot parse hook input: {e}", file=sys.stderr)
        return 2
    if data.get("tool_name") != "Bash":
        return 0
    ti = data.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str):
        print("agent-file-guard: Bash call with no string command", file=sys.stderr)
        return 2
    if ".claude/agents" in cmd or (".claude" in cmd and "agents" in cmd):
        if not writes_to_agent(cmd):
            log("pass")
            return 0
        log("deny")
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": DENY_REASON,
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
