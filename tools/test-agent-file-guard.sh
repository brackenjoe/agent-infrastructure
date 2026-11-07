#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# Test for tools/claude-hooks/agent-file-guard.py and its wiring in
# .claude/settings.json. Exit 0 if every case passed, 1 if any failed, 2 if
# the hook or python3 is missing.
#
#   tools/test-agent-file-guard.sh
#
# Offline. The hook JSON goes in on stdin; stdout and the exit code are checked.
# Cases: deny for writes (redirects, heredoc, append, sed/perl -i, tee, cp, mv,
# rm, touch, interpreters given code, git checkout/restore, cd .claude && cat >
# agents/x); silent for other mentions (ls, cat, cat <, 2>/dev/null, 2>&1, git add,
# git log, wc, a checkout path beside an audit's agents/ folder), for commands
# that do not mention agent files and for an Edit call; exit 2 for malformed JSON and for Bash with no command. A deny
# must append `invoked` then `deny` to AGENT_FILE_GUARD_LOG. Then settings.json:
# parses, carries a Bash PreToolUse hook with onFailure "block", and the file it
# runs exists.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
HOOK="$HERE/claude-hooks/agent-file-guard.py"
SETTINGS="$ROOT/.claude/settings.json"
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { failn=$((failn + 1)); echo "FAIL  $1: $2"; }

# run_hook JSON: stdout in $out, exit code in $rc
run_hook() {
  printf '%s' "$1" | python3 -I "$HOOK" >"$TMP/out" 2>"$TMP/err"
  rc=$?
  out=$(cat "$TMP/out")
}

