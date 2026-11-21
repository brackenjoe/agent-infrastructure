#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# Test for tools/security-audit-run.sh (the setup, check, land and teardown
# fixes from an earlier audit).
# Exit 0 if every case passed, 1 if any failed, 2 if the fixture could not
# be built.
#
#   tools/test-security-audit-run.sh
#
# Threat model: the script under test catches mistakes and the content of a
# hostile upstream tree (export-ignore, export-subst, symlinks in a --tree
# commit). It is not built to stop a hostile same-uid agent, so nothing here
# races the script; a case only plants the file a careless or misbehaving
# agent could leave in OUT.
#
# Offline. Everything happens in a mktemp -d that is removed at the end, with
# HOME pointed into it (so SKILL_DST and CACHE are in the temp dir, never the
# real ~/.claude/skills or ~/.cache/security-audit) and the git config
# pointed away from the operator's. The fixture is a throwaway git repo
# holding a copy of the script and of tools/security-audit-skill, a tracked
# part, and gitignored --tree checkouts inside it. The main checkout is
# never touched. --sandbox is not exercised (its selfcheck is another job).
# SECURITY_AUDIT_RUN_ORIG=FILE runs the cases against FILE instead (the
# original script, to show the cases fail on it).
#
# Cases:
#   --tree     clean: setup, then check verifies it; edited, extra, mode-
#              changed, missing and symlinked target files each FAIL in
#              check; export-ignore, export-subst and a tracked symlink are
#              refused by setup, leaving no run and no skill; an outer tree
#              with a gitlink filled by an inner tree at the pinned commit
#              passes, and an edit inside the inner tree FAILs
#   --file     setup ok, check ok, a changed exec bit FAILs
#   check      invalid --values; a hit prints file:line and not the value; a
#              NUL file; a symlink at the top of OUT; a FIFO under briefs/
#              and scratch/ allowed; metadata missing, unparseable, bad
#              source_ref, a `..` dst, a dst with a leading `-`
#   land       a symlink at a fixed file, recon/*.md, result.json, an
#              agents/<id> directory, and an artifact: nothing copied, exit
#              1; check runs first: a --values hit and a change under the
#              part (a partial land) refuse with nothing landed; a clean OUT
#              lands
#   briefs     the builder's hunter brief has the venv rule with the harness
#              clause, a recon brief has it without
#   teardown   a failed removal is reported and exits 1; a clean one
#              reports "removed" and exits 0; an unknown id, and an id the
#              metadata does not name, are refused with nothing removed
#   enumeration  agents/x at mode 0311 with a --values canary: check and land
#              FAIL, nothing landed; an unreadable .git/index with a dirty
#              part: check FAILs
#   worktree   plain part untouched ok; an ignored file or a commit in the
#              worktree FAILs; --tree binds to its own base
#   setup      parts _p, .p, "x y", a+b refused with nothing made; a spaced
#              venv path is quoted in sandbox_command;
#              uncommitted change in the skill refused; a failure after the
#              run directory is made (the skill copy) leaves no run dir, no
#              worktree and no skill
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC_SCRIPT="${SECURITY_AUDIT_RUN_ORIG:-$ROOT/tools/security-audit-run.sh}"
SRC_SKILL="$ROOT/tools/security-audit-skill"
for need in git jq node; do
  command -v "$need" >/dev/null 2>&1 || { echo "$need not found" >&2; exit 2; }
