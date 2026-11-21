#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# The mechanical half of a security-audit run:
# the parent agent does the judgement, this does the setup, the checks and
# the clean-up. Run by the manager, in a fresh session, never ambient: the
# skill is copied into ~/.claude/skills/ by setup and removed by teardown.
# Exit 1 on any failed step or check, 2 on usage.
#
#   tools/security-audit-run.sh setup PART [--budget N] [--profile P] [--exclude PATH]... [--sandbox]
#                                     [--file SRC[:DST]]... [--tree DIR[@REV][:DST]]...
#                                     [--venv DIR] [--selftest-cmd CMD]...
#   tools/security-audit-run.sh validate OUT
#   tools/security-audit-run.sh check OUT [--values REGEX]
#   tools/security-audit-run.sh land OUT DEST [--values REGEX]
#   tools/security-audit-run.sh teardown RUN-ID [--keep-out]
#
# setup     PART is a tracked, committed directory (for example apps/example).
#           Its basename must pass the run-id grammar teardown enforces
#           (starts with a letter or digit; letters, digits, '.', '_', '-';
#           no '..'; one function, run_id_ok, serves both) or setup refuses
#           before any state is made. The venv path and the data variable in
#           sandbox_command are shell-quoted with printf %q.
#           Makes ~/.cache/security-audit/<run-id>/ with worktree/ (detached
#           at HEAD), out/{agents,recon,briefs}/ and out/run-metadata.json,
#           and copies tools/security-audit-skill/ to
#           ~/.claude/skills/security-audit/, last, after the metadata is
#           written (refused if already there, or if the vendored skill has
#           uncommitted changes). A failure after the run directory is made
#           removes what this setup made (worktree, run directory, the skill
#           copy if it installed one) and exits 1.
#           Prints RUN=, TARGET=, OUT=, SKILL=. Budget defaults to 20 and
#           must be at least 10 (4 recon + 1 critic + 5 hunters).
#           --sandbox runs tools/security-audit-sandbox.sh selfcheck first
#           and refuses (no run made) unless every control is ok; the
#           metadata's sandbox_note then names the tool and its defaults.
#           --file SRC[:DST] (repeatable) makes the target a set of named
#           files, for loose files that belong to no part (the public
#           drone-tools and print-tools trees). SRC is a repo-relative path
#           tracked at HEAD as a regular file (mode 100644 or 100755), with
#           no uncommitted change; DST (default: basename SRC) is relative,
#           has no `..` and is unique. The files are copied from the detached
#           worktree to ~/.cache/security-audit/<run-id>/target/<basename
#           PART>/ at their mode and checked byte-identical to HEAD (the
#           target is outside the worktree so the worktree stays clean);
#           PART still names the run (prior_runs, check, land). Metadata
#           gains target_files, scope_paths = PART + every SRC, and the
#           sandbox_command carries no --env <PART>_DATA pair. TARGET= prints
#           the file target. Anything wrong is refused before a run exists.
#           --tree DIR[@REV][:DST] (repeatable, not with --file) makes the
#           target a separate git checkout that sits gitignored inside this
#           repo (tools/some-checkout). DIR is repo-relative, the top
#           level of its own work tree (not this repo); REV (default HEAD)
#           is resolved to a commit, and for HEAD the checkout must be clean;
#           DST (default: basename DIR) is relative, has no `..` and is
#           unique. Each tree is `git archive`d at its commit into
#           ~/.cache/security-audit/<run-id>/target/<basename PART>/DST, outer
#           trees first, and each is then verified against `git ls-tree -r`
#           of its commit (verify_tree): every file a regular file with the
#           blob's hash and exec bit, nothing missing, nothing extra, and a
#           symlink in the tree refused (as --file does). That catches
#           export-ignore and export-subst in the commit's .gitattributes,
#           which make `git archive` drop or rewrite files. One tree may lie inside another's DST only where
#           that path is a gitlink in the outer tree at the outer commit and
#           the inner tree's commit is the gitlink's (that is how a submodule
#           checkout fills it); other gitlinks stay empty. Metadata gains
#           target_trees [{dir, remote, commit, dst, gitlinks}], repo and
#           source_ref from the outermost tree, checkout_ref (this repo's
#           HEAD), scope_paths = PART + every DIR, and the sandbox_command
#           carries no --env <PART>_DATA pair. Anything wrong is refused
#           before a run exists.
#           --venv DIR (needs --sandbox) replaces the part's .venv in
#           sandbox_command. --selftest-cmd CMD (repeatable) is written to
#           metadata selftest_commands ({TARGET} allowed) for the hunters'
#           harness text. The metadata also names the worktree ("worktree").
# validate  both validators from tools/security-audit-skill on
#           OUT/findings.json (skipped if absent) and
#           OUT/coverage-ledger.json (FAIL if absent), then the ledger
#           counts by status and the findings counts by verdict.
# check     (a) git status empty under the part (and every --file source) in
#           this checkout and empty in the run's worktree (a worktree that
#           is not a git repo is a FAIL; a git status that itself fails, in
#           the checkout or the worktree, is a FAIL; in a plain-part run the
#           worktree status also counts ignored and untracked files); the
#           worktree's HEAD must equal worktree_ref (metadata: the commit
#           setup made it at; checkout_ref or source_ref in older metadata);
#           run-metadata.json present and
#           parseable (FAIL otherwise), source_ref a 40-hex commit id, every
#           target_files/target_trees dst relative with no `..` and no leading
#           `-`; with --file, every target file present, regular, equal to
#           `git show` of the reviewed commit (a failed git show is a FAIL)
#           and with the commit's exec bit, nothing else under the target;
#           with --tree, verify_tree of each tree against its own commit
#           (not a rebuild, so independent of git archive); (b) no JSON
#           coordinate field with a number, no line naming lat/lon/lng with a
#           decimal of three or more places (version numbers and file:line
#           tokens removed first), no line matching --values REGEX, anywhere
#           under OUT but OUT/briefs. Files are scanned as text (grep -a), a
#           grep status of 2 or more is a FAIL ("scan failed"), an invalid
#           --values regex is a FAIL, and any entry under OUT that is not a
#           regular file or directory (a symlink, FIFO) is a FAIL, except
#           under briefs/ and agents/*/scratch/. A find that fails or a
#           directory under OUT that cannot be listed makes the type scan
#           and every grep scan a FAIL. A hit prints file:line,
#           never the line. (c) validate. A relative OUT is relative to the
#           working directory.
# land      first checks every source: the fixed files, recon/*.md,
#           critic-wave-*.json, agents/<id>/result.json and every file in
#           agents/<id>/artifacts/ must be regular files and not symlinks;
#           recon/, agents/, each agents/<id>/ and each artifacts/ real
#           directories, and every directory under OUT must be readable and
#           searchable (-r, -x). Any failure is a FAIL naming the entry; nothing is
#           copied and the exit is 1. Then runs `check OUT` (with --values if
#           given) and refuses, copying nothing, if any FAIL: that includes
#           "checkout has changes" under the part, so a previous partial
#           land into it must be removed first. Then copies the report files,
#           findings, ledger, metadata, architecture, critic (critic-final,
#           critic-wave-*), hardening (and hardening-by-hunter), candidates,
#           record-verifiers, phase5-log, recon/*.md, agents/<id>/result.json
#           (as agents/<id>.json) and the files in agents/<id>/artifacts/ (as
#           agents/<id>/artifacts/<name>) to DEST, a new directory; a
#           relative DEST is relative to the repo root. briefs/ and any
#           scratch/ are never copied.
# teardown  refuses (exit 1) an id whose <run>/out/run-metadata.json is
#           missing or names another run_id. Otherwise removes the skill
#           copy, the run's worktree and, unless --keep-out, the run
#           directory (with --keep-out, the file target too). "removed X"
#           is printed only when X is gone; any removal that fails is a FAIL
#           and the exit is 1. Parts already gone are not an error.
set -uo pipefail
shopt -s nullglob
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_SRC="$ROOT/tools/security-audit-skill"
SKILL_DST="$HOME/.claude/skills/security-audit"
SANDBOX="$ROOT/tools/security-audit-sandbox.sh"
CACHE="$HOME/.cache/security-audit"
SKILL_COMMIT="c1c8a8c1471069fb0e188eeaff69b8e8db6564a8"
fail=0
FAIL() { echo "FAIL  $*"; fail=1; }
OK()   { echo "ok    $*"; }
SKIP() { echo "skip  $*"; }