# bash_json CMD: hook input for a Bash call, JSON-encoded safely
bash_json() {
  python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# decide WORD NAME CMD: WORD is ask or deny
decide() {
  run_hook "$(bash_json "$3")"
  if [ "$rc" -ne 0 ]; then bad "$2" "rc=$rc: $(cat "$TMP/err")"; return; fi
  if printf '%s' "$out" | python3 -I -c '
import json, sys
h = json.load(sys.stdin)["hookSpecificOutput"]
sys.exit(0 if h["hookEventName"] == "PreToolUse" and h["permissionDecision"] == sys.argv[1] and h["permissionDecisionReason"] else 1)' "$1"; then
    ok "$2"
  else
    bad "$2" "no $1 decision, stdout: $out"
  fi
}

# deny NAME CMD
deny() { decide deny "$1" "$2"; }

# silent NAME JSON
silent() {
  run_hook "$2"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$1"; else bad "$1" "rc=$rc stdout: $out"; fi
}

# exit2 NAME JSON
exit2() {
  run_hook "$2"
  if [ "$rc" -eq 2 ] && [ -s "$TMP/err" ]; then ok "$1"; else bad "$1" "rc=$rc, want 2 with stderr"; fi
}

deny "heredoc redirect, multi-line: deny" "cat > .claude/agents/x.md <<'EOF'
---
name: x
---
body
EOF"
deny "sed -i: deny"                     "sed -i s/a/b/ .claude/agents/x.md"
deny "cd .claude && cat > agents/x: deny" "cd .claude && cat > agents/x.md"
deny "tee into nested checkout copy: deny"     "tee .claude/checkouts/w/.claude/agents/x.md"
deny "append with ./ prefix: deny"      "printf x >> ./.claude/agents/x.md"
deny "append >>: deny"                  "echo x >> .claude/agents/x.md"
deny "sed -i.bak: deny"                 "sed -i.bak s/a/b/ .claude/agents/x.md"
deny "perl -i -pe: deny"                "perl -i -pe 's/a/b/' .claude/agents/x.md"
deny "tee: deny"                        "echo x | tee .claude/agents/x.md"
deny "tee -a after pipe: deny"          "echo x | tee -a .claude/agents/x.md"
deny "cp into agents: deny"             "cp a .claude/agents/x.md"
deny "mv: deny"                         "mv a.md .claude/agents/x.md"
deny "rm: deny"                         "rm .claude/agents/x.md"
deny "touch: deny"                      "touch .claude/agents/x.md"
deny "python3 -c: deny"                 "python3 -c \"open('.claude/agents/x.md','w')\""
deny "bash -c: deny"                    "bash -c 'echo > .claude/agents/x'"
deny "git checkout --: deny"            "git checkout -- .claude/agents/x.md"
deny "git restore: deny"                "git restore .claude/agents/x.md"
deny "rm -f: deny"                      "rm -f .claude/agents/x.md"
deny "python3 -c open w, double-quoted: deny" "python3 -c \"open('.claude/agents/x.md','w')\""
deny "python3 - heredoc writes: deny"   "python3 - <<'EOF'
p = '.claude/agents/x.md'
open('.claude/agents/x.md', 'w').write('x')
EOF"
deny "bash heredoc rm: deny"            "bash <<EOF
rm .claude/agents/x.md
EOF"
deny "cd /r/.claude && rm agents/x: deny" "cd /r/.claude && rm agents/x.md"
deny "xargs rm from agents listing: deny" "ls .claude/agents | xargs rm"
deny "git checkout . beside a mention: deny" "git checkout . ; ls .claude/agents"
deny "git stash beside a mention: deny" "git stash; ls .claude/agents"
deny "git rm agent path: deny"          "git rm .claude/agents/x.md"
deny "find -delete: deny"               "find .claude/agents -name x.md -delete"
deny "redirect to quoted path: deny"    "echo x > \"./.claude/agents/x.md\""
silent "ls agents: silent" "$(bash_json "ls .claude/agents")"
silent "rm elsewhere, then cat an agent file: silent" "$(bash_json "rm /tmp/x; cat .claude/agents/a.md")"
silent "python3 -c read-only: silent" "$(bash_json "python3 -c \"print(open('.claude/agents/a.md').read())\"")"
silent "refused shape 1: rm elsewhere, cd .claude/projects, grep subagents: silent" "$(bash_json "tail -2 /home/user/harness-output.txt; rm /home/user/harness-output.txt && echo removed; cd ~/.claude/projects/p; grep -lF x */subagents/*.jsonl")"
silent "refused shape 2: python3 -c reads settings.json: silent" "$(bash_json "python3 -c \"import json;s=json.load(open('/home/user/.claude/settings.json'));print(s.get('agents'))\"")"
silent "refused shape 3: heredoc edits settings.json, mentions agents: silent" "$(bash_json "python3 - <<'EOF'
p = '.claude/settings.json'
t = open(p).read()
open(p, 'w').write(t.replace('a', 'b'))
# the agents hook; tools/test-agent-file-guard.sh
EOF")"
silent "python3 heredoc only reads an agent file: silent" "$(bash_json "python3 - <<'EOF'
print(open('.claude/agents/a.md').read())
EOF")"
silent "cat heredoc text naming an agent path: silent" "$(bash_json "cat <<'EOF'
to change it run: rm .claude/agents/x.md > /dev/null
EOF")"
silent "git checkout a branch path beside a read mention: silent" "$(bash_json "git checkout feature/x; cat .claude/agents/a.md")"
silent "cp from an unrelated dir, mention in a read: silent" "$(bash_json "cp a /tmp/b && grep -c x .claude/agents/a.md")"
silent "cat file: silent" "$(bash_json "cat .claude/agents/a.md")"
silent "cat < file: silent" "$(bash_json "cat < .claude/agents/a.md")"
silent "grep 2>/dev/null: silent" "$(bash_json "grep -n x .claude/agents/a.md 2>/dev/null")"
silent "grep 2>&1: silent" "$(bash_json "grep x .claude/agents/a.md 2>&1")"
silent "git add: silent" "$(bash_json "git add .claude/agents/a.md")"
silent "git log --: silent" "$(bash_json "git log -- .claude/agents")"
silent "wc glob: silent" "$(bash_json "wc -l .claude/agents/*.md")"
silent "checkout path and an audit agents/ dir: silent" "$(bash_json "cd /r/.claude/checkouts/agent-a1/x && cat docs/audit/agents/h1/harness.py")"
silent "transcript subagents dir, read: silent" "$(bash_json "grep -c x ~/.claude/projects/p/s/subagents/agent-a.jsonl")"
silent "ls tools: silent"               '{"tool_name":"Bash","tool_input":{"command":"ls tools"}}'
silent "git status: silent"             '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
silent "redirect with no mention: silent" '{"tool_name":"Bash","tool_input":{"command":"echo hi > /tmp/x"}}'
silent "Edit call: silent"              '{"tool_name":"Edit","tool_input":{"file_path":"/x/.claude/agents/x.md"}}'
exit2 "malformed JSON: exit 2"          '{"tool_name": "Bash", '
exit2 "Bash with no command: exit 2"    '{"tool_name":"Bash","tool_input":{}}'
exit2 "Bash with non-string command: exit 2" '{"tool_name":"Bash","tool_input":{"command":5}}'

# AGENT_FILE_GUARD_LOG: a deny appends invoked then deny, a read mention invoked then pass
rm -f "$TMP/guard.log"
printf '%s' "$(bash_json "cat > .claude/agents/x.md")" | AGENT_FILE_GUARD_LOG="$TMP/guard.log" python3 -I "$HOOK" >/dev/null 2>&1
if [ "$(cat "$TMP/guard.log" 2>/dev/null)" = "invoked
deny" ]; then ok "deny logs invoked then deny"; else bad "deny log" "got: $(cat "$TMP/guard.log" 2>/dev/null)"; fi
rm -f "$TMP/guard.log"
printf '%s' "$(bash_json "cat .claude/agents/x.md")" | AGENT_FILE_GUARD_LOG="$TMP/guard.log" python3 -I "$HOOK" >/dev/null 2>&1
if [ "$(cat "$TMP/guard.log" 2>/dev/null)" = "invoked
pass" ]; then ok "read mention logs invoked then pass"; else bad "pass log" "got: $(cat "$TMP/guard.log" 2>/dev/null)"; fi

# settings wiring
if rel=$(python3 -I - "$SETTINGS" <<'PYEOF'
import json, re, sys
s = json.load(open(sys.argv[1]))
for ent in s["hooks"]["PreToolUse"]:
    if ent.get("matcher") != "Bash":
        continue
    for h in ent["hooks"]:
        m = re.search(r'\$\{?CLAUDE_PROJECT_DIR\}?/([^" ]*agent-file-guard\.py)', h.get("command", ""))
        if m and h.get("type") == "command" and h.get("onFailure") == "block":
            print(m.group(1)); sys.exit(0)
sys.exit(1)
PYEOF
); then
  ok "settings.json parses and carries the Bash hook with onFailure block"
  if [ -f "$ROOT/$rel" ]; then ok "settings hook points at an existing file: $rel"; else bad "settings hook target" "$rel does not exist"; fi
else
  bad "settings.json hook" "missing, unparseable, or no onFailure block on the Bash PreToolUse agent-file-guard hook"
fi

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