done
[ -f "$SRC_SCRIPT" ] && [ -f "$SRC_SKILL/SKILL.md" ] || { echo "script or skill not found" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir "$TMP/home"
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
CACHE="$HOME/.cache/security-audit"
SKILL_DST="$HOME/.claude/skills/security-audit"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { failn=$((failn + 1)); echo "FAIL  $1: $2"; }
skip() { echo "skip  $1"; }

FIX="$TMP/repo"
PART=work/p/part
PD="$FIX/$PART"
S="$FIX/tools/security-audit-run.sh"

gc() { git -C "$1" add -A >/dev/null && git -C "$1" commit -q -m "$2"; }
new_repo() { mkdir -p "$1" && git init -q -b main "$1"; }

build_fixture() {
  mkdir -p "$FIX/tools" "$PD" || return 1
  cp "$SRC_SCRIPT" "$S" && chmod 0755 "$S" || return 1
  cp -a "$SRC_SKILL" "$FIX/tools/security-audit-skill" || return 1
  printf 'readme\n' >"$PD/README.md"
  printf '#!/bin/sh\necho tool\n' >"$PD/tool.sh"; chmod 0755 "$PD/tool.sh"
  printf 'data\n' >"$PD/data.txt"
  printf 'trees/\n' >"$PD/.gitignore"
  git init -q -b main "$FIX" || return 1
  gc "$FIX" fixture || return 1
  local T="$PD/trees"
  # clean
  new_repo "$T/clean" || return 1
  printf 'one\n' >"$T/clean/a.txt"
  mkdir -p "$T/clean/sub" "$T/clean/dir/c"
  printf '#!/bin/sh\n' >"$T/clean/sub/b.sh"; chmod 0755 "$T/clean/sub/b.sh"
  printf 'deep\n' >"$T/clean/dir/c/d.txt"
  gc "$T/clean" init || return 1
  # export-ignore
  new_repo "$T/eign" || return 1
  printf 'hidden.c export-ignore\n' >"$T/eign/.gitattributes"
  printf 'int hidden;\n' >"$T/eign/hidden.c"; printf 'int shown;\n' >"$T/eign/shown.c"
  gc "$T/eign" init || return 1
  # export-subst
  new_repo "$T/esubst" || return 1
  printf 'ver.txt export-subst\n' >"$T/esubst/.gitattributes"
  printf '$Format:%%H$\n' >"$T/esubst/ver.txt"
  gc "$T/esubst" init || return 1
  # tracked symlink
  new_repo "$T/sym" || return 1
  printf 'one\n' >"$T/sym/a.txt"; ln -s a.txt "$T/sym/link"
  gc "$T/sym" init || return 1
  # outer tree with a gitlink filled by an inner tree at the pinned commit
  new_repo "$T/outer" || return 1
  printf 'outer\n' >"$T/outer/o.txt"
  gc "$T/outer" init || return 1
  mkdir -p "$T/outer/sub"
  new_repo "$T/outer/sub/inner" || return 1
  printf 'inner\n' >"$T/outer/sub/inner/in.txt"
  gc "$T/outer/sub/inner" init || return 1
  local isha
  isha=$(git -C "$T/outer/sub/inner" rev-parse HEAD) || return 1
  git -C "$T/outer" update-index --add --cacheinfo "160000,$isha,sub/inner" || return 1
  git -C "$T/outer" commit -q -m gitlink || return 1
  [ -z "$(git -C "$T/outer" status --porcelain)" ] || return 1
}
build_fixture || { echo "fixture failed" >&2; exit 2; }
[ -z "$(git -C "$FIX" status --porcelain)" ] || { echo "fixture is not clean" >&2; exit 2; }

# --- helpers --------------------------------------------------------------
OUTP="" RC=0 RUNDIR="" OUTDIR="" TARGET=""
run() { OUTP="$("$S" "$@" 2>&1)"; RC=$?; }
reset_env() {
  chmod -R u+rwX "$CACHE" 2>/dev/null
  rm -rf "$CACHE" "$HOME/.claude"
  git -C "$FIX" worktree prune
}
do_setup() {
  reset_env
  run setup "$@"
  RUNDIR=$(sed -n 's/^RUN=//p' <<<"$OUTP")
  TARGET=$(sed -n 's/^TARGET=//p' <<<"$OUTP")
  OUTDIR="$RUNDIR/out"
}
# expect NAME RC PATTERN...: exit status, then each PATTERN a fixed string
# present in the output, or absent if it starts with '!'.
expect() {
  local name="$1" want="$2" pat; shift 2
  if [ "$RC" -ne "$want" ]; then bad "$name" "rc=$RC, want $want; output: ${OUTP:0:700}"; return; fi
  for pat in "$@"; do
    if [[ "$pat" == '!'* ]]; then
      if grep -Fq -- "${pat:1}" <<<"$OUTP"; then bad "$name" "output has '${pat:1}': ${OUTP:0:700}"; return; fi
    elif ! grep -Fq -- "$pat" <<<"$OUTP"; then
      bad "$name" "output lacks '$pat': ${OUTP:0:700}"; return
    fi
  done
  ok "$name"
}
# cond NAME COMMAND...: ok if COMMAND succeeds.
cond() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n" "output: ${OUTP:0:500}"; fi; }
no_run_left() { [ -z "$(ls -A "$CACHE" 2>/dev/null)" ] && [ ! -e "$SKILL_DST" ] && [ "$(git -C "$FIX" worktree list | wc -l)" -eq 1 ]; }
# no FAIL line except the ledger one (the cases give no ledger).
only_ledger_fail() { ! grep '^FAIL' <<<"$OUTP" | grep -v 'coverage-ledger' | grep -q .; }
meta_save() { cp "$OUTDIR/run-metadata.json" "$TMP/meta.orig"; }
meta_restore() { cp "$TMP/meta.orig" "$OUTDIR/run-metadata.json"; }
meta_edit() { jq "$1" "$TMP/meta.orig" >"$OUTDIR/run-metadata.json"; }
isroot=false; [ "$(id -u)" -eq 0 ] && isroot=true

# --- --tree: clean, then tampering ----------------------------------------
do_setup "$PART" --tree "$PART/trees/clean"
expect "tree clean: setup ok" 0 "RUN=" "TARGET="
run check "$OUTDIR"
expect "tree clean: check verifies the tree" 1 "ok    target trees match their commits" "ok    checkout clean" "ok    run worktree clean"
cond "tree clean: nothing fails but the missing ledger" only_ledger_fail
T="$TARGET/clean"
cp "$T/a.txt" "$TMP/a.save"
printf 'extra\n' >>"$T/a.txt"
run check "$OUTDIR"; expect "tree edited after setup: check FAILs" 1 "FAIL  content differs from the commit: a.txt" "!ok    target trees match"
cp "$TMP/a.save" "$T/a.txt"
printf 'x\n' >"$T/extra.txt"
run check "$OUTDIR"; expect "tree extra file: check FAILs" 1 "FAIL  unexpected entry in the target: extra.txt"
rm -f "$T/extra.txt"
mkdir "$T/emptydir"
run check "$OUTDIR"; expect "tree extra directory: check FAILs" 1 "FAIL  unexpected entry in the target: emptydir"
rmdir "$T/emptydir"
chmod +x "$T/a.txt"
run check "$OUTDIR"; expect "tree mode changed: check FAILs" 1 "FAIL  mode differs from the commit (100755, want 100644): a.txt"
chmod 0644 "$T/a.txt"
rm -f "$T/sub/b.sh"
run check "$OUTDIR"; expect "tree file removed: check FAILs" 1 "FAIL  missing or not a regular file in the target: sub/b.sh"
printf '#!/bin/sh\n' >"$T/sub/b.sh"; chmod 0755 "$T/sub/b.sh"
rm -f "$T/a.txt"; ln -s /etc/hostname "$T/a.txt"
run check "$OUTDIR"; expect "tree file replaced by a symlink: check FAILs" 1 "FAIL  missing or not a regular file in the target: a.txt"
rm -f "$T/a.txt"; cp "$TMP/a.save" "$T/a.txt"
run check "$OUTDIR"; expect "tree restored: check verifies again" 1 "ok    target trees match their commits"
cond "tree restored: nothing fails but the missing ledger" only_ledger_fail

# --- --tree: refused by setup ---------------------------------------------
do_setup "$PART" --tree "$PART/trees/eign"
expect "export-ignore: setup refuses, naming file and cause" 1 "FAIL  missing or not a regular file in the target: hidden.c" "export-ignore" "!RUN="
cond "export-ignore: no run, worktree or skill left" no_run_left
do_setup "$PART" --tree "$PART/trees/esubst"
expect "export-subst: setup refuses, naming file and cause" 1 "FAIL  content differs from the commit: ver.txt" "export-subst" "!RUN="
cond "export-subst: no run, worktree or skill left" no_run_left
do_setup "$PART" --tree "$PART/trees/sym"
expect "tracked symlink: setup refuses" 1 "FAIL  symlink in tree link: --tree targets must be symlink-free, as --file" "!RUN="
cond "tracked symlink: no run, worktree or skill left" no_run_left

# --- --tree: gitlink filled by an inner tree -------------------------------
do_setup "$PART" --tree "$PART/trees/outer" --tree "$PART/trees/outer/sub/inner:outer/sub/inner"
expect "outer + inner: setup ok" 0 "RUN="
run check "$OUTDIR"
expect "outer + inner: check verifies both" 1 "ok    target trees match their commits"
cond "outer + inner: nothing fails but the missing ledger" only_ledger_fail
IN="$TARGET/outer/sub/inner"
printf 'tampered\n' >>"$IN/in.txt"
run check "$OUTDIR"; expect "inner tree edited: check FAILs" 1 "FAIL  content differs from the commit: in.txt"
printf 'inner\n' >"$IN/in.txt"
printf 'x\n' >"$IN/new.txt"
run check "$OUTDIR"; expect "inner tree extra file: check FAILs" 1 "FAIL  unexpected entry in the target: new.txt"
rm -f "$IN/new.txt"
printf 'x\n' >"$TARGET/outer/stray.txt"
run check "$OUTDIR"; expect "outer tree extra file: check FAILs" 1 "FAIL  unexpected entry in the target: stray.txt"
rm -f "$TARGET/outer/stray.txt"
do_setup "$PART" --tree "$PART/trees/outer"
expect "outer alone: the gitlink stays an empty directory, setup ok" 0 "RUN="
run check "$OUTDIR"; expect "outer alone: check verifies" 1 "ok    target trees match their commits"

# --- --file ---------------------------------------------------------------
do_setup "$PART" --file "$PART/tool.sh" --file "$PART/data.txt:d/data.txt"
expect "file: setup ok" 0 "RUN="
meta_save
run check "$OUTDIR"
expect "file: check ok" 1 "ok    target files present, regular, byte-identical" "ok    only regular files and directories under OUT"
cond "file: nothing fails but the missing ledger" only_ledger_fail
chmod -x "$TARGET/tool.sh"
run check "$OUTDIR"; expect "file mode changed: check FAILs" 1 "FAIL  target file tool.sh has mode 100644"
chmod +x "$TARGET/tool.sh"

# --- check: scan, entries, metadata ----------------------------------------
run check "$OUTDIR" --values '('
expect "invalid --values regex: FAIL, no ok for values" 1 "FAIL  invalid --values regex" "!ok    no line matches --values"
printf 'a line with SECRETVALUE9\n' >"$OUTDIR/recon/n.md"
run check "$OUTDIR" --values 'SECRETVALUE'
expect "--values hit: file:line only, never the value" 1 "FAIL  lines matching --values" "recon/n.md:1" "!SECRETVALUE9"
run check "$OUTDIR" --values 'NOMATCHXYZ'
expect "--values with no hit: ok" 1 "ok    no line matches --values"
rm -f "$OUTDIR/recon/n.md"
printf '{"lat": 51.5}\n' >"$OUTDIR/recon/coord.md"
run check "$OUTDIR"
expect "coordinate hit prints file:line, not the line" 1 "FAIL  JSON coordinate fields" "recon/coord.md:1" "!51.5"
rm -f "$OUTDIR/recon/coord.md"
printf 'x\0\n{"lat": 51.5}\n' >"$OUTDIR/recon/nul.md"
run check "$OUTDIR"
expect "NUL file is scanned as text" 1 "FAIL  JSON coordinate fields" "recon/nul.md:2"
rm -f "$OUTDIR/recon/nul.md"
ln -s /etc/hostname "$OUTDIR/leak"
run check "$OUTDIR"
expect "symlink at the top of OUT: FAIL, named" 1 "FAIL  not a regular file or directory under OUT" "leak" "!ok    only regular files"
rm -f "$OUTDIR/leak"
ln -s /etc "$OUTDIR/recon/dirlink"
run check "$OUTDIR"
expect "symlink to a directory below OUT: FAIL, named" 1 "recon/dirlink"
rm -f "$OUTDIR/recon/dirlink"
mkdir -p "$OUTDIR/agents/a1/scratch"
mkfifo "$OUTDIR/briefs/f" "$OUTDIR/agents/a1/scratch/f"
ln -s /etc/hostname "$OUTDIR/briefs/l"
run check "$OUTDIR"
expect "FIFO and symlink under briefs/ and scratch/ are exempt" 1 "ok    only regular files and directories under OUT" "!FAIL  not a regular file"
rm -rf "$OUTDIR/briefs/f" "$OUTDIR/briefs/l" "$OUTDIR/agents/a1"
mv "$OUTDIR/run-metadata.json" "$TMP/meta.moved"
run check "$OUTDIR"; expect "metadata missing: FAIL" 1 "FAIL  run-metadata.json is missing"
meta_restore
printf '{ not json' >"$OUTDIR/run-metadata.json"
run check "$OUTDIR"; expect "metadata unparseable: FAIL" 1 "FAIL  run-metadata.json does not parse"
meta_edit '.source_ref = "--output=/tmp/x"'
run check "$OUTDIR"; expect "source_ref with a dash: FAIL" 1 "FAIL  source_ref is not a 40-hex commit id"
meta_edit '.source_ref = "ABCDEF"'
run check "$OUTDIR"; expect "source_ref short: FAIL" 1 "FAIL  source_ref is not a 40-hex commit id"
meta_edit '.source_ref = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
run check "$OUTDIR"; expect "source_ref names no commit: FAIL, nothing passes silently" 1 "FAIL  cannot read" "!ok    target files present"
meta_edit '.target_files[0].dst = "../x"'
run check "$OUTDIR"; expect "dst with '..': FAIL" 1 "FAIL  target_files dst is not a clean relative path" "!ok    target files present"
meta_edit '.target_files[0].dst = "-rf"'
run check "$OUTDIR"; expect "dst with a leading dash: FAIL" 1 "FAIL  target_files dst is not a clean relative path"
meta_edit '.target_files[0].dst = "/etc/passwd"'
run check "$OUTDIR"; expect "absolute dst: FAIL" 1 "FAIL  target_files dst is not a clean relative path"
meta_restore
run check "$OUTDIR"; expect "metadata restored: file target ok again" 1 "ok    target files present"

# --- check: tree metadata ---------------------------------------------------
do_setup "$PART" --tree "$PART/trees/clean"
meta_save
meta_edit '.target_trees[0].dst = "../clean"'
run check "$OUTDIR"; expect "tree dst with '..': FAIL" 1 "FAIL  target_trees dst is not a clean relative path" "!ok    target trees match"
meta_edit '.target_trees[0].commit = "--all"'
run check "$OUTDIR"; expect "tree commit not 40-hex: FAIL" 1 "FAIL  target_trees commit is not a 40-hex commit id"
meta_restore

# --- land -------------------------------------------------------------------
LAND="$TMP/land"
echo "outside" >"$TMP/outside.txt"
mkdir -p "$TMP/outside_agent"; echo '{"r":1}' >"$TMP/outside_agent/result.json"
mk_out() {
  local o="$LAND/$1"
  rm -rf "$o"
  mkdir -p "$o/recon" "$o/agents/x/artifacts" "$o/briefs"
  echo report >"$o/REPORT.md"; echo '{}' >"$o/findings.json"
  echo recon >"$o/recon/a.md"; echo '{}' >"$o/agents/x/result.json"
  echo ev >"$o/agents/x/artifacts/e.txt"; echo '{}' >"$o/critic-wave-1.json"
  echo brief >"$o/briefs/b.md"
}
land_case() { # NAME PLANT-COMMAND-ARGS... ; plants a symlink, then lands
  local name="$1"; shift
  mk_out "$name"
  ( cd "$LAND/$name" && "$@" )
  run land "$LAND/$name" "$TMP/dest-$name"
  expect "land: symlink at $name: refused" 1 "FAIL  land:" "!landed"
  cond "land: symlink at $name: nothing copied" test ! -e "$TMP/dest-$name"
}
# A real OUT that passes check: a setup run plus the files the validators want.
mk_good_out() {
  do_setup "$PART" --file "$PART/data.txt"
  echo '[]' >"$OUTDIR/findings.json"; echo '[]' >"$OUTDIR/coverage-ledger.json"
  echo report >"$OUTDIR/REPORT.md"
  mkdir -p "$OUTDIR/recon" "$OUTDIR/agents/x/artifacts" "$OUTDIR/briefs"
  echo recon >"$OUTDIR/recon/a.md"; echo '{}' >"$OUTDIR/agents/x/result.json"
  echo ev >"$OUTDIR/agents/x/artifacts/e.txt"; echo brief >"$OUTDIR/briefs/b.md"
}
mk_good_out
run check "$OUTDIR"
expect "land fixture: check passes on the good OUT" 0 "ok    checkout clean"
run land "$OUTDIR" "$TMP/dest-ok"
expect "land: clean OUT lands after check (exit 0)" 0 "check before landing:" "landed 7 file(s)" "!land refused"
cond "land: briefs/ not copied" test ! -e "$TMP/dest-ok/briefs"
echo "SECRETWORD" >>"$OUTDIR/REPORT.md"
run land "$OUTDIR" "$TMP/dest-vals" --values SECRETWORD
expect "land: a --values hit is a check FAIL: refused" 1 "FAIL  lines matching --values" "FAIL  land refused: check failed" "!landed"
cond "land: --values hit: nothing landed" test ! -e "$TMP/dest-vals"
run land "$OUTDIR" "$TMP/dest-vals2"
expect "land: same OUT without --values lands" 0 "landed 7 file(s)"
echo "stray" >"$PD/stray.txt"
run land "$OUTDIR" "$TMP/dest-part"
expect "land: changes under the part (a partial land): refused with the reason" 1 "FAIL  checkout has changes under $PART" "previous partial land" "!landed"
cond "land: changes under the part: nothing landed" test ! -e "$TMP/dest-part"
rm -f "$PD/stray.txt"
run land "$OUTDIR" "$TMP/dest-part2"
expect "land: lands once the stray copy is removed" 0 "landed 7 file(s)"
land_case "fixed-file" bash -c "rm REPORT.md && ln -s '$TMP/outside.txt' REPORT.md"
land_case "recon" bash -c "rm recon/a.md && ln -s '$TMP/outside.txt' recon/a.md"
land_case "result.json" bash -c "rm agents/x/result.json && ln -s '$TMP/outside.txt' agents/x/result.json"
land_case "agent-dir" bash -c "ln -s '$TMP/outside_agent' agents/y"
land_case "artifact" bash -c "ln -s '$TMP/outside.txt' agents/x/artifacts/link.txt"
land_case "critic-wave" bash -c "rm critic-wave-1.json && ln -s '$TMP/outside.txt' critic-wave-1.json"
land_case "recon-dir" bash -c "rm -rf recon && ln -s '$TMP/outside_agent' recon"

# --- check and land: a failed enumeration is never read as clean -----------
if $isroot; then
  skip "enumeration failures: running as root, chmod does not hide anything"
else
  mk_good_out
  echo "CANARYVAL7" >"$OUTDIR/agents/x/artifacts/c.txt"
  chmod 0311 "$OUTDIR/agents/x"
  run check "$OUTDIR" --values CANARYVAL7
  expect "unlistable agents/x (0311): check FAILs, scans do not read as clean" 1 "FAIL  scan failed" "FAIL  the type scan could not list" "!ok    no line matches --values" "!ok    only regular files"
  run land "$OUTDIR" "$TMP/dest-0311" --values CANARYVAL7
  expect "unlistable agents/x (0311): land refuses, naming the directory" 1 "FAIL  land: agents/x cannot be listed" "FAIL  land refused; nothing copied" "!landed"
  cond "unlistable agents/x (0311): nothing landed" test ! -e "$TMP/dest-0311"
  chmod 0755 "$OUTDIR/agents/x"
  run land "$OUTDIR" "$TMP/dest-0311b" --values CANARYVAL7
  expect "agents/x listable again: the canary is a --values hit, land refuses" 1 "FAIL  lines matching --values" "!landed"
  rm -f "$OUTDIR/agents/x/artifacts/c.txt"
  # a dirty part and an unreadable index: git status fails, not "clean"
  echo stray >"$PD/stray.txt"
  chmod 000 "$FIX/.git/index"
  run check "$OUTDIR"
  expect "unreadable .git/index with a dirty part: check FAILs" 1 "FAIL  git status failed in the checkout" "!ok    checkout clean"
  chmod 0644 "$FIX/.git/index"
  rm -f "$PD/stray.txt"
  run check "$OUTDIR"
  expect "index readable again: checkout clean" 0 "ok    checkout clean"
fi

# --- check: the worktree is bound to the commit it was made at -------------
do_setup "$PART"
expect "plain part: setup ok" 0 "RUN="
WT="$RUNDIR/worktree"
run check "$OUTDIR"
expect "plain part untouched: worktree clean and at its commit" 1 "ok    run worktree clean" "ok    run worktree HEAD is the commit it was made at" "ok    checkout clean"
cond "plain part untouched: nothing fails but the missing ledger" only_ledger_fail
mkdir -p "$WT/$PART/trees"; echo x >"$WT/$PART/trees/planted.txt"
run check "$OUTDIR"
expect "ignored file under the part: check FAILs" 1 "FAIL  run worktree has changes" "planted.txt"
rm -rf "$WT/$PART/trees"
git -C "$WT" commit -q --allow-empty -m moved
run check "$OUTDIR"
expect "a commit in the worktree: check FAILs" 1 "FAIL  run worktree HEAD is" "(a commit or reset was made in it)"
git -C "$WT" reset -q --hard "$(jq -r .worktree_ref "$OUTDIR/run-metadata.json")"
run check "$OUTDIR"
expect "worktree reset to its commit: HEAD ok again" 1 "ok    run worktree HEAD is the commit it was made at"
meta_save
jq 'del(.worktree_ref)' "$TMP/meta.orig" >"$OUTDIR/run-metadata.json"
run check "$OUTDIR"
expect "older metadata without worktree_ref: source_ref binds" 1 "ok    run worktree HEAD is the commit it was made at"
meta_restore
do_setup "$PART" --tree "$PART/trees/clean"
run check "$OUTDIR"
expect "--tree: worktree HEAD binds to the checkout commit, not source_ref" 1 "ok    run worktree HEAD is the commit it was made at" "ok    run worktree clean"

# --- setup: the part basename must give a run id teardown accepts ----------
for badpart in work/p/_p work/p/.p "work/p/x y" work/p/a+b; do
  reset_env
  run setup "$badpart"
  expect "setup: part '$badpart' is refused before anything is made" 1 "FAIL  the basename of PART" "!RUN="
  cond "setup: part '$badpart' leaves no run, no skill, no worktree" no_run_left
done
# a stub sandbox (the fixture has none): the venv path is shell-quoted
printf '#!/bin/sh\ncase "$1" in selfcheck) echo "ok    stub" ;; defaults) echo "mem=1M" ;; esac\n' >"$FIX/tools/security-audit-sandbox.sh"
chmod 0755 "$FIX/tools/security-audit-sandbox.sh"
mkdir -p "$TMP/v v"; : >"$TMP/v v/pyvenv.cfg"
do_setup "$PART" --sandbox --venv "$TMP/v v"
expect "setup --sandbox: spaced venv path setup ok" 0 "RUN="
cond "setup --sandbox: the venv path is quoted in sandbox_command" bash -c \
  'jq -r .sandbox_command "$0/run-metadata.json" | grep -Fq -- "--venv $(printf "%q" "$1")"' "$OUTDIR" "$TMP/v v"
rm -f "$FIX/tools/security-audit-sandbox.sh"
reset_env

# --- briefs: the venv rule ---------------------------------------------------
BR="$TMP/briefs-out"
mkdir -p "$BR"
jq -n '{target:"/t/target", sandbox_available:true, excluded_paths:[],
        sandbox_command:"sandbox --ro /srv/venv-main/bin/python -- python {TARGET}/h.py {SCRATCH}"}' >"$BR/run-metadata.json"