usage() {
  sed -n '/^#   tools\/security-audit-run.sh/p' "$0" | sed 's/^#   //' >&2
  exit 2
}

# abs_dir DIR: print DIR as an absolute path, or fail.
# run_id_ok ID: the one grammar for a run id and for the basename of a PART
# (a run id is <basename>-<date>-<n>, so a basename that passes makes an id
# that passes). setup refuses a PART that fails it before any state is made;
# teardown refuses an id that fails it. Letters and digits first, then letters,
# digits, '.', '_' and '-', and no '..'.
run_id_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *..* ]]; }

abs_dir() { (cd "$1" 2>/dev/null && pwd); }

# owner_repo URL: print owner/repo from a git remote URL (empty if none).
owner_repo() {
  local u="${1%/}"
  u="${u%.git}"
  printf '%s\n' "$u" | awk -F'[/:]' 'NF >= 2 { print $(NF-1) "/" $NF }'
}

# mat_tree DIR SHA DEST: git archive of DIR at SHA extracted into DEST.
mat_tree() {
  local -a st
  mkdir -p "$3" || return 1
  git -C "$1" archive --format=tar "$2" | tar -x -C "$3"
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ]
}

# vt_bad MESSAGE: one verify_tree failure; the first 20 are printed.
VT_BAD=0
vt_bad() {
  VT_BAD=$((VT_BAD + 1))
  [ "$VT_BAD" -gt 20 ] || FAIL "$*"
}

# verify_tree DIR SHA DEST: DEST holds exactly the tree of commit SHA in the
# git work tree DIR, compared with `git ls-tree -r -z`, not with another
# `git archive` (which honours export-ignore and export-subst). Regular
# entries: a regular non-symlink file at DEST/path, hash-object --no-filters
# equal to the blob id, exec bit equal to the mode. A symlink entry is a
# FAIL. A gitlink must be a directory; what is inside it is the nested
# tree's own verify. Nothing else may be in DEST. Prints FAIL lines, returns
# 1 on any.
verify_tree() {
  local dir="$1" sha="$2" dest="$3"
  local lst ent meta p mode blob d g rel i m bits hout nh
  local -A want_file=() want_dir=()
  local -a gl=() fp=() fb=() fm=() hl=() ho=()
  VT_BAD=0
  if [ ! -d "$dest" ] || [ -L "$dest" ]; then
    FAIL "target tree $dest is missing or not a directory"; return 1
  fi
  lst="$(mktemp)" || { FAIL "cannot make a temporary file"; return 1; }
  if ! git -C "$dir" ls-tree -r -z --full-tree "$sha" >"$lst" 2>/dev/null; then
    rm -f "$lst"; FAIL "cannot list $sha in $dir"; return 1
  fi
  while IFS= read -r -d '' ent; do
    meta="${ent%%$'\t'*}"; p="${ent#*$'\t'}"
    mode="${meta%% *}"; blob="${meta##* }"
    case "$p" in *$'\n'*) vt_bad "path with a newline in tree $dir at $sha"; continue ;; esac
    d="$p"
    while [[ "$d" == */* ]]; do d="${d%/*}"; want_dir["$d"]=1; done
    case "$mode" in
      100644|100755) want_file["$p"]=1; fp+=("$p"); fb+=("$blob"); fm+=("$mode") ;;
      120000) vt_bad "symlink in tree $p: --tree targets must be symlink-free, as --file" ;;
      160000) want_dir["$p"]=1; gl+=("$p") ;;
      *) vt_bad "tree entry $p has unexpected mode $mode" ;;
    esac
  done <"$lst"
  for i in "${!fp[@]}"; do
    p="${fp[$i]}"
    if [ -L "$dest/$p" ] || [ ! -f "$dest/$p" ]; then
      vt_bad "missing or not a regular file in the target: $p"; continue
    fi
    m="$(stat -c %a "$dest/$p" 2>/dev/null || echo 0)"
    if (( 8#$m & 8#100 )); then bits=100755; else bits=100644; fi
    [ "$bits" = "${fm[$i]}" ] || vt_bad "mode differs from the commit ($bits, want ${fm[$i]}): $p"
    hl+=("$dest/$p")
  done
  if [ "${#hl[@]}" -gt 0 ]; then
    if hout="$(printf '%s\n' "${hl[@]}" | git -C "$dir" hash-object --no-filters --stdin-paths 2>/dev/null)"; then
      mapfile -t ho <<<"$hout"
      nh=0
      for i in "${!fp[@]}"; do
        p="${fp[$i]}"
        if [ -L "$dest/$p" ] || [ ! -f "$dest/$p" ]; then continue; fi
        [ "${ho[$nh]:-}" = "${fb[$i]}" ] || vt_bad "content differs from the commit: $p"
        nh=$((nh + 1))
      done
    else
      vt_bad "git hash-object failed in $dir"
    fi
  fi
  while IFS= read -r -d '' ent; do
    rel="${ent#"$dest"/}"
    if [ -n "${want_file["$rel"]:-}" ]; then continue; fi
    if [ -n "${want_dir["$rel"]:-}" ]; then
      if [ -L "$ent" ] || [ ! -d "$ent" ]; then vt_bad "not a directory in the target: $rel"; fi
      continue
    fi
    for g in "${gl[@]+"${gl[@]}"}"; do
      case "$rel/" in "$g"/*) continue 2 ;; esac
    done
    vt_bad "unexpected entry in the target: $rel"
  done < <(find "$dest" -mindepth 1 -print0)
  for g in "${gl[@]+"${gl[@]}"}"; do
    if [ -L "$dest/$g" ] || [ ! -d "$dest/$g" ]; then vt_bad "gitlink $g is not a directory in the target"; fi
  done
  if [ "$VT_BAD" -gt 0 ]; then
    [ "$VT_BAD" -le 20 ] || FAIL "... and $((VT_BAD - 20)) more"
    # Likely cause: export-ignore or export-subst in the commit's own
    # .gitattributes (git archive honours both).
    git -C "$dir" ls-tree -r -z --name-only --full-tree "$sha" >"$lst" 2>/dev/null
    while IFS= read -r -d '' p; do
      [ "${p##*/}" = .gitattributes ] || continue
      if git -C "$dir" show "$sha:$p" 2>/dev/null | grep -Eq 'export-(ignore|subst)'; then
        FAIL "likely cause: $p in $dir at $sha uses export-ignore or export-subst, which make git archive drop or rewrite files"
      fi
    done <"$lst"
    rm -f "$lst"
    return 1
  fi
  rm -f "$lst"
  return 0
}

cmd_setup() {
  local part="" budget=20 profile=quick sandbox=false venv="" venv_set=false
  local -a extra=() file_args=() tree_args=() selftests=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --budget)  [ $# -ge 2 ] || usage; budget="$2"; shift 2 ;;
      --profile) [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
      --exclude) [ $# -ge 2 ] || usage; extra+=("$2"); shift 2 ;;
      --sandbox) sandbox=true; shift ;;
      --file)    [ $# -ge 2 ] || usage; file_args+=("$2"); shift 2 ;;
      --tree)    [ $# -ge 2 ] || usage; tree_args+=("$2"); shift 2 ;;
      --venv)    [ $# -ge 2 ] || usage; venv="$2"; venv_set=true; shift 2 ;;
      --selftest-cmd) [ $# -ge 2 ] || usage; selftests+=("$2"); shift 2 ;;
      -*) usage ;;
      *) [ -z "$part" ] || usage; part="$1"; shift ;;
    esac
  done
  [ -n "$part" ] || usage
  part="${part%/}"
  case "$part" in /*|..|../*|*/..|*/../*|.|"") echo "FAIL  PART must be a repo-relative directory: $part"; return 1 ;; esac
  if ! run_id_ok "$(basename "$part")"; then
    echo "FAIL  the basename of PART must start with a letter or digit and hold only letters, digits, '.', '_' and '-' (no '..'), or teardown would refuse its run id: $part"; return 1
  fi
  if ! [[ "$budget" =~ ^[0-9]+$ ]] || [ "$budget" -lt 10 ]; then
    echo "FAIL  --budget must be an integer of at least 10 (4 recon, 1 critic, 5 hunters): $budget"; return 1
  fi
  if ! [[ "$profile" =~ ^[a-z]+$ ]]; then echo "FAIL  --profile must be a lowercase word: $profile"; return 1; fi
  [ -d "$ROOT/$part" ] || { echo "FAIL  no such directory under the repo: $part"; return 1; }
  [ -n "$(git -C "$ROOT" ls-files -- "$part" | head -n 1)" ] \
    || { echo "FAIL  $part has no tracked files"; return 1; }
  if [ -n "$(git -C "$ROOT" status --porcelain -- "$part")" ]; then
    echo "FAIL  uncommitted changes under $part; the worktree would not match. Commit or revert them:"
    git -C "$ROOT" status --short -- "$part" | sed 's/^/      /'
    return 1
  fi
  if $venv_set; then
    $sandbox || { echo "FAIL  --venv only means something with --sandbox"; return 1; }
    [ -d "$venv" ] || { echo "FAIL  --venv is not an existing directory: $venv"; return 1; }
    venv="$(abs_dir "$venv")"
  fi
  # --file: every source tracked at HEAD as a regular file and unchanged;
  # every destination relative, clean and unique. Nothing is made yet.
  local -a f_src=() f_dst=() f_mode=()
  local fa fsrc fdst fmode lsl i
  for fa in "${file_args[@]+"${file_args[@]}"}"; do
    fsrc="${fa%%:*}"; fdst=""
    [ "$fsrc" = "$fa" ] || fdst="${fa#*:}"
    fsrc="${fsrc%/}"
    case "$fsrc" in /*|..|../*|*/..|*/../*|.|""|./*|*/./*|*//*) echo "FAIL  --file SRC must be a clean repo-relative path: $fa"; return 1 ;; esac
    [ -n "$fdst" ] || fdst="$(basename "$fsrc")"
    case "$fdst" in /*|"") echo "FAIL  --file DST must be relative and non-empty: $fa"; return 1 ;; esac
    case "/$fdst/" in */../*|*/./*|*//*) echo "FAIL  --file DST must have no '..', '.' or empty segment: $fa"; return 1 ;; esac
    lsl="$(git -C "$ROOT" ls-tree HEAD -- "$fsrc")"
    fmode="${lsl%% *}"
    case "$fmode" in
      100644|100755) ;;
      120000|160000) echo "FAIL  --file $fsrc is mode $fmode at HEAD (symlink or submodule); only regular files"; return 1 ;;
      *) echo "FAIL  --file $fsrc is not tracked at HEAD as a regular file"; return 1 ;;
    esac
    case "$lsl" in *$'
'*) echo "FAIL  --file $fsrc names more than one tree entry"; return 1 ;; esac
    if [ -n "$(git -C "$ROOT" status --porcelain -- "$fsrc")" ]; then
      echo "FAIL  uncommitted changes in $fsrc; the target would not match. Commit or revert them:"
      git -C "$ROOT" status --short -- "$fsrc" | sed 's/^/      /'
      return 1
    fi
    for i in "${!f_dst[@]}"; do
      if [ "${f_dst[$i]}" = "$fdst" ]; then echo "FAIL  --file destination used twice: $fdst"; return 1; fi
      case "${f_dst[$i]}/" in "$fdst"/*) echo "FAIL  --file destination $fdst is a directory on the path of ${f_dst[$i]}"; return 1 ;; esac
      case "$fdst/" in "${f_dst[$i]}"/*) echo "FAIL  --file destination ${f_dst[$i]} is a directory on the path of $fdst"; return 1 ;; esac
    done
    f_src+=("$fsrc"); f_dst+=("$fdst"); f_mode+=("$fmode")
  done
  # --tree: each DIR the top level of its own git work tree, REV resolved,
  # HEAD checkouts clean, DST clean and unique, nesting only on a matching
  # gitlink. Nothing is made yet.
  local -a t_dir=() t_sha=() t_dst=() t_abs=() t_order=()
  local ta tdir trev tdst tabs ttop rootp tsha tmode tj tp tpl trel tent tcommit
  if [ "${#tree_args[@]}" -gt 0 ] && [ "${#file_args[@]}" -gt 0 ]; then
    echo "FAIL  --tree and --file are mutually exclusive"; return 1
  fi
  rootp="$(cd "$ROOT" && pwd -P)"
  for ta in "${tree_args[@]+"${tree_args[@]}"}"; do
    tdst=""; tdir="$ta"
    if [[ "$ta" == *:* ]]; then tdst="${ta#*:}"; tdir="${ta%%:*}"; fi
    trev=HEAD
    if [[ "$tdir" == *@* ]]; then trev="${tdir#*@}"; tdir="${tdir%%@*}"; fi
    tdir="${tdir%/}"
    case "$tdir" in /*|..|../*|*/..|*/../*|.|""|./*|*/./*|*//*) echo "FAIL  --tree DIR must be a clean repo-relative path: $ta"; return 1 ;; esac
    case "$trev" in ""|-*) echo "FAIL  --tree REV must be non-empty and not start with '-': $ta"; return 1 ;; esac
    [ -n "$tdst" ] || [[ "$ta" != *:* ]] || { echo "FAIL  --tree DST must be non-empty: $ta"; return 1; }
    [ -n "$tdst" ] || tdst="$(basename "$tdir")"
    case "$tdst" in /*|"") echo "FAIL  --tree DST must be relative and non-empty: $ta"; return 1 ;; esac
    case "/$tdst/" in */../*|*/./*|*//*) echo "FAIL  --tree DST must have no '..', '.' or empty segment: $ta"; return 1 ;; esac
    [ -d "$ROOT/$tdir" ] || { echo "FAIL  --tree $tdir is not a directory under the repo"; return 1; }
    [ ! -L "$ROOT/$tdir" ] || { echo "FAIL  --tree $tdir is a symlink"; return 1; }
    tabs="$(cd "$ROOT/$tdir" && pwd -P)" || return 1
    [ "$tabs" != "$rootp" ] || { echo "FAIL  --tree $tdir is this repository itself"; return 1; }
    ttop="$(git -C "$ROOT/$tdir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$ttop" != "$tabs" ]; then
      echo "FAIL  --tree $tdir is not the top level of its own git work tree (toplevel: ${ttop:-none})"; return 1
    fi
    tsha="$(git -C "$tabs" rev-parse --verify "$trev^{commit}" 2>/dev/null)" \
      || { echo "FAIL  --tree $tdir: cannot resolve REV to a commit: $trev"; return 1; }
    if [ "$trev" = HEAD ] && [ -n "$(git -C "$tabs" status --porcelain 2>/dev/null)" ]; then
      echo "FAIL  uncommitted changes in $tdir; the target would not match its HEAD. Commit, revert, or name a REV:"
      git -C "$tabs" status --short | head -n 10 | sed 's/^/      /'
      return 1
    fi
    for i in "${!t_dst[@]}"; do
      if [ "${t_dst[$i]}" = "$tdst" ]; then echo "FAIL  --tree destination used twice: $tdst"; return 1; fi
    done
    t_dir+=("$tdir"); t_sha+=("$tsha"); t_dst+=("$tdst"); t_abs+=("$tabs")
  done
  if [ "${#t_dir[@]}" -gt 0 ]; then
    mapfile -t t_order < <(for i in "${!t_dst[@]}"; do printf '%s %s\n' "${#t_dst[$i]}" "$i"; done | sort -n -s | awk '{print $2}')
    # An inner destination lies inside its nearest outer one only on a gitlink
    # of the outer commit that names the inner commit.
    for tj in "${!t_dst[@]}"; do
      tp=""; tpl=-1
      for i in "${!t_dst[@]}"; do
        case "${t_dst[$tj]}/" in "${t_dst[$i]}"/*)
          if [ "$i" != "$tj" ] && [ "${#t_dst[$i]}" -gt "$tpl" ]; then tp="$i"; tpl="${#t_dst[$i]}"; fi ;;
        esac
      done
      [ -n "$tp" ] || continue
      trel="${t_dst[$tj]#"${t_dst[$tp]}"/}"
      tent="$(git -C "${t_abs[$tp]}" ls-tree "${t_sha[$tp]}" -- "$trel" | head -n 1)"
      tmode="${tent%% *}"
      if [ "$tmode" != 160000 ]; then
        echo "FAIL  --tree ${t_dir[$tj]}: destination ${t_dst[$tj]} lies inside ${t_dst[$tp]} but $trel is not a gitlink in ${t_dir[$tp]} at ${t_sha[$tp]}"
        return 1
      fi
      tcommit="$(printf '%s\n' "${tent%%$'\t'*}" | awk '{print $3}')"
      if [ "$tcommit" != "${t_sha[$tj]}" ]; then
        echo "FAIL  --tree ${t_dir[$tj]}: $trel in ${t_dir[$tp]} at ${t_sha[$tp]} is gitlink commit $tcommit; the inner tree resolves to ${t_sha[$tj]}. Use ${t_dir[$tj]}@$tcommit"
        return 1
      fi
    done
  fi
  if [ -e "$SKILL_DST" ]; then
    echo "FAIL  $SKILL_DST already exists; the skill is never left installed. Run teardown for the run that put it there."
    return 1
  fi
  [ -f "$SKILL_SRC/SKILL.md" ] || { echo "FAIL  vendored skill missing at $SKILL_SRC"; return 1; }
  if [ -z "$(git -C "$ROOT" ls-files -- tools/security-audit-skill)" ]; then
    echo "FAIL  tools/security-audit-skill has no tracked files (a gitignored copy passes the status check); skill_commit would not describe the copy. Commit it first."
    return 1
  fi
  if [ -n "$(git -C "$ROOT" status --porcelain -- tools/security-audit-skill)" ]; then
    echo "FAIL  uncommitted changes in tools/security-audit-skill; skill_commit would not describe the copy. Commit or revert them:"
    git -C "$ROOT" status --short -- tools/security-audit-skill | sed 's/^/      /'
    return 1
  fi
  # --sandbox is a claim the selfcheck must back: every control exercised now.
  if $sandbox; then
    local sc_out
    if ! sc_out="$("$SANDBOX" selfcheck 2>&1)"; then
      echo "FAIL  --sandbox given but tools/security-audit-sandbox.sh selfcheck failed; no run made:"
      printf '%s\n' "$sc_out" | grep -E '^FAIL' | sed 's/^/      /'
      return 1
    fi
  fi

  local ref base date n run_id RUN
  ref="$(git -C "$ROOT" rev-parse HEAD)" || return 1
  base="$(basename "$part")"
  date="$(date -u +%Y-%m-%d)"
  mkdir -p "$CACHE" || return 1
  n=1
  while [ -e "$CACHE/$base-$date-$n" ]; do n=$((n + 1)); done
  run_id="$base-$date-$n"
  RUN="$CACHE/$run_id"
  mkdir "$RUN" || return 1

  # Everything from here is _setup_build, which sees this function's locals.
  # If it fails, what this setup made is removed: the worktree, the run
  # directory and the skill copy if it installed one.
  local skill_installed=false
  _setup_build() {
  if ! git -C "$ROOT" worktree add --detach "$RUN/worktree" HEAD >/dev/null 2>&1; then
    echo "FAIL  git worktree add failed"; return 1
  fi
  if [ ! -d "$RUN/worktree/$part" ]; then
    echo "FAIL  $part is not in the worktree at HEAD ($ref)"; return 1
  fi
  local target_dir="$RUN/worktree/$part" files_json="[]"
  if [ "${#f_src[@]}" -gt 0 ]; then
    target_dir="$RUN/target/$base"
    mkdir -p "$target_dir" || return 1
    local k dpath
    for k in "${!f_src[@]}"; do
      if [ -L "$RUN/worktree/${f_src[$k]}" ] || [ ! -f "$RUN/worktree/${f_src[$k]}" ]; then
        echo "FAIL  ${f_src[$k]} is not a regular file in the worktree"; return 1
      fi
      dpath="$target_dir/${f_dst[$k]}"
      if ! { mkdir -p "$(dirname "$dpath")" && cp "$RUN/worktree/${f_src[$k]}" "$dpath"; }; then
        echo "FAIL  copying ${f_src[$k]}"; return 1
      fi
      if [ "${f_mode[$k]}" = 100755 ]; then chmod 0755 "$dpath"; else chmod 0644 "$dpath"; fi
      if ! cmp -s "$dpath" <(git -C "$ROOT" show "HEAD:${f_src[$k]}"); then
        echo "FAIL  ${f_dst[$k]} is not byte-identical to HEAD:${f_src[$k]}"; return 1
      fi
    done
    files_json="$(for k in "${!f_src[@]}"; do
      jq -n --arg s "${f_src[$k]}" --arg d "${f_dst[$k]}" --arg m "${f_mode[$k]}" '{src: $s, dst: $d, mode: $m}'
    done | jq -s '.')" || { echo "FAIL  building target_files"; return 1; }
  fi
  local trees_json="[]"
  if [ "${#t_dir[@]}" -gt 0 ]; then
    target_dir="$RUN/target/$base"
    mkdir -p "$target_dir" || return 1
    local tk o ent meta gpath gsha gcov trem
    for tk in "${t_order[@]}"; do
      if ! mat_tree "${t_abs[$tk]}" "${t_sha[$tk]}" "$target_dir/${t_dst[$tk]}"; then
        echo "FAIL  git archive of ${t_dir[$tk]} at ${t_sha[$tk]}"; return 1
      fi
      verify_tree "${t_abs[$tk]}" "${t_sha[$tk]}" "$target_dir/${t_dst[$tk]}" || return 1
    done
    trees_json="$(for tk in "${t_order[@]}"; do
      trem="$(owner_repo "$(git -C "${t_abs[$tk]}" remote get-url origin 2>/dev/null || true)")"
      glj="$(git -C "${t_abs[$tk]}" ls-tree -r -z "${t_sha[$tk]}" | while IFS= read -r -d '' ent; do
        meta="${ent%%$'\t'*}"; gpath="${ent#*$'\t'}"
        case "$meta" in 160000\ *) ;; *) continue ;; esac
        gsha="$(printf '%s\n' "$meta" | awk '{print $3}')"
        gcov=false
        for o in "${!t_dst[@]}"; do
          [ "${t_dst[$o]}" = "${t_dst[$tk]}/$gpath" ] && gcov=true
        done
        jq -n --arg p "$gpath" --arg c "$gsha" --argjson v "$gcov" '{path: $p, commit: $c, covered: $v}'
      done | jq -s '.')"
      jq -n --arg d "${t_dir[$tk]}" --arg r "$trem" --arg c "${t_sha[$tk]}" --arg s "${t_dst[$tk]}" --argjson g "${glj:-[]}" \
        '{dir: $d, remote: $r, commit: $c, dst: $s, gitlinks: $g}'
    done | jq -s '.')" || { echo "FAIL  building target_trees"; return 1; }
  fi
  mkdir -p "$RUN/out/agents" "$RUN/out/recon" "$RUN/out/briefs" || return 1

  # Repo name: the remote's owner/repo, else the checkout's directory name.
  local remote repo
  remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  repo=""
  if [ "${#t_dir[@]}" -gt 0 ]; then
    repo="$(jq -r '.[0].remote' <<<"$trees_json")"
    [ -n "$repo" ] || repo="$(basename "${t_dir[${t_order[0]}]}")"
  else
    [ -z "$remote" ] || repo="$(owner_repo "$remote")"
    [ -n "$repo" ] || repo="$(basename "$ROOT")"
  fi

  # Excluded paths, relative to PART: the standard list, any tracked
  # static/vendor/ or static/fonts/, then --exclude.
  local std vend extras_nl lsf
  std=$'missions/\nexamples/\nfixtures/\ncache/\n__pycache__/'
  vend="$(git -C "$ROOT" ls-files -- "$part" \
    | while IFS= read -r lsf; do printf '%s\n' "${lsf#"$part"/}"; done \
    | sed -nE 's#^((.*/)?static/(vendor|fonts)/).*#\1#p' | sort -u)"
  extras_nl="$(printf '%s\n' "${extra[@]+"${extra[@]}"}")"

  local prior_nl="" d
  for d in "$ROOT/$part"/docs/security-audit-*; do
    [ -d "$d" ] && prior_nl+="${d#"$ROOT/"}"$'\n'
  done
  prior_nl="$(printf '%s' "$prior_nl" | sort)"

  local note defaults sbcmd=""
  if $sandbox; then
    sbcmd="$SANDBOX run --target {TARGET} --scratch {SCRATCH}"
    # With a venv its python is first on PATH; without one the sandbox has no
    # `python`, only /usr/bin/python3.
    local py="/usr/bin/python3 -I"
    # The string is pasted into a shell: every path is shell-quoted (%q).
    if $venv_set; then sbcmd+=" --venv $(printf '%q' "$venv")"; py=python
    elif [ -d "$ROOT/$part/.venv" ]; then sbcmd+=" --venv $(printf '%q' "$ROOT/$part/.venv")"; py=python; fi
    sbcmd+=" --env PYTHONPATH={TARGET}"
    if [ "${#f_src[@]}" -eq 0 ] && [ "${#t_dir[@]}" -eq 0 ]; then
      # The part's data directory variable: FOO_DATA for a part named foo, ...
      local datavar; datavar="$(basename "$part" | tr '[:lower:]-' '[:upper:]_')_DATA"
      sbcmd+=" --env $(printf '%q' "$datavar")={SCRATCH}/sandbox/data"
    fi
    sbcmd+=" -- $py {SCRATCH}/harness.py"
    defaults="$("$SANDBOX" defaults)"
    note="OS-enforced sandbox: tools/security-audit-sandbox.sh run --target DIR --scratch AGENT/scratch [--venv DIR] [--env NAME=VALUE]... -- CMD (bwrap: no network but an isolated lo, an environment of HOME/TMPDIR/XDG_*/PYTHONPYCACHEPREFIX under AGENT/scratch/sandbox plus PATH, LANG, PWD and the --env pairs, target, venv, scratch, /usr and listed /etc files read-only, one tmpfs at AGENT/scratch/sandbox the only writable place and not kept after the run; systemd-run --user scope: memory without swap, CPU, tasks, wall clock; prlimit: file size). Defaults $defaults; stdout and stderr each capped. Its selfcheck passed at setup, $(date -u +%Y-%m-%dT%H:%MZ). Target writes do not persist: retain evidence from stdout, and promote only with tools/security-audit-promote.py"
  else
    note="no OS-enforced sandbox on this run; no target code runs, so every local check is blocked and candidates stop at needs_validation"
  fi

  jq -n \
    --arg run_id "$run_id" --arg repo "$repo" --arg part "$part" \
    --arg target "$target_dir" --arg worktree "$RUN/worktree" --arg ref "$ref" --arg profile "$profile" \
    --arg std "$std" --arg vend "$vend" --arg extras "$extras_nl" --arg prior "$prior_nl" \
    --argjson budget "$budget" --argjson sandbox "$sandbox" --arg note "$note" \
    --arg skill_dir "$SKILL_DST" --arg skill_commit "$SKILL_COMMIT" --arg sbcmd "$sbcmd" \
    --argjson tfiles "$files_json" --argjson ttrees "$trees_json" \
    --argjson selftests "$(printf '%s\n' "${selftests[@]+"${selftests[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" '
    def lines: split("\n") | map(select(length > 0));
    {
      run_id: $run_id,
      repo: $repo,
      part: $part,
      target: $target,
      worktree: $worktree,
      target_note: (if ($ttrees | length) > 0
                    then "git archive of each --tree checkout at its commit (submodule contents only where another --tree fills them); not a git checkout"
                    elif ($tfiles | length) > 0
                    then "files named by --file, copied from the detached worktree at the reviewed commit (the published tree); not a git checkout"
                    else "detached git worktree at the reviewed commit; the target is the part, not the repository root" end),
      source_ref: (if ($ttrees | length) > 0 then $ttrees[0].commit else $ref end),
      worktree_ref: $ref,
      worktree_dirty: false,
      profile: $profile,
      scope_paths: ([$part] + ($tfiles | map(.src)) + ($ttrees | map(.dir))),
      excluded_paths: (($std | lines) + ($vend | lines) + ($extras | lines)),
      excluded_methods: (["git history", "dependency CVE lookup", "deployed-endpoint probing", "WebFetch", "WebSearch"]
                         + (if $sandbox then [] else ["any target execution"] end)),
      budget: $budget,
      budget_plan: (if $profile == "quick"
                    then {reconnaissance: 4, post_wave_critic: 1, hunters_max: 5, verifier_reserve: ($budget - 10)}
                    else {reconnaissance: 4, critics_reserved: 2, verifier_reserve: null, note: "parent fills from the seeded ledger"} end),
      invocations_spent: 0,
      invocation_log: [],
      execution_policy: "sandboxed-source-and-local-only",
      sandbox_available: $sandbox,
      sandbox_note: $note
    } + (if $sandbox then {
      sandbox_command: $sbcmd,
      promotion_allowlist: ["harness.py", "harness-output.txt", "evidence.txt"],
      promotion_byte_limits: {per_file: 1048576, cumulative: 4194304}
    } else {} end)
    + (if ($tfiles | length) > 0 then {target_files: $tfiles} else {} end)
    + (if ($ttrees | length) > 0 then {checkout_ref: $ref, target_trees: $ttrees} else {} end)
    + (if ($selftests | length) > 0 then {selftest_commands: $selftests} else {} end) + {
      agent_role_mapping: {research: "Explore", general: "general-purpose model sonnet"},
      selected_companion_files: [],
      prior_runs: ($prior | lines),
      shared_file_owners: {
        "run-metadata.json": "parent", "architecture.md": "parent",
        "coverage-ledger.json": "parent", "findings.json": "parent",
        "REPORT.md": "parent", "FINDINGS-DETAIL.md": "parent",
        "NEEDS-VALIDATION.md": "parent"
      },
      skill_dir: $skill_dir,
      skill_commit: $skill_commit,
      run_status: "in_progress"
    }' >"$RUN/out/run-metadata.json" || { echo "FAIL  writing run-metadata.json"; return 1; }

  # The skill goes in last: a failure above never leaves an ambient grant.
  skill_installed=true
  if ! { mkdir -p "$(dirname "$SKILL_DST")" && cp -a "$SKILL_SRC" "$SKILL_DST"; }; then
    echo "FAIL  copying the skill"; return 1
  fi

  echo "RUN=$RUN"
  echo "TARGET=$target_dir"
  echo "OUT=$RUN/out"
  echo "SKILL=$SKILL_DST"
  }
  if ! _setup_build; then
    git -C "$ROOT" worktree remove --force "$RUN/worktree" >/dev/null 2>&1
    rm -rf "$RUN/worktree"
    git -C "$ROOT" worktree prune
    if $skill_installed; then rm -rf "$SKILL_DST"; fi
    rm -rf "$RUN"
    echo "FAIL  setup failed; removed what it made ($RUN)"
    return 1
  fi
  return 0
}