echo "arch" >"$BR/architecture.md"
jq -n '[{coverage_id:"u1", status:"in_progress", agent_id:"hunter-1",
         ordinary_attack_class_block:"ATTACK-CLASSES.md#Injection"}]' >"$BR/coverage-ledger.json"
BRIEFS="$ROOT/tools/security-audit-briefs.py"
VENV_RULE_TXT="The venv in the sandbox command is mounted for the sandbox only: never list, grep or read it."
OUTP="$(python3 -I "$BRIEFS" "$BR" hunters 2>&1)"; RC=$?
expect "briefs: hunters build" 0
cond "briefs: hunter brief has the venv rule with the harness clause" bash -c \
  'grep -Fq -- "$0 To learn how a dependency behaves, run a harness that exercises it inside the sandbox. Write only under your own scratch/ with absolute paths." "$1"/briefs/hunter-1.md' "$VENV_RULE_TXT" "$BR"
cond "briefs: the venv rule comes right after the Read-only rule" bash -c \
  'grep -A1 -F "Read only under TARGET" "$0"/briefs/hunter-1.md | grep -Fq "venv in the sandbox command"' "$BR"
OUTP="$(python3 -I "$BRIEFS" "$BR" recon 2>&1)"; RC=$?
expect "briefs: recon builds" 0
cond "briefs: recon brief has the venv rule without the harness clause" bash -c \
  'grep -Fq -- "$0" "$1"/briefs/recon-1a.md && ! grep -Fq "run a harness" "$1"/briefs/recon-1a.md' "$VENV_RULE_TXT" "$BR"