cmd_validate() {
  local out
  [ $# -eq 1 ] || usage
  out="$1"
  [ -d "$out" ] || { FAIL "no such output directory: $out"; return 1; }
  [ -f "$SKILL_SRC/validate-findings.cjs" ] || { FAIL "validators missing at $SKILL_SRC"; return 1; }
  if [ -f "$out/findings.json" ]; then
    if node "$SKILL_SRC/validate-findings.cjs" "$out/findings.json"; then OK "findings.json validates"
    else FAIL "findings.json does not validate"; fi
  else
    SKIP "no findings.json yet"
  fi
  if [ -f "$out/coverage-ledger.json" ]; then
    if node "$SKILL_SRC/validate-coverage-ledger.cjs" "$out/coverage-ledger.json"; then OK "coverage-ledger.json validates"
    else FAIL "coverage-ledger.json does not validate"; fi
    echo "ledger units by status:"
    jq -r 'if type == "array" then group_by(.status) | map("  \(.[0].status // "null")  \(length)") | .[] else "  (not an array)" end' \
      "$out/coverage-ledger.json" 2>/dev/null || echo "  (unreadable)"
  else
    FAIL "no coverage-ledger.json in $out"
  fi
  if [ -f "$out/findings.json" ]; then
    echo "findings by verdict:"
    jq -r 'if type == "array" then group_by(.verdict) | map("  \(.[0].verdict // "null")  \(length)") | .[] else "  (not an array)" end' \
      "$out/findings.json" 2>/dev/null || echo "  (unreadable)"
  fi
  return "$fail"
}

# grep_out OUT RE: print "file<TAB>line<TAB>text" (file relative to OUT) for
# every line of every file under OUT except OUT/briefs matching the ERE RE.
# Files are read as text (-a, C locale), so a NUL byte does not hide a line.
# Returns grep's status over all files: 0 if some line matched, 1 if none,
# 2 if any grep failed (a bad regex, an unreadable file) or find failed (a
# directory it could not list). Callers treat 2 as
# "scan failed".
grep_out() {
  local out="$1" re="$2" f rc=1 gs fl fs
  # The list goes to a file so find's status is not lost: a directory it
  # cannot read, or any other find error, makes the scan fail (2).
  fl="$(mktemp)" || return 2
  find "$out" -path "$out/briefs" -prune -o -type f -print0 >"$fl" 2>/dev/null; fs=$?
  [ "$fs" -eq 0 ] || rc=2
  while IFS= read -r -d '' f; do
    LC_ALL=C grep -anE -e "$re" -- "$f" 2>/dev/null \
      | tr -d '\0' \
      | F="${f#"$out"/}" LC_ALL=C awk '{ i = index($0, ":"); printf "%s\t%s\t%s\n", ENVIRON["F"], substr($0, 1, i - 1), substr($0, i + 1) }'
    gs="${PIPESTATUS[0]}"
    if [ "$gs" -ge 2 ]; then rc=2
    elif [ "$gs" -eq 0 ] && [ "$rc" -eq 1 ]; then rc=0; fi
  done <"$fl"
  rm -f "$fl"
  return "$rc"
}

# loc_only: stdin "file<TAB>line<TAB>text" lines, stdout "file:line". A hit
# never carries its text, so a value never reaches the transcript.
loc_only() { cut -f1,2 | tr '\t' ':' | sort -u | cut -c1-200 | sed 's/^/      /'; }

# safe_rel P: P is a relative path with no `..`, `.` or empty segment and no
# leading `-`.
safe_rel() {
  case "$1" in ""|/*|-*) return 1 ;; esac
  case "/$1/" in */../*|*/./*|*//*) return 1 ;; esac
  return 0
}

# mode_bits FILE: 100755 if the owner exec bit is set, else 100644.
mode_bits() {
  local m
  m="$(stat -c %a "$1" 2>/dev/null || echo 0)"
  if (( 8#$m & 8#100 )); then echo 100755; else echo 100644; fi
}

cmd_check() {
  local out="" values="" values_set=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --values) [ $# -ge 2 ] || usage; values="$2"; values_set=true; shift 2 ;;
      -*) usage ;;
      *) [ -z "$out" ] || usage; out="$1"; shift ;;
    esac
  done
  [ -n "$out" ] || usage
  [ -d "$out" ] || { FAIL "no such output directory: $out"; return 1; }
  out="$(abs_dir "$out")"

  # (a) the source is untouched. This checkout is judged under the part
  # only: other sessions leave their own edits elsewhere in it.
  local gst=0 part="" target="" st wt="" sref="" wref="" tfiles="" ttrees="" meta_ok=false mf="$out/run-metadata.json"
  local -a paths=()
  if [ ! -f "$mf" ]; then
    FAIL "run-metadata.json is missing from $out; the target and the worktree cannot be checked"
  elif ! jq -e 'type == "object"' "$mf" >/dev/null 2>&1; then
    FAIL "run-metadata.json does not parse as a JSON object"
  else
    meta_ok=true
  fi
  if $meta_ok; then
    part="$(jq -r '.part // empty' "$mf" 2>/dev/null)"
    target="$(jq -r '.target // empty' "$mf" 2>/dev/null)"
    wt="$(jq -r '.worktree // .target // empty' "$mf" 2>/dev/null)"
    sref="$(jq -r '.source_ref // empty' "$mf" 2>/dev/null)"
    wref="$(jq -r '.worktree_ref // .checkout_ref // .source_ref // empty' "$mf" 2>/dev/null)"
    tfiles="$(jq -r '(.target_files // []) | .[] | [.src, .dst] | @tsv' "$mf" 2>/dev/null)"
    ttrees="$(jq -r '(.target_trees // []) | .[] | [(.dst | length), .dir, .commit, .dst] | @tsv' "$mf" 2>/dev/null | sort -t $'\t' -k1,1n -s | cut -f2-)"
    if ! [[ "$sref" =~ ^[0-9a-f]{40}$ ]]; then
      FAIL "source_ref is not a 40-hex commit id: ${sref:-(empty)}"; sref=""
    fi
    local v_s v_d v_c v_bad=0
    if [ -n "$tfiles" ]; then
      while IFS=$'\t' read -r v_s v_d; do
        safe_rel "$v_d" || { FAIL "target_files dst is not a clean relative path (no .., no leading -): $v_d"; v_bad=1; }
      done <<<"$tfiles"
      [ "$v_bad" -eq 0 ] || tfiles=""
    fi
    v_bad=0
    if [ -n "$ttrees" ]; then
      while IFS=$'\t' read -r v_d v_c v_s; do
        safe_rel "$v_s" || { FAIL "target_trees dst is not a clean relative path (no .., no leading -): $v_s"; v_bad=1; }
        safe_rel "$v_d" || { FAIL "target_trees dir is not a clean relative path: $v_d"; v_bad=1; }
        [[ "$v_c" =~ ^[0-9a-f]{40}$ ]] || { FAIL "target_trees commit is not a 40-hex commit id for $v_d: $v_c"; v_bad=1; }
      done <<<"$ttrees"
      [ "$v_bad" -eq 0 ] || ttrees=""
    fi
  fi
  if [ -n "$part" ]; then
    paths=("$part")
    if [ -n "$tfiles" ]; then
      local tf_s tf_d
      while IFS=$'\t' read -r tf_s tf_d; do paths+=("$tf_s"); done <<<"$tfiles"
    fi
    st="$(git -C "$ROOT" status --short -- "${paths[@]}" 2>&1)"; gst=$?
  else st="$(git -C "$ROOT" status --short 2>&1)"; gst=$?; fi
  if [ "$gst" -ne 0 ]; then FAIL "git status failed in the checkout (exit $gst); it cannot be judged clean: ${st%%$'\n'*}"
  elif [ -z "$st" ]; then OK "checkout clean${part:+ under $part${tfiles:+ and the target files}}"
  else FAIL "checkout has changes${part:+ under $part}:"; printf '      %s\n' "${st//$'\n'/$'\n'      }"; fi
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    # Plain part: the worktree is the target, so ignored files count too.
    local -a wst=(status --short)
    [ -n "$tfiles$ttrees" ] || wst+=(--ignored --untracked-files=all)
    if st="$(git -C "$wt" "${wst[@]}" 2>&1)"; then
      if [ -z "$st" ]; then OK "run worktree clean"
      else FAIL "run worktree has changes:"; printf '      %s\n' "${st//$'\n'/$'\n'      }"; fi
      # And at the commit setup made it at (worktree_ref; checkout_ref in
      # --tree runs; source_ref in older metadata).
      if [ -z "$(jq -r '.worktree // empty' "$mf" 2>/dev/null)" ]; then :
      elif [[ "$wref" =~ ^[0-9a-f]{40}$ ]]; then
        local whead
        if ! whead="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; then
          FAIL "cannot read the run worktree's HEAD: $wt"
        elif [ "$whead" != "$wref" ]; then
          FAIL "run worktree HEAD is $whead; it was made at $wref (a commit or reset was made in it)"
        else OK "run worktree HEAD is the commit it was made at"; fi
      else
        FAIL "run-metadata.json names no valid commit for the run worktree: ${wref:-(empty)}"
      fi
    else
      FAIL "run worktree is not a git repository (git status failed): $wt"
    fi
  else
    SKIP "no run worktree named in run-metadata.json"
  fi
  # The file target: each file present, regular, equal to `git show` of the
  # reviewed commit and with its exec bit; nothing else under it.
  if [ -n "$tfiles" ]; then
    local tf_s tf_d tbad=0 ent ok_ent d2 lsl fmode bits expf
    if [ -z "$target" ] || [ ! -d "$target" ]; then
      FAIL "target directory missing: $target"; tbad=1
    elif [ -z "$wt" ] || [ -z "$sref" ]; then
      FAIL "run-metadata.json lacks worktree or a valid source_ref; cannot compare the target files"; tbad=1
    elif ! expf="$(mktemp)"; then
      FAIL "cannot make a temporary file"; tbad=1
    else
      while IFS=$'\t' read -r tf_s tf_d; do
        if [ -L "$target/$tf_d" ] || [ ! -f "$target/$tf_d" ]; then
          FAIL "target file $tf_d is missing or not a regular file"; tbad=1
        elif ! lsl="$(git -C "$wt" ls-tree "$sref" -- "$tf_s" 2>/dev/null)" || [ -z "$lsl" ]; then
          FAIL "cannot read $tf_s at $sref in the run worktree"; tbad=1
        elif ! git -C "$wt" show "$sref:$tf_s" >"$expf" 2>/dev/null; then
          FAIL "git show $sref:$tf_s failed; cannot compare $tf_d"; tbad=1
        elif ! cmp -s "$target/$tf_d" "$expf"; then
          FAIL "target file $tf_d differs from $sref:$tf_s"; tbad=1
        else
          fmode="${lsl%% *}"; bits="$(mode_bits "$target/$tf_d")"
          if [ "$bits" != "$fmode" ]; then
            FAIL "target file $tf_d has mode $bits; $sref:$tf_s is $fmode"; tbad=1
          fi
        fi
      done <<<"$tfiles"
      rm -f "$expf"
      while IFS= read -r -d '' ent; do
        ok_ent=false
        d2="${ent#"$target"/}"
        while IFS=$'\t' read -r tf_s tf_d; do
          if [ "$tf_d" = "$d2" ] && [ -f "$ent" ] && [ ! -L "$ent" ]; then ok_ent=true; fi
          if [ -d "$ent" ] && [ ! -L "$ent" ]; then case "$tf_d" in "$d2"/*) ok_ent=true ;; esac; fi
        done <<<"$tfiles"
        $ok_ent || { FAIL "unexpected entry under the target: $d2"; tbad=1; }
      done < <(find "$target" -mindepth 1 -print0)
    fi
    [ "$tbad" -eq 0 ] && OK "target files present, regular, byte-identical to $sref with the commit's modes; nothing else under the target"
  fi

  # The tree target: each tree verified against `git ls-tree -r` of its own
  # commit and its own dst (outer trees first; a gitlink directory's contents
  # belong to the inner tree). Not a rebuild, so independent of git archive.
  if [ -n "$ttrees" ]; then
    local tt_d tt_c tt_s tbad2=0
    if [ -z "$target" ] || [ ! -d "$target" ]; then
      FAIL "target directory missing: $target"; tbad2=1
    else
      while IFS=$'\t' read -r tt_d tt_c tt_s; do
        if ! git -C "$ROOT/$tt_d" cat-file -e "$tt_c^{commit}" 2>/dev/null; then
          FAIL "tree $tt_d has no commit $tt_c"; tbad2=1
        elif ! verify_tree "$ROOT/$tt_d" "$tt_c" "$target/$tt_s"; then
          tbad2=1
        fi
      done <<<"$ttrees"
    fi
    [ "$tbad2" -eq 0 ] && OK "target trees match their commits (ls-tree: files, hashes, modes, nothing extra, no symlinks)"
  fi

  # (b) no coordinates in anything that could leave this machine. First, nothing
  # under OUT may be other than a regular file or a directory (briefs/ and
  # agents/*/scratch/ are not scanned for this).
  local hits n=0 rc text hf hn bad_t=0 ent hits_l tl ts
  if ! tl="$(mktemp)"; then
    FAIL "cannot make a temporary file for the type scan"; bad_t=1; tl=/dev/null
  fi
  find "$out" -mindepth 1 \( -path "$out/briefs" -o -path "$out/agents/*/scratch" \) -prune -o ! -type f ! -type d -print0 >"$tl" 2>/dev/null; ts=$?
  if [ "$ts" -ne 0 ]; then
    FAIL "the type scan could not list every directory under OUT (find exit $ts); unreadable files were never judged"; bad_t=1
  fi
  while IFS= read -r -d '' ent; do
    FAIL "not a regular file or directory under OUT (never scanned, never landed): ${ent#"$out"/}"; bad_t=1
  done <"$tl"
  [ "$tl" = /dev/null ] || rm -f "$tl"
  [ "$bad_t" -eq 0 ] && OK "only regular files and directories under OUT"

  hits="$(grep_out "$out" '"(lat|lon|lng|latitude|longitude)"[[:space:]]*:[[:space:]]*-?[0-9]')"; rc=$?
  if [ "$rc" -ge 2 ]; then FAIL "scan failed (grep status $rc): JSON coordinate fields"
  elif [ -n "$hits" ]; then
    FAIL "JSON coordinate fields with a number (file:line):"
    printf '%s\n' "$hits" | loc_only
  else OK "no JSON coordinate fields"; fi

  # A line naming lat/lon/lng as a word (an underscore or digit counts as a
  # break, so lat_deg matches and "relative" does not) that still holds a
  # decimal of three or more places once versions and file:line are removed.
  hits="$(grep_out "$out" '(^|[^A-Za-z])([Ll][Aa][Tt]|[Ll][Oo][Nn]|[Ll][Nn][Gg]|[Ll][Aa][Tt][Ii][Tt][Uu][Dd][Ee]|[Ll][Oo][Nn][Gg][Ii][Tt][Uu][Dd][Ee])([^A-Za-z]|$)')"; rc=$?
  if [ "$rc" -ge 2 ]; then
    FAIL "scan failed (grep status $rc): lat/lon lines"
  else
    hits_l=""
    while IFS=$'\t' read -r hf hn text; do
      [ -n "$hf" ] || continue
      text="$(printf '%s\n' "$text" | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+//g; s/\.[A-Za-z]+:[0-9]+//g')"
      if printf '%s\n' "$text" | grep -qE -- '-?[0-9]{1,3}\.[0-9]{3,}'; then
        hits_l+="$hf:$hn"$'\n'; n=$((n + 1))
      fi
    done <<<"$hits"
    if [ "$n" -gt 0 ]; then
      FAIL "$n line(s) name lat/lon/lng beside a long decimal (file:line):"
      printf '%s' "$hits_l" | cut -c1-200 | sed 's/^/      /'
    else OK "no lat/lon line with a long decimal"; fi
  fi

  if $values_set; then
    if [ -z "$values" ]; then
      FAIL "invalid --values regex: empty"
    else
      LC_ALL=C grep -E -e "$values" </dev/null >/dev/null 2>&1; rc=$?
      if [ "$rc" -ge 2 ]; then
        FAIL "invalid --values regex (grep status $rc)"
      else
        hits="$(grep_out "$out" "$values")"; rc=$?
        if [ "$rc" -ge 2 ]; then FAIL "scan failed (grep status $rc): --values"
        elif [ -n "$hits" ]; then
          FAIL "lines matching --values (file:line):"
          printf '%s\n' "$hits" | loc_only
        else OK "no line matches --values"; fi
      fi
    fi
  fi

  # (c) the validators.
  echo "validators:"
  cmd_validate "$out" || fail=1
  return "$fail"
}