# --- teardown ---------------------------------------------------------------
if $isroot; then
  skip "teardown removal failure: running as root, chmod does not block rm"
else
  do_setup "$PART" --file "$PART/data.txt"
  mkdir "$OUTDIR/locked"; echo x >"$OUTDIR/locked/f"; chmod 500 "$OUTDIR/locked"
  RID=$(basename "$RUNDIR")
  run teardown "$RID"
  expect "teardown: a failed removal exits 1 and is not reported removed" 1 "FAIL  could not remove $RUNDIR" "removed $SKILL_DST"
  cond "teardown: no 'removed RUN' line for the failed one" bash -c '! grep -Fxq "removed $0" <<<"$1"' "$RUNDIR" "$OUTP"
  chmod 700 "$OUTDIR/locked"
fi
do_setup "$PART" --file "$PART/data.txt"
RID=$(basename "$RUNDIR")
run teardown "$RID"
expect "teardown: clean run: removed lines, exit 0" 0 "removed $SKILL_DST" "removed $RUNDIR/worktree" "removed $RUNDIR" "!FAIL"
cond "teardown: nothing left" no_run_left
do_setup "$PART" --file "$PART/data.txt"
RID=$(basename "$RUNDIR")
run teardown "$RID" --keep-out
expect "teardown --keep-out: out kept, target removed, exit 0" 0 "kept $RUNDIR/out" "removed $RUNDIR/target"
cond "teardown --keep-out: out still holds the metadata" test -f "$OUTDIR/run-metadata.json"
reset_env
mkdir -p "$CACHE/ghost-2026-11-04-1/worktree"
run teardown ghost-2026-11-04-1
expect "teardown: an id with no metadata is refused" 1 "FAIL  " "run-metadata.json is missing"
cond "teardown: the refused directory is untouched" test -d "$CACHE/ghost-2026-11-04-1/worktree"
do_setup "$PART" --file "$PART/data.txt"
RID=$(basename "$RUNDIR")
jq '.run_id = "someone-else-1"' "$OUTDIR/run-metadata.json" >"$TMP/m.json" && cp "$TMP/m.json" "$OUTDIR/run-metadata.json"
run teardown "$RID"
expect "teardown: metadata naming another run_id is refused" 1 "FAIL  " "names run_id 'someone-else-1'" "!removed $SKILL_DST" "!removed $RUNDIR"
cond "teardown: refusal leaves the skill and the worktree" bash -c 'test -d "$0" && test -d "$1/worktree"' "$SKILL_DST" "$RUNDIR"

# --- setup: skill state and late failure -----------------------------------
reset_env
SK="$FIX/tools/security-audit-skill"
printf 'local edit\n' >>"$SK/SKILL.md"
run setup "$PART" --file "$PART/data.txt"
expect "setup: an uncommitted change in the skill is refused" 1 "FAIL  uncommitted changes in tools/security-audit-skill" "!RUN="
cond "setup: skill change refusal makes no run" no_run_left
git -C "$FIX" checkout -q -- tools/security-audit-skill
# an untracked, gitignored skill copy passes `status --porcelain`: refused anyway
reset_env
git -C "$FIX" rm -r -q --cached tools/security-audit-skill
printf 'tools/security-audit-skill\n' >>"$FIX/.git/info/exclude"
run setup "$PART" --file "$PART/data.txt"
expect "setup: a skill with no tracked files is refused" 1 "FAIL  tools/security-audit-skill has no tracked files" "!RUN="
cond "setup: untracked skill refusal makes no run" no_run_left
git -C "$FIX" reset -q -- tools/security-audit-skill
sed -i '/^tools\/security-audit-skill$/d' "$FIX/.git/info/exclude"
if $isroot; then
  skip "setup late failure: running as root, chmod does not block cp"
else
  # (1) the skill copy dies half way: an unreadable file (assume-unchanged,
  # so the skill still counts as clean); (2) its parent is a regular file.
  git -C "$FIX" update-index --assume-unchanged tools/security-audit-skill/ATTACK-CLASSES.md
  chmod 000 "$SK/ATTACK-CLASSES.md"
  do_setup "$PART" --file "$PART/data.txt"
  expect "setup: the skill copy fails half way: exit 1" 1 "FAIL  copying the skill" "!RUN="
  cond "setup: a late failure leaves no run dir, no worktree and no skill" no_run_left
  chmod 0644 "$SK/ATTACK-CLASSES.md"
  git -C "$FIX" update-index --no-assume-unchanged tools/security-audit-skill/ATTACK-CLASSES.md
  reset_env
  mkdir -p "$HOME/.claude"; : >"$HOME/.claude/skills"
  run setup "$PART" --file "$PART/data.txt"
  expect "setup: skills parent unusable, fails after the metadata: exit 1" 1 "FAIL  copying the skill" "!RUN="
  cond "setup: that failure leaves no run dir and no worktree" bash -c '[ -z "$(ls -A "$0" 2>/dev/null)" ] && [ "$(git -C "$1" worktree list | wc -l)" -eq 1 ]' "$CACHE" "$FIX"
fi
do_setup "$PART" --file "$PART/data.txt"
expect "setup: succeeds again after the failed one" 0 "RUN="
cond "setup: the skill is installed and the metadata written" bash -c 'test -f "$0/SKILL.md" && test -f "$1/run-metadata.json"' "$SKILL_DST" "$OUTDIR"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