# reg_file PATH: a regular file and not a symlink.
reg_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

cmd_land() {
  local out="" dest="" values_arg=() f d id count=0 bad=0 a
  while [ $# -gt 0 ]; do
    case "$1" in
      --values) [ $# -ge 2 ] || usage; values_arg=(--values "$2"); shift 2 ;;
      -*) usage ;;
      *) if [ -z "$out" ]; then out="$1"; elif [ -z "$dest" ]; then dest="$1"; else usage; fi; shift ;;
    esac
  done
  if [ -z "$out" ] || [ -z "$dest" ]; then usage; fi
  local -a fixed=(REPORT.md NEEDS-VALIDATION.md FINDINGS-DETAIL.md findings.json coverage-ledger.json
                  run-metadata.json architecture.md critic-final.json hardening.md candidates.json
                  uncovered-from-hunters.json record-verifiers.json phase5-log.json
                  hardening-by-hunter.json)
  [ -d "$out" ] || { FAIL "no such output directory: $out"; return 1; }
  out="$(abs_dir "$out")"
  case "$dest" in /*) ;; *) dest="$ROOT/$dest" ;; esac
  [ ! -e "$dest" ] || { FAIL "$dest already exists; land never overwrites"; return 1; }

  # Pre-pass: every source a regular file that is not a symlink, every
  # directory a real directory. Nothing is copied unless all pass.
  for f in "${fixed[@]}" "$out"/critic-wave-*.json; do
    f="${f#"$out"/}"
    if [ -e "$out/$f" ] || [ -L "$out/$f" ]; then
      reg_file "$out/$f" || { FAIL "land: $f is not a regular file (a symlink or other); fix or remove it"; bad=1; }
    fi
  done
  for d in recon agents; do
    if [ -e "$out/$d" ] || [ -L "$out/$d" ]; then
      if [ -L "$out/$d" ] || [ ! -d "$out/$d" ]; then FAIL "land: $d/ is not a real directory"; bad=1; fi
    fi
  done
  if [ -d "$out/recon" ] && [ ! -L "$out/recon" ]; then
    for f in "$out"/recon/*.md; do
      reg_file "$f" || { FAIL "land: recon/${f##*/} is not a regular file"; bad=1; }
    done
  fi
  if [ -d "$out/agents" ] && [ ! -L "$out/agents" ]; then
    for d in "$out"/agents/*; do
      id="${d##*/}"
      if [ -L "$d" ]; then FAIL "land: agents/$id is a symlink"; bad=1; continue; fi
      [ -d "$d" ] || continue
      if [ -e "$d/result.json" ] || [ -L "$d/result.json" ]; then
        reg_file "$d/result.json" || { FAIL "land: agents/$id/result.json is not a regular file"; bad=1; }
      fi
      if [ -e "$d/artifacts" ] || [ -L "$d/artifacts" ]; then
        if [ -L "$d/artifacts" ] || [ ! -d "$d/artifacts" ]; then
          FAIL "land: agents/$id/artifacts is not a real directory"; bad=1
        else
          for a in "$d"/artifacts/* "$d"/artifacts/.[!.]*; do
            reg_file "$a" || { FAIL "land: agents/$id/artifacts/${a##*/} is not a regular file"; bad=1; }
          done
        fi
      fi
    done
  fi
  # Every directory under OUT must be listable (-r and -x), or check could
  # not scan what the glob copies below would still reach.
  local ul us u
  if ! ul="$(mktemp)"; then FAIL "cannot make a temporary file"; return 1; fi
  find "$out" -type d \( ! -readable -o ! -executable \) -print0 >"$ul" 2>/dev/null; us=$?
  while IFS= read -r -d '' u; do
    FAIL "land: ${u#"$out"/} cannot be listed (needs read and search permission)"; bad=1
  done <"$ul"
  rm -f "$ul"
  if [ "$us" -ne 0 ]; then FAIL "land: find could not list every directory under OUT (exit $us)"; bad=1; fi
  if [ "$bad" -ne 0 ]; then echo "FAIL  land refused; nothing copied"; return 1; fi

  # The same checks as `check OUT [--values RE]`; any FAIL refuses.
  echo "check before landing:"
  if ! cmd_check "$out" "${values_arg[@]}" || [ "$fail" -ne 0 ]; then
    FAIL "land refused: check failed; nothing copied. A 'checkout has changes' FAIL under the part may be a previous partial land into it: remove that copy, then land again"
    return 1
  fi

  mkdir -p "$dest" || return 1
  for f in "${fixed[@]}"; do
    [ -f "$out/$f" ] && { cp "$out/$f" "$dest/$f" && count=$((count + 1)); }
  done
  for f in "$out"/critic-wave-*.json; do
    cp "$f" "$dest/" && count=$((count + 1))
  done
  if compgen -G "$out/recon/*.md" >/dev/null; then
    mkdir -p "$dest/recon"
    for f in "$out"/recon/*.md; do cp "$f" "$dest/recon/" && count=$((count + 1)); done
  fi
  for d in "$out"/agents/*/; do
    d="${d%/}"
    id="$(basename "$d")"
    if [ -f "$d/result.json" ]; then
      mkdir -p "$dest/agents"
      cp "$d/result.json" "$dest/agents/$id.json" && count=$((count + 1))
    fi
    if [ -d "$d/artifacts" ]; then
      for f in "$d"/artifacts/* "$d"/artifacts/.[!.]*; do
        mkdir -p "$dest/agents/$id/artifacts" \
          && cp "$f" "$dest/agents/$id/artifacts/" && count=$((count + 1))
      done
    fi
  done
  echo "landed $count file(s) in $dest"
}

# rm_report PATH: rm -rf PATH; "removed PATH" only if it is gone, else FAIL.
rm_report() {
  if rm -rf -- "$1" && [ ! -e "$1" ] && [ ! -L "$1" ]; then
    echo "removed $1"
  else
    FAIL "could not remove $1"
    return 1
  fi
}

cmd_teardown() {
  local id="" keep=false RUN trc=0 mrid
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-out) keep=true; shift ;;
      -*) usage ;;
      *) [ -z "$id" ] || usage; id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || usage
  if ! run_id_ok "$id"; then
    echo "FAIL  not a run id: $id"; return 1
  fi
  RUN="$CACHE/$id"
  if [ ! -f "$RUN/out/run-metadata.json" ]; then
    echo "FAIL  $RUN/out/run-metadata.json is missing: not a run of this tool, or already torn down; nothing removed"
    return 1
  fi
  mrid="$(jq -r '.run_id // empty' "$RUN/out/run-metadata.json" 2>/dev/null)"
  if [ "$mrid" != "$id" ]; then
    echo "FAIL  $RUN/out/run-metadata.json names run_id '${mrid:-none}', not $id; nothing removed"
    return 1
  fi
  if [ -d "$SKILL_DST" ] && [ ! -L "$SKILL_DST" ] && [ -f "$SKILL_DST/SKILL.md" ]; then
    rm_report "$SKILL_DST" || trc=1
  elif [ -e "$SKILL_DST" ] || [ -L "$SKILL_DST" ]; then
    echo "left $SKILL_DST: not a skill copy (no SKILL.md, or a symlink); check it by hand"
  else
    echo "no skill copy at $SKILL_DST"
  fi
  if [ -e "$RUN/worktree" ]; then
    git -C "$ROOT" worktree remove --force "$RUN/worktree" >/dev/null 2>&1
    rm_report "$RUN/worktree" || trc=1
  else
    echo "no worktree at $RUN/worktree"
  fi
  git -C "$ROOT" worktree prune || trc=1
  if $keep; then
    [ -d "$RUN/out" ] && echo "kept $RUN/out"
    if [ -e "$RUN/target" ]; then rm_report "$RUN/target" || trc=1; fi
  elif [ -e "$RUN" ]; then
    rm_report "$RUN" || trc=1
  else
    echo "no run directory at $RUN"
  fi
  return "$trc"
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  setup)    cmd_setup "$@"; rc=$? ;;
  validate) cmd_validate "$@"; rc=$? ;;
  check)    cmd_check "$@"; rc=$? ;;
  land)     cmd_land "$@"; rc=$? ;;
  teardown) cmd_teardown "$@"; rc=$? ;;
  *) usage ;;
esac
[ "$rc" -ne 0 ] && exit 1
[ "$fail" -ne 0 ] && exit 1
exit 0
