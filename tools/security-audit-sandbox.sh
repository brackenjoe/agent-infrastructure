#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# The OS-enforced sandbox the security-audit skill requires before any
# target code runs (tools/security-audit-skill/SKILL.md, "Universal
# execution safety"). Runs one command under bubblewrap (/usr/bin/bwrap)
# for namespaces, mounts and
# environment, inside `systemd-run --user --scope` for cgroup limits, with
# prlimit for the per-file size. Needs the AppArmor profile
# /etc/apparmor.d/bwrap-userns-restrict on Ubuntu 24.04, or bwrap cannot
# start (run then exits 125).
#
#   tools/security-audit-sandbox.sh run --target DIR --scratch DIR [--venv DIR] [--mem MIB] [--cpu N] [--wall S] [--pids N] [--fsize MIB] [--disk MIB] [--out-max KIB] [--env NAME=VALUE]... -- CMD [ARGS...]
#   tools/security-audit-sandbox.sh selfcheck
#   tools/security-audit-sandbox.sh defaults
#
# run        runs CMD with no network (loopback only), a cleared environment,
#            TARGET, VENV and SCRATCH read-only at their own real paths, the
#            host /usr and a short list of /etc files read-only, /dev (its
#            own tmpfs, remounted read-only; the null, zero, random devices
#            still work) read-only, and one
#            tmpfs, SCRATCH/sandbox, as the only writable place (HOME, TMPDIR,
#            caches and the working directory live in it; it is gone when the
#            run ends). Limits: --mem MiB of memory (no swap), --cpu cores,
#            --wall seconds, --pids tasks, --fsize MiB per file, --disk MiB
#            of tmpfs, --out-max KiB each of stdout and stderr (the rest is
#            read and dropped). Defaults: `defaults`. --env NAME=VALUE adds a
#            variable (repeatable); PATH and LANG may be overridden, the
#            fixed names (HOME, TMPDIR, XDG_*, PYTHONPYCACHEPREFIX) may not.
#            bwrap adds PWD (the working directory, $SCRATCH/sandbox/work).
#            Refused with exit 2, nothing run: a bad limit, disk*2 above
#            mem, an empty or relative $HOME, a bad path (missing, not a
#            directory, / or the home directory (from passwd, and $HOME if it
#            differs) or an ancestor of it, a path that is, is under or
#            contains ~/.ssh ~/.claude ~/.config ~/.local ~/.gnupg ~/.aws
#            ~/.kube ~/.docker or ~/.password-store, or is or contains
#            ~/.cache/security-audit, under /usr /etc /proc /sys /dev /run
#            /tmp, one of target, scratch and venv containing another), a
#            scratch that is a symlink (trailing slashes included), not
#            owned by this user, other-writable, or group-writable (unless
#            its group is the user's own private group: gid = `id -g`, named
#            as the user, no listed members), a venv without pyvenv.cfg, a bad or fixed
#            --env name (fixed, or any LD_* loader variable), a scratch
#            carrying an access ACL beyond its mode bits, or a target, scratch or venv that changed while
#            checking. Each of the three is opened on a descriptor right
#            after its check and bound by that descriptor (bwrap
#            --ro-bind-fd), so a rename or symlink swap after the checks
#            cannot make the sandbox mount something unchecked; the
#            descriptors, and the scratch mode and owner, are re-verified
#            just before the command starts. They reach bwrap only, not CMD.
#            bwrap itself re-resolves the descriptor's current name when it
#            mounts, so a guard run inside the sandbox before CMD stats each
#            bound path and compares device and inode with the checked
#            directory's; a mismatch exits 125 ("mounted is not the checked
#            directory") and CMD never starts.
#            Exit: CMD's status; 125 if the sandbox could not start or the
#            guard found a bound path that is not the checked directory or
#            CMD does not exist or is not executable ("cannot run CMD"); 137 if
#            a limit killed it (the reason is on stderr); 2 on usage or a
#            refused path. The last stderr line is `sandbox: exit N after
#            Ss; mem=... `. Every wrapper line after the command has started
#            is preceded by a newline, so it begins a line; a target can still
#            print lines that look like the wrapper's, and the exit status is
#            authoritative.
# selfcheck  one run per control (24) against a scratch directory under the
#            cache: network, environment, each write path, each limit, user
#            namespaces, the descriptor fds, the refusals (scratch write bits
#            included), limit-attribution (limit phrases in a CMD argument and
#            an --env value must give exit 0 and no limit note: the reason
#            for a kill is read from systemd's structured MESSAGE_ID and
#            UNIT_RESULT fields for the scope, never from free journal text),
#            and bind-race (a target path swapped between a
#            directory and a symlink to a protected canary, exchanged
#            atomically, while runs start: the canary must never be read and
#            the guard must have stopped a run). `ok`/`FAIL` per control; if the
#            sandbox cannot start every control is FAIL (not run). Exit 0
#            all ok, 1 any FAIL. Run it after every bwrap, kernel or AppArmor
#            change and before the first standard run.
# defaults   prints the default limits on one line.
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$(readlink -f "$0")"

# The settled defaults.
DEF_MEM=512     # MiB, cgroup MemoryMax (swap 0)
DEF_CPU=2       # cores, CPUQuota
DEF_WALL=120    # seconds, RuntimeMaxSec
DEF_PIDS=128    # TasksMax
DEF_FSIZE=64    # MiB, RLIMIT_FSIZE
DEF_DISK=128    # MiB, the writable tmpfs
DEF_OUT=1024    # KiB each of stdout and stderr

# The guard runs inside the sandbox before CMD (fixed text, no user data): the
# arguments are LABEL PATH DEV:INO triples, then --, then CMD and its args. A
# bound path whose device and inode differ from the checked directory's, or
# that cannot be stat'ed, ends the run with exit 125 and CMD never starts; so
# does a CMD that does not exist or is not executable (dash would say 126/127).
# shellcheck disable=SC2016  # the text is for the inner sh, not expanded here
GUARD='while [ "$1" != -- ]; do [ "$#" -ge 4 ] || exit 125; l=$1; p=$2; x=$3; shift 3; [ "$(/usr/bin/stat -c %d:%i -- "$p" 2>/dev/null)" = "$x" ] || { echo "sandbox: $l mounted is not the checked directory" >&2; exit 125; }; done; shift; c=; case "$1" in */*) [ -f "$1" ] && [ -x "$1" ] || c=1 ;; *) command -v -- "$1" >/dev/null 2>&1 || c=1 ;; esac; [ -z "$c" ] || { echo "sandbox: cannot run $1" >&2; exit 125; }; exec "$@"'

# The only /etc paths the sandbox sees (read-only, absent ones skipped).
ETC_FILES=(passwd group nsswitch.conf hosts host.conf ld.so.cache ld.so.conf
  ld.so.conf.d localtime alternatives ssl/certs ssl/openssl.cnf protocols
  services mime.types)

# Environment names the caller may not set with --env.
FIXED_ENV=(HOME TMPDIR XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
  XDG_STATE_HOME PYTHONPYCACHEPREFIX)

HINT='bwrap could not start the sandbox. If bwrap said "setting up uid map: Permission denied" or "loopback: Failed RTM_NEWADDR", the AppArmor profile /etc/apparmor.d/bwrap-userns-restrict is not loaded; load the AppArmor profile bwrap-userns-restrict from the Ubuntu apparmor-profiles package'

fail=0
FAIL() { echo "FAIL  $*"; fail=1; }
OK()   { echo "ok    $*"; }

usage() {
  sed -n '/^#   tools\/security-audit-sandbox.sh/p' "$0" | sed 's/^#   //' >&2
  exit 2
}

# note TEXT: a wrapper line on stderr once the command has started. It begins
# with a newline so it starts at column 0 even when the target's stderr ended
# without one.
note() { printf '\nsandbox: %s\n' "$*" >&2; }

# refuse REASON: a usage error or a refused path. Nothing has run.
refuse() { echo "sandbox: $*" >&2; exit 2; }

# anc A B: true if A equals B or is an ancestor of B (both resolved paths).
# The trailing / keeps /a/b from being taken as an ancestor of /a/bc.
anc() { local a="${1%/}/" b="${2%/}/"; [[ "$b" == "$a"* ]]; }

# fd_is FD PATH LABEL: refuse unless descriptor FD still names the resolved
# path PATH. Run in the main shell, so $BASHPID is the process that holds FD.
fd_is() {
  [ "$(readlink "/proc/$BASHPID/fd/$1")" = "$2" ] || refuse "$3 changed while checking: $2"
}

# open_fd VAR PATH LABEL: open directory PATH on a new descriptor, number in VAR
# (set in the caller's scope), and refuse unless it is the directory PATH names.
open_fd() {
  local _fd
  exec {_fd}<"$2" || refuse "$3 cannot be opened: $2"
  printf -v "$1" %s "$_fd"
  fd_is "$_fd" "$2" "$3"
}

# scratch_bits STATPATH SHOWN: refuse an other-writable scratch, and a
# group-writable one unless its group is the user's private group. STATPATH
# may be /proc/PID/fd/N (stat -L follows it to the directory).
scratch_bits() {
  local m g mode pg
  read -r m g < <(stat -L -c '%a %g' -- "$1") || refuse "cannot stat scratch: $2"
  mode=$((8#$m))
  # %a shows an ACL mask as the group bits, so an extended access ACL (the
  # system.posix_acl_access xattr exists only beyond the mode bits) is refused.
  /usr/bin/python3 -I -c 'import os, sys; sys.exit(1 if "system.posix_acl_access" in os.listxattr(sys.argv[1]) else 0)' "$1" 2>/dev/null \
    || refuse "scratch carries an access ACL beyond its mode bits: $2"
  (( (mode & 2) == 0 )) || refuse "scratch is other-writable ($m): $2"
  if (( (mode & 16) != 0 )); then
    pg="$(getent group "$g")"
    if [ "$g" != "$(id -g)" ] || [ "$(cut -d: -f1 <<<"$pg")" != "$(id -un)" ] || [ -n "$(cut -d: -f4 <<<"$pg")" ]; then
      refuse "scratch is group-writable ($m, gid $g) and the group is not the private group of $(id -un): $2"
    fi
  fi
}

cmd_defaults() {
  printf 'mem=%sM cpu=%s wall=%ss pids=%s fsize=%sM disk=%sM out-max=%sK\n' \
    "$DEF_MEM" "$DEF_CPU" "$DEF_WALL" "$DEF_PIDS" "$DEF_FSIZE" "$DEF_DISK" "$DEF_OUT"
}

# ---------------------------------------------------------------- run

# State the traps in cmd_run read.
unit=""; cmdpid=""; tmp=""; SELFCHECK_BASE=""; SELFCHECK_PROBE=""; SELFCHECK_TMPPROBE=""; SELFCHECK_RACEPID=""

# cap_stream FIFO LIMIT NAME: forward the first LIMIT bytes of FIFO to stdout,
# then keep reading and discarding so the writer is never SIGPIPEd.
cap_stream() {
  local fifo="$1" limit="$2" name="$3" dropped
  { head -c "$limit"; dropped=$(wc -c); } <"$fifo"
  if [ "${dropped:-0}" -gt 0 ]; then
    printf '\nsandbox: %s truncated, %s bytes dropped\n' "$name" "$dropped" >&2
  fi
  return 0
}

# journal_reason UNIT: timeout, oom or nothing, from systemd's own structured
# entries for the scope only. Free MESSAGE text is never read: the scope's
# Started line carries the whole command line, so a CMD argument or --env
# value could forge it. Measured on systemd 255 (Ubuntu 24.04, 2026-11-21):
# a RuntimeMaxSec kill logs MESSAGE_ID=d9b373ed55a64feb8242e02dbe79a49c with
# UNIT_RESULT=timeout; a MemoryMax kill logs the same ID with
# UNIT_RESULT=oom-kill, and, also when only a child was killed and the scope
# did not fail, MESSAGE_ID=fe6faa94e7774663a0da52717891d8ef.
journal_reason() {
  journalctl --user -u "$1.scope" -o json --no-pager \
    MESSAGE_ID=d9b373ed55a64feb8242e02dbe79a49c MESSAGE_ID=fe6faa94e7774663a0da52717891d8ef \
    _COMM=systemd 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
r = ""
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    mid, res = d.get("MESSAGE_ID"), d.get("UNIT_RESULT")
    if mid == "d9b373ed55a64feb8242e02dbe79a49c" and res == "timeout":
        r = "timeout"
    elif (mid == "d9b373ed55a64feb8242e02dbe79a49c" and res == "oom-kill") \
            or mid == "fe6faa94e7774663a0da52717891d8ef":
        r = r or "oom"
print(r)'
}

cmd_run() {
  local MEM="$DEF_MEM" CPU="$DEF_CPU" WALL="$DEF_WALL" PIDS="$DEF_PIDS"
  local FSIZE="$DEF_FSIZE" DISK="$DEF_DISK" OUTMAX="$DEF_OUT"
  local target_arg="" scratch_arg="" venv_arg="" have_cmd=false
  local -a env_pairs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)  [ $# -ge 2 ] || refuse "--target needs a value"; target_arg="$2"; shift 2 ;;
      --scratch) [ $# -ge 2 ] || refuse "--scratch needs a value"; scratch_arg="$2"; shift 2 ;;
      --venv)    [ $# -ge 2 ] || refuse "--venv needs a value"; venv_arg="$2"; shift 2 ;;
      --mem)     [ $# -ge 2 ] || refuse "--mem needs a value"; MEM="$2"; shift 2 ;;
      --cpu)     [ $# -ge 2 ] || refuse "--cpu needs a value"; CPU="$2"; shift 2 ;;
      --wall)    [ $# -ge 2 ] || refuse "--wall needs a value"; WALL="$2"; shift 2 ;;
      --pids)    [ $# -ge 2 ] || refuse "--pids needs a value"; PIDS="$2"; shift 2 ;;
      --fsize)   [ $# -ge 2 ] || refuse "--fsize needs a value"; FSIZE="$2"; shift 2 ;;
      --disk)    [ $# -ge 2 ] || refuse "--disk needs a value"; DISK="$2"; shift 2 ;;
      --out-max) [ $# -ge 2 ] || refuse "--out-max needs a value"; OUTMAX="$2"; shift 2 ;;
      --env)     [ $# -ge 2 ] || refuse "--env needs NAME=VALUE"; env_pairs+=("$2"); shift 2 ;;
      --)        shift; have_cmd=true; break ;;
      *)         refuse "unknown argument: $1" ;;
    esac
  done
  $have_cmd || refuse "no command: put -- before CMD"
  [ $# -ge 1 ] || refuse "no command after --"
  [ -n "$target_arg" ] || refuse "--target is required"
  [ -n "$scratch_arg" ] || refuse "--scratch is required"

  # Limits.
  local pair name val
  for pair in "mem:$MEM" "cpu:$CPU" "wall:$WALL" "pids:$PIDS" "fsize:$FSIZE" "disk:$DISK" "out-max:$OUTMAX"; do
    name="${pair%%:*}"; val="${pair#*:}"
    [[ "$val" =~ ^[1-9][0-9]{0,8}$ ]] || refuse "--$name must be a positive integer: $val"
  done
  [ $((DISK * 2)) -le "$MEM" ] \
    || refuse "disk $DISK MiB x 2 is above mem $MEM MiB; tmpfs pages are charged to the memory cgroup, so keep the disk at most half of memory"
  [ "$FSIZE" -le "$DISK" ] || refuse "fsize $FSIZE MiB is above disk $DISK MiB"

  # Paths. The scratch is tested for a symlink before it is resolved.
  local s_chk="$scratch_arg"
  while [ "$s_chk" != / ] && [ "${s_chk%/}" != "$s_chk" ]; do s_chk="${s_chk%/}"; done
  [ ! -L "$s_chk" ] || refuse "scratch is a symlink: $scratch_arg"
  local TARGET SCRATCH VENV=""
  TARGET="$(realpath -e -- "$target_arg" 2>/dev/null)"
  [ -d "$TARGET" ] || refuse "target is not an existing directory: $target_arg"
  local tfd sfd vfd=""
  open_fd tfd "$TARGET" target
  SCRATCH="$(realpath -e -- "$scratch_arg" 2>/dev/null)"
  [ -d "$SCRATCH" ] || refuse "scratch is not an existing directory: $scratch_arg"
  open_fd sfd "$SCRATCH" scratch
  if [ -n "$venv_arg" ]; then
    VENV="$(realpath -e -- "$venv_arg" 2>/dev/null)"
    [ -d "$VENV" ] || refuse "venv is not an existing directory: $venv_arg"
    open_fd vfd "$VENV" venv
  fi
  [ -O "$SCRATCH" ] || refuse "scratch is not owned by the current user: $SCRATCH"
  scratch_bits "$SCRATCH" "$SCRATCH"
  ! anc /tmp "$SCRATCH" || refuse "scratch is under /tmp: $SCRATCH"

  # The home directory comes from passwd; $HOME is checked too when it differs.
  local pw_home h hr s sp d p label
  case "$HOME" in /*) ;; *) refuse "HOME is empty or not an absolute path: '$HOME'" ;; esac
  pw_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
  case "$pw_home" in /*) ;; *) refuse "cannot find the home directory of $(id -un) in passwd" ;; esac
  local -a homes=()
  for h in "$pw_home" "$HOME"; do
    h="${h%/}"
    [ -n "$h" ] || h=/
    hr="$(realpath -m -- "$h")"
    for p in "$h" "$hr"; do
      [[ " ${homes[*]-} " == *" $p "* ]] || homes+=("$p")
    done
  done
  for label in target scratch venv; do
    case "$label" in
      target) p="$TARGET" ;;
      scratch) p="$SCRATCH" ;;
      venv) p="$VENV"; [ -n "$p" ] || continue ;;
    esac
    case "$p" in *:*|*$'\n'*) refuse "$label path contains ':' or a newline: $p" ;; esac
    [ "$p" != / ] || refuse "$label is /"
    for h in "${homes[@]}"; do
      ! anc "$p" "$h" || refuse "$label is the home directory or contains it: $p"
      for s in .ssh .claude .config .local .gnupg .aws .kube .docker .password-store; do
        sp="$(realpath -m -- "$h/$s")"
        if anc "$p" "$sp" || anc "$sp" "$p"; then
          refuse "$label is, is under or contains protected $h/$s: $p"
        fi
      done
      # The runs live under this one, so only "is or contains" is refused.
      sp="$(realpath -m -- "$h/.cache/security-audit")"
      ! anc "$p" "$sp" || refuse "$label is or contains $h/.cache/security-audit: $p"
    done
    for d in /usr /etc /proc /sys /dev /run /tmp; do
      ! anc "$d" "$p" || refuse "$label is under $d: $p"
    done
  done
  ! anc "$TARGET" "$SCRATCH" || refuse "target contains or equals scratch: $TARGET, $SCRATCH"
  ! anc "$SCRATCH" "$TARGET" || refuse "scratch contains or equals target: $SCRATCH, $TARGET"
  if [ -n "$VENV" ]; then
    ! anc "$TARGET" "$VENV" || refuse "target contains or equals venv: $TARGET, $VENV"
    ! anc "$VENV" "$TARGET" || refuse "venv contains or equals target: $VENV, $TARGET"
    ! anc "$SCRATCH" "$VENV" || refuse "scratch contains or equals venv: $SCRATCH, $VENV"
    ! anc "$VENV" "$SCRATCH" || refuse "venv contains or equals scratch: $VENV, $SCRATCH"
    [ -f "$VENV/pyvenv.cfg" ] || refuse "venv has no pyvenv.cfg: $VENV"
  fi

  # --env pairs. PATH and LANG replace the defaults; the rest are appended.
  local W="$SCRATCH/sandbox"
  local PATH_VAL="/usr/bin:/bin" LANG_VAL="C.UTF-8" f
  [ -z "$VENV" ] || PATH_VAL="$VENV/bin:/usr/bin:/bin"
  local -a extra_env=()
  for pair in "${env_pairs[@]+"${env_pairs[@]}"}"; do
    case "$pair" in *=*) ;; *) refuse "--env needs NAME=VALUE: $pair" ;; esac
    name="${pair%%=*}"; val="${pair#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || refuse "bad --env name: $name"
    case "$val" in *$'\n'*) refuse "--env $name: the value has a newline" ;; esac
    case "$name" in LD_*) refuse "--env $name: a loader variable would act on the guard's sh and stat before the check" ;; esac
    for f in "${FIXED_ENV[@]}"; do
      [ "$name" != "$f" ] || refuse "--env $name: that name is fixed by the sandbox"
    done
    case "$name" in
      PATH) PATH_VAL="$val" ;;
      LANG) LANG_VAL="$val" ;;
      *) extra_env+=("$name" "$val") ;;
    esac
  done

  # The writable mountpoint, made on the host (trusted, empty).
  if [ -L "$W" ]; then refuse "$W is a symlink"; fi
  if [ -e "$W" ] && [ ! -d "$W" ]; then refuse "$W exists and is not a directory"; fi
  if [ ! -e "$W" ]; then mkdir -- "$W" 2>/dev/null || refuse "cannot create $W"; fi

  # bwrap arguments.
  local -a bw=(
    --unshare-user --unshare-ipc --unshare-pid --unshare-net --unshare-uts --unshare-cgroup
    --disable-userns --die-with-parent --new-session --cap-drop ALL --hostname sandbox
    --clearenv
    --setenv HOME "$W/home"
    --setenv TMPDIR "$W/tmp"
    --setenv XDG_CACHE_HOME "$W/cache"
    --setenv XDG_CONFIG_HOME "$W/home/.config"
    --setenv XDG_DATA_HOME "$W/home/.local/share"
    --setenv XDG_STATE_HOME "$W/home/.local/state"
    --setenv PYTHONPYCACHEPREFIX "$W/pycache"
    --setenv PATH "$PATH_VAL"
    --setenv LANG "$LANG_VAL"
  )
  local i
  for ((i = 0; i < ${#extra_env[@]}; i += 2)); do
    bw+=(--setenv "${extra_env[i]}" "${extra_env[i + 1]}")
  done
  bw+=(--ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib
    --symlink usr/lib64 /lib64 --symlink usr/sbin /sbin)
  for f in "${ETC_FILES[@]}"; do bw+=(--ro-bind-try "/etc/$f" "/etc/$f"); done
  bw+=(--proc /proc --dev /dev --remount-ro /dev --ro-bind-fd "$tfd" "$TARGET")
  [ -z "$VENV" ] || bw+=(--ro-bind-fd "$vfd" "$VENV")
  bw+=(--ro-bind-fd "$sfd" "$SCRATCH"
    --size $((DISK * 1048576)) --tmpfs "$W"
    --dir "$W/home" --dir "$W/tmp" --dir "$W/cache" --dir "$W/work" --dir "$W/pycache"
    --symlink "$W/tmp" /tmp
    --remount-ro /
    --chdir "$W/work"
    --json-status-fd 3)

  tmp="$(mktemp -d)" || { echo "sandbox: mktemp failed" >&2; return 125; }
  trap 'rm -rf -- "$tmp"' EXIT
  # A signal kills the scope and the command, then the EXIT trap cleans up.
  trap 'systemctl --user kill --signal=SIGKILL "$unit.scope" >/dev/null 2>&1; kill -KILL "$cmdpid" 2>/dev/null; printf "\nsandbox: interrupted; killed\n" >&2; exit 143' INT TERM HUP
  mkfifo "$tmp/out" "$tmp/err" || { echo "sandbox: mkfifo failed" >&2; return 125; }
  : >"$tmp/status"

  # The descriptors must still be the checked directories, and the scratch
  # must still pass the owner and write-bit checks, read through the descriptor.
  fd_is "$tfd" "$TARGET" target
  fd_is "$sfd" "$SCRATCH" scratch
  [ -z "$VENV" ] || fd_is "$vfd" "$VENV" venv
  [ -O "/proc/$BASHPID/fd/$sfd" ] || refuse "scratch is not owned by the current user: $SCRATCH"
  scratch_bits "/proc/$BASHPID/fd/$sfd" "$SCRATCH"

  # Identity of the checked objects, compared inside the sandbox by the guard.
  local -a guard_args=()
  guard_args+=(target "$TARGET" "$(stat -L -c %d:%i -- "/proc/$BASHPID/fd/$tfd")")
  [ -z "$VENV" ] || guard_args+=(venv "$VENV" "$(stat -L -c %d:%i -- "/proc/$BASHPID/fd/$vfd")")
  guard_args+=(scratch "$SCRATCH" "$(stat -L -c %d:%i -- "/proc/$BASHPID/fd/$sfd")")

  unit="sa-$(date +%s)-$$-$RANDOM"
  local cap1 cap2 st t0 t1 elapsed
  cap_stream "$tmp/out" $((OUTMAX * 1024)) stdout &
  cap1=$!
  cap_stream "$tmp/err" $((OUTMAX * 1024)) stderr >&2 &
  cap2=$!

  t0=${EPOCHREALTIME/./}
  # stdin is passed through explicitly: a background job would get /dev/null.
  systemd-run --user --scope --quiet --unit="$unit" \
    -p "MemoryMax=${MEM}M" -p MemorySwapMax=0 -p "TasksMax=$PIDS" \
    -p "CPUQuota=$((CPU * 100))%" -p "RuntimeMaxSec=$WALL" -p KillSignal=SIGKILL \
    -- prlimit --fsize=$((FSIZE * 1048576)) --core=0 --nofile=1024 \
    -- /usr/bin/bwrap "${bw[@]}" -- /usr/bin/sh -c "$GUARD" sh "${guard_args[@]}" -- "$@" \
    <&0 >"$tmp/out" 2>"$tmp/err" 3>"$tmp/status" &
  cmdpid=$!
  wait "$cmdpid"; st=$?
  cmdpid=""
  t1=${EPOCHREALTIME/./}
  wait "$cap1" "$cap2"
  elapsed=$((t1 - t0))
  elapsed="$((elapsed / 1000000)).$(((elapsed % 1000000) / 100000))"

  # What happened. The status file is bwrap's JSON, one document per line.
  local rec_exit=""
  rec_exit="$(sed -n 's/.*"exit-code"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tmp/status" | tail -n 1)"

  # bwrap writes "child-pid" before the child has set up loopback and the
  # mounts, so a missing "exit-code" is the test: either a limit killed it
  # (the journal says which) or bwrap failed during setup (measured on
  # Ubuntu 24.04 without the AppArmor profile: child-pid written, bwrap exit 1).
  local code=$st tries=1 k reason=""
  if [ -z "$rec_exit" ] || [ "$rec_exit" = 137 ]; then tries=15; fi
  for ((k = 0; k < tries; k++)); do
    reason="$(journal_reason "$unit")"
    [ -z "$reason" ] || break
    [ "$k" -lt $((tries - 1)) ] && sleep 0.2
  done
  if [ -n "$rec_exit" ]; then
    code=$rec_exit
    [ "$reason" != oom ] || note "memory limit of $MEM MiB reached; a process was killed"
    [ "$reason" != timeout ] || { note "wall clock of $WALL s reached; killed"; code=137; }
  elif [ "$reason" = timeout ]; then
    note "wall clock of $WALL s reached; killed"; code=137
  elif [ "$reason" = oom ]; then
    note "memory limit of $MEM MiB reached; killed"; code=137
  elif [ "$st" -gt 128 ]; then
    note "killed by signal $((st - 128)) with no exit status, and the journal names no limit"; code=137
  else
    if ! grep -q '"child-pid"' "$tmp/status"; then
      note "bwrap never started: systemd-run --user failed (see its message above). It needs a systemd user manager and XDG_RUNTIME_DIR: under su or sudo -u, run loginctl enable-linger USER and export XDG_RUNTIME_DIR=/run/user/$(id -u), or log in normally"
    else
      note "setup failed; $HINT"
    fi
    code=125
  fi
  note "exit $code after ${elapsed}s; mem=${MEM}M cpu=$CPU wall=${WALL}s pids=$PIDS fsize=${FSIZE}M disk=${DISK}M"
  systemctl --user reset-failed "$unit.scope" 2>/dev/null || true
  return "$code"
}

# ---------------------------------------------------------- selfcheck

# Python for each control, run inside the sandbox as /usr/bin/python3 -I -c.
PY_NET_PUBLIC=$(cat <<'EOF'
import socket, sys
res, bad = [], False
# Documentation addresses (TEST-NET-1, 2001:db8::/32): no route inside, so an
# immediate error; with a network they time out, which also fails the control.
for fam, addr in ((socket.AF_INET, socket.inet_ntoa(bytes((192, 0, 2, 1)))), (socket.AF_INET6, "2001:db8::1")):
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(3)
        try:
            s.connect((addr, 443))
            res.append(addr + " CONNECTED")
            bad = True
        finally:
            s.close()
    except socket.timeout:
        res.append(addr + " TIMEOUT (a namespace with no route refuses at once)")
        bad = True
    except OSError as e:
        res.append("%s errno=%s" % (addr, e.errno))
print("; ".join(res))
sys.exit(1 if bad else 0)
EOF
)
PY_NET_IF=$(cat <<'EOF'
import sys
names = [l.split(":")[0].strip() for l in open("/proc/net/dev").read().splitlines()[2:] if ":" in l]
print(",".join(names))
sys.exit(0 if names == ["lo"] else 1)
EOF
)
PY_LOOPBACK=$(cat <<'EOF'
import socket, sys
srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(1)
c = socket.create_connection(srv.getsockname(), timeout=3)
a, _ = srv.accept()
a.settimeout(3)
c.settimeout(3)
c.sendall(b"hello")
d = b""
while len(d) < 5:
    x = a.recv(5 - len(d))
    if not x:
        break
    d += x
a.sendall(d)
r = b""
while len(r) < 5:
    x = c.recv(5 - len(r))
    if not x:
        break
    r += x
print(r.decode())
sys.exit(0 if r == b"hello" else 1)
EOF
)
PY_WRITE_FAILS=$(cat <<'EOF'
import sys
# Each mode:path opens the path; every one must fail.
bad, res = False, []
for spec in sys.argv[1:]:
    mode, path = spec.split(":", 1)
    try:
        open(path, mode).close()
        res.append("%s %s WRITABLE" % (mode, path))
        bad = True
    except OSError as e:
        res.append("%s errno=%s" % (path, e.errno))
print("; ".join(res))
sys.exit(1 if bad else 0)
EOF
)
PY_WRITE_DEV=$(cat <<'EOF'
import errno, os, sys
# Writes under /dev must fail with EROFS; the char devices must still work.
res, bad = [], False
for path in sys.argv[1:]:
    if not os.path.isdir(os.path.dirname(path)):
        res.append("%s absent" % os.path.dirname(path))
        continue
    try:
        open(path, "w").close()
        res.append("%s WRITABLE" % path)
        bad = True
    except OSError as e:
        res.append("%s errno=%s" % (path, e.errno))
        if e.errno != errno.EROFS:
            bad = True
try:
    open("/dev/null", "w").write("x")
    open("/dev/zero", "rb").read(4)
    open("/dev/urandom", "rb").read(4)
    res.append("null/zero/urandom work")
except OSError as e:
    res.append("char devices errno=%s" % e.errno)
    bad = True
print("; ".join(res))
sys.exit(1 if bad else 0)
EOF
)
PY_WRITE_SCRATCH=$(cat <<'EOF'
import sys
scratch, w = sys.argv[1], sys.argv[2]
ok = True
try:
    open(scratch + "/x", "w").close()
    r1 = "scratch WRITABLE"
    ok = False
except OSError as e:
    r1 = "scratch errno=%s" % e.errno
try:
    open(w + "/work/x", "w").close()
    r2 = "work ok"
except OSError as e:
    r2 = "work errno=%s" % e.errno
    ok = False
print(r1 + "; " + r2)
sys.exit(0 if ok else 1)
EOF
)
PY_HIDDEN=$(cat <<'EOF'
import os, sys
seen = [p for p in sys.argv[1:] if os.path.exists(p)]
print("visible: " + ",".join(seen) if seen else "none visible")
sys.exit(1 if seen else 0)
EOF
)
PY_MEMORY=$(cat <<'EOF'
b = bytearray(128 << 20)
for i in range(0, len(b), 4096):
    b[i] = 1
print("allocated")
EOF
)
PY_FSIZE=$(cat <<'EOF'
import os, sys
fd = os.open(sys.argv[1] + "/work/big", os.O_WRONLY | os.O_CREAT)
total, err = 0, None
try:
    for _ in range(32):
        total += os.write(fd, b"x" * 65536)
except OSError as e:
    err = e.errno
print("wrote=%d errno=%s" % (total, err))
sys.exit(0 if err == 27 else 1)
EOF
)
PY_DISK=$(cat <<'EOF'
import os, sys
chunk = b"x" * (1 << 20)
total, err, i = 0, None, 0
try:
    while i < 64:
        fd = os.open("%s/work/f%d" % (sys.argv[1], i), os.O_WRONLY | os.O_CREAT)
        total += os.write(fd, chunk)
        os.close(fd)
        i += 1
except OSError as e:
    err = e.errno
print("wrote=%d errno=%s" % (total, err))
sys.exit(0 if err == 28 and total <= (8 << 20) else 1)
EOF
)
PY_PIDS=$(cat <<'EOF'
import os, signal, sys, time
kids, err = [], None
try:
    for _ in range(200):
        pid = os.fork()
        if pid == 0:
            time.sleep(2)
            os._exit(0)
        kids.append(pid)
except OSError as e:
    err = e.errno
for p in kids:
    try:
        os.kill(p, signal.SIGKILL)
    except OSError:
        pass
for p in kids:
    try:
        os.waitpid(p, 0)
    except OSError:
        pass
print("forked=%d errno=%s" % (len(kids), err))
sys.exit(0 if err == 11 and len(kids) < 16 else 1)
EOF
)
PY_CPU=$(cat <<'EOF'
import os, sys, time
kids = []
for _ in range(2):
    pid = os.fork()
    if pid == 0:
        end = time.monotonic() + 3
        while time.monotonic() < end:
            pass
        os._exit(0)
    kids.append(pid)
for p in kids:
    os.waitpid(p, 0)
t = os.times()
cpu = t.children_user + t.children_system
print("children_cpu=%.2fs" % cpu)
sys.exit(0 if cpu < 4.5 else 1)
EOF
)
PY_FDS=$(cat <<'EOF'
import os, sys
open_fds = []
for fd in range(3, 1024):
    try:
        os.fstat(fd)
        open_fds.append(fd)
    except OSError:
        pass
print("open fds above 2: %s" % (open_fds or "none"))
sys.exit(1 if open_fds else 0)
EOF
)

cmd_selfcheck() {
  local base
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}" || { FAIL "setup  cannot make the cache directory"; return 1; }
  base="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/sa-selfcheck.XXXXXX")" \
    || { FAIL "setup  mktemp failed"; return 1; }
  SELFCHECK_BASE="$base"
  # Every probe made on the host goes in this trap, so every exit path,
  # signals included, removes them.
  trap '[ -z "$SELFCHECK_RACEPID" ] || kill "$SELFCHECK_RACEPID" 2>/dev/null; rm -rf -- "$SELFCHECK_BASE" "$SELFCHECK_PROBE" "$SELFCHECK_TMPPROBE"' EXIT
  trap 'exit 130' INT TERM HUP
  mkdir "$base/target" "$base/scratch"
  echo hello >"$base/target/hello.txt"
  local target="$base/target" scratch="$base/scratch" W
  W="$(realpath -e -- "$scratch")/sandbox"
  local T
  T="$(realpath -e -- "$target")"
  local SC
  SC="$(realpath -e -- "$scratch")"
  export SA_SELFCHECK_CANARY=leak
  local -a LIM=(--mem 128 --cpu 1 --wall 30 --pids 64 --fsize 4 --disk 8 --out-max 64)
  local PYBIN=/usr/bin/python3
  local o="" e="" rc=0 t0 t1 ms

  # sbx [OVERRIDES...] -- CMD...: o = stdout, e = stderr, rc = status.
  sbx() {
    o="$("$SELF" run --target "$target" --scratch "$scratch" "${LIM[@]}" "$@" 2>"$base/err")"; rc=$?
    e="$(cat "$base/err")"
  }
  # one TEXT: TEXT on one line, for a one-line detail.
  one() { printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/ $//'; }
  # ctl_py NAME PY OVERRIDES... -- ARGS...: run PY, ok if it exits 0.
  # Returns 0 on ok so the caller can add host-side checks.
  ctl_py() {
    local name="$1" py="$2"; shift 2
    local -a ov=() args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do ov+=("$1"); shift; done
    [ $# -eq 0 ] || shift
    args=("$@")
    sbx "${ov[@]}" -- "$PYBIN" -I -c "$py" "${args[@]}"
    if [ "$rc" -eq 0 ]; then return 0; fi
    FAIL "$name  rc=$rc; $(one "$o") $(one "$e")"
    return 1
  }

  local -a names=(exit-status net-public net-interfaces loopback env write-home
    write-target write-root write-dev write-scratch home-hidden memory wall fsize disk
    pids cpu userns fds cannot-run refusals bind-race limit-attribution)
  local n

  # start
  sbx -- /usr/bin/true
  if [ "$rc" -ne 0 ]; then
    FAIL "start  run -- true exited $rc (expected 0); $HINT"
    [ -z "$e" ] || echo "      first stderr line: $(printf '%s\n' "$e" | head -n 1)"
    for n in "${names[@]}"; do FAIL "$n  not run: the sandbox cannot start"; done
    return 1
  fi
  OK "start  run -- true exited 0"

  # exit-status
  sbx -- /usr/bin/sh -c 'exit 7'
  if [ "$rc" -eq 7 ]; then OK "exit-status  sh -c 'exit 7' returned 7"
  else FAIL "exit-status  returned $rc, expected 7"; fi

  # net-public
  if ctl_py net-public "$PY_NET_PUBLIC" -- ; then OK "net-public  $(one "$o")"; fi

  # net-interfaces
  if ctl_py net-interfaces "$PY_NET_IF" -- ; then OK "net-interfaces  only $(one "$o")"; fi

  # loopback
  if ctl_py loopback "$PY_LOOPBACK" -- ; then OK "loopback  127.0.0.1 echo of 5 bytes ($(one "$o"))"; fi

  # env
  local want got extra missing
  # PWD is set by bwrap itself after --chdir (to $W/work); it cannot be unset.
  want="$(printf '%s\n' HOME TMPDIR XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME PYTHONPYCACHEPREFIX PATH LANG PWD SA_PROBE | sort)"
  sbx --env SA_PROBE=1 -- /usr/bin/env
  if [ "$rc" -ne 0 ]; then
    FAIL "env  rc=$rc; $(one "$e")"
  else
    got="$(printf '%s\n' "$o" | sed 's/=.*//' | sort)"
    extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ')"
    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ')"
    if grep -q 'SA_SELFCHECK_CANARY\|=leak$' <<<"$o"; then
      FAIL "env  the canary leaked into the sandbox"
    elif [ -n "$extra$missing" ]; then
      FAIL "env  extra: ${extra:-none} missing: ${missing:-none}"
    else
      OK "env  exactly the 11 expected names (PWD set by bwrap), canary absent"
    fi
  fi

  # write-home
  local probe="$HOME/sa-selfcheck-probe-$$"
  if ctl_py write-home "$PY_WRITE_FAILS" -- "w:$probe"; then
    if [ -e "$probe" ]; then rm -f -- "$probe"; FAIL "write-home  the host path exists afterwards"
    else OK "write-home  $(one "$o"); host path absent"; fi
  fi

  # write-target
  if ctl_py write-target "$PY_WRITE_FAILS" -- "w:$T/new" "a:$T/hello.txt"; then
    if [ "$(cat "$target/hello.txt")" = hello ] && [ ! -e "$target/new" ]; then
      OK "write-target  $(one "$o"); host target unchanged"
    else FAIL "write-target  the host target changed"; fi
  fi

  # write-root
  if ctl_py write-root "$PY_WRITE_FAILS" -- "w:/newfile" "w:/usr/sa-probe"; then
    OK "write-root  $(one "$o")"
  fi

  # write-dev: bwrap's /dev is its own tmpfs, which --remount-ro / does not cover.
  if ctl_py write-dev "$PY_WRITE_DEV" -- "/dev/sa-probe" "/dev/shm/sa-probe"; then
    OK "write-dev  $(one "$o")"
  fi

  # write-scratch
  if ctl_py write-scratch "$PY_WRITE_SCRATCH" -- "$SC" "$W"; then
    if [ -e "$W/work/x" ] || [ -e "$SC/x" ]; then FAIL "write-scratch  a write reached the host scratch"
    else OK "write-scratch  $(one "$o"); tmpfs did not persist"; fi
  fi

  # home-hidden
  # The probe is a real directory with a file under the passwd home, so the
  # control does not pass just because the host has no ~/.ssh.
  local pw_home
  pw_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  SELFCHECK_PROBE="$pw_home/.sa-selfcheck-hidden-$$"
  if ! { mkdir -- "$SELFCHECK_PROBE" && echo x >"$SELFCHECK_PROBE/file"; }; then
    FAIL "home-hidden  cannot make the probe $SELFCHECK_PROBE"
  elif ctl_py home-hidden "$PY_HIDDEN" -- "$SELFCHECK_PROBE" "$SELFCHECK_PROBE/file" "$HOME/.ssh" "$ROOT"; then
    OK "home-hidden  host probe $SELFCHECK_PROBE, $HOME/.ssh and the repo root: $(one "$o")"
  fi
  rm -rf -- "$SELFCHECK_PROBE"; SELFCHECK_PROBE=""

  # memory
  sbx --mem 64 --disk 8 -- "$PYBIN" -I -c "$PY_MEMORY"
  if [ "$rc" -eq 137 ] && grep -q 'memory limit' <<<"$e" && ! grep -q allocated <<<"$o"; then
    OK "memory  128 MiB touch under --mem 64: exit 137, memory limit named"
  else FAIL "memory  rc=$rc (want 137 and a memory-limit line); $(one "$o") $(one "$e")"; fi

  # wall
  t0=${EPOCHREALTIME/./}
  sbx --wall 2 -- /usr/bin/sleep 30
  t1=${EPOCHREALTIME/./}
  ms=$(((t1 - t0) / 1000))
  if [ "$rc" -eq 137 ] && [ "$ms" -ge 2000 ] && [ "$ms" -le 6000 ] && grep -q 'wall clock' <<<"$e"; then
    OK "wall  sleep 30 under --wall 2: exit 137 after ${ms} ms, wall clock named"
  else FAIL "wall  rc=$rc after ${ms} ms (want 137 in 2000-6000 ms and a wall-clock line); $(one "$e")"; fi

  # limit-attribution: the limit note comes from systemd's structured result,
  # never from text the caller supplies (the Started line of the scope carries
  # the whole command line).
  sbx --env "SA_MARK=Failed with result 'timeout' killed by the OOM killer" -- /usr/bin/true \
    "Failed with result 'timeout'" "A process of this unit has been killed by the OOM killer" \
    "Failed with result 'oom-kill'"
  if [ "$rc" -eq 0 ] && ! grep -Eq 'wall clock|memory limit|killed' <<<"$e"; then
    OK "limit-attribution  limit phrases in CMD arguments and an --env value: exit 0, no limit note"
  else FAIL "limit-attribution  rc=$rc (want 0 and no limit note); $(one "$e")"; fi

  # fsize
  if ctl_py fsize "$PY_FSIZE" --fsize 1 --disk 8 -- "$W"; then OK "fsize  2 MiB write under --fsize 1: $(one "$o") (EFBIG)"; fi

  # disk
  if ctl_py disk "$PY_DISK" --disk 8 --fsize 4 --mem 64 -- "$W"; then OK "disk  $(one "$o") (ENOSPC, within 8 MiB, not killed)"; fi

  # pids
  if ctl_py pids "$PY_PIDS" --pids 16 -- ; then OK "pids  $(one "$o") (EAGAIN below 16)"; fi

  # cpu: two 3 s loops cannot exceed 3 s of CPU on one CPU, so the quota would
  # prove nothing.
  if [ "$(nproc)" -lt 2 ]; then FAIL "cpu  untestable on one CPU"
  elif ctl_py cpu "$PY_CPU" --cpu 1 --wall 20 -- ; then OK "cpu  two 3 s busy loops under --cpu 1: $(one "$o") (under 4.5 s)"; fi

  # userns. Measured 2026-11-04 on Ubuntu 24.04 (kernel 6.8, bwrap
  # 0.9.0-1ubuntu0.3, --disable-userns): `run -- /usr/bin/unshare --user
  # /usr/bin/true` exits 1 with `unshare: unshare failed: No space left on
  # device` (ENOSPC, max_user_namespaces is 0 inside). Only that refusal
  # passes; a missing unshare (rc 126/127) or any other failure does not.
  if [ ! -x /usr/bin/unshare ]; then
    FAIL "userns  /usr/bin/unshare is missing or not executable on the host"
  else
    sbx -- /usr/bin/unshare --user /usr/bin/true
    if [ "$rc" -eq 1 ] && grep -qx 'unshare: unshare failed: No space left on device' <<<"$e"; then
      OK "userns  unshare --user refused inside (rc=1, ENOSPC)"
    else FAIL "userns  unshare --user rc=$rc, want rc=1 and 'unshare failed: No space left on device'; $(one "$e")"; fi
  fi

  # fds: bwrap's status fd must not reach the target, or it could forge exit-code.
  if ctl_py fds "$PY_FDS" -- ; then OK "fds  $(one "$o")"; fi

  # cannot-run: an unrunnable CMD exits 125 (the guard), not dash's 126/127.
  sbx -- /nonexistent/cmd
  if [ "$rc" -eq 125 ] && grep -qx 'sandbox: cannot run /nonexistent/cmd' <<<"$e"; then
    OK "cannot-run  /nonexistent/cmd exits 125 with 'sandbox: cannot run'"
  else FAIL "cannot-run  rc=$rc, want 125 and 'sandbox: cannot run /nonexistent/cmd'; $(one "$e")"; fi

  # refusals: each case must exit 2 AND print its own reason, so a refusal
  # for the wrong reason (a missing directory, say) does not pass.
  local fh="$base/fakehome" bad="" nref=0
  mkdir -p "$fh/.ssh/x" "$fh/.aws/x" "$base/real"
  # Scratch directories for the write-bit cases. Ubuntu's default umask is 0002, so
  # a 0775 scratch on the private group must keep working.
  local g_pg g_other="" g_sk="" acc_rc g_named=", scratch group-writable on a non-private group"
  g_pg="$(id -g)"
  for g in $(id -G); do [ "$g" = "$g_pg" ] || { g_other="$g"; break; }; done
  mkdir "$base/scr-o" "$base/scr-g" "$base/scr-p" "$base/scr-a"
  local g_acl=1 g_ask=""
  chmod 0755 "$base/scr-a"
  if command -v setfacl >/dev/null && setfacl -m "u:$(id -un):rwx" "$base/scr-a" 2>/dev/null; then g_acl=0
  else g_ask=" (ACL case skipped: setfacl missing or failed)"; fi
  chmod 0757 "$base/scr-o"
  chmod 0775 "$base/scr-p"
  chgrp "$g_pg" "$base/scr-p" 2>/dev/null
  if [ -n "$g_other" ] && chgrp "$g_other" "$base/scr-g" 2>/dev/null; then chmod 0775 "$base/scr-g"
  else g_other=""; g_named=""; g_sk=" (group-writable on a non-private group skipped: no usable supplementary group)"; fi
  ln -s "$base/real" "$base/link"
  SELFCHECK_TMPPROBE="$(mktemp -d /tmp/sa-selfcheck-tmp.XXXXXX)"
  # refcase NAME PATTERN HOME TARGET SCRATCH
  refcase() {
    local rn="$1" pat="$2" hv="$3" tg="$4" sc="$5" rr
    HOME="$hv" "$SELF" run --target "$tg" --scratch "$sc" -- /usr/bin/true >/dev/null 2>"$base/err"; rr=$?
    e="$(cat "$base/err")"
    nref=$((nref + 1))
    if [ "$rr" -ne 2 ] || ! grep -q "^sandbox: .*$pat" <<<"$e"; then
      bad="$bad $rn(rc=$rr: $(one "$(head -n 1 <<<"$e")"))"
    fi
  }
  refcase overlap          'contains or equals' "$HOME"   "$base"       "$scratch"
  refcase home             'home directory'     "$HOME"   "$HOME"       "$scratch"
  refcase passwd-home      'home directory'     "$fh"     "$pw_home"    "$scratch"
  refcase under-ssh        'protected'          "$fh"     "$fh/.ssh/x"  "$scratch"
  refcase under-aws        'protected'          "$fh"     "$fh/.aws/x"  "$scratch"
  refcase empty-home       'HOME'               ""        "$target"     "$scratch"
  refcase relative-home    'HOME'               "rel/home" "$target"    "$scratch"
  refcase scratch-link-2   'symlink'            "$HOME"   "$target"     "$base/link//"
  refcase target-under-tmp 'under /tmp'         "$HOME"   "$SELFCHECK_TMPPROBE" "$scratch"
  refcase scratch-other    'other-writable'     "$HOME"   "$target"     "$base/scr-o"
  [ -z "$g_other" ] || refcase scratch-group 'group-writable' "$HOME" "$target" "$base/scr-g"
  [ "$g_acl" -ne 0 ] || refcase scratch-acl 'ACL' "$HOME" "$target" "$base/scr-a"
  # a loader variable is refused before anything runs
  HOME="$HOME" "$SELF" run --target "$target" --scratch "$scratch" --env LD_PRELOAD=/x -- /usr/bin/true >/dev/null 2>"$base/err"; acc_rc=$?
  nref=$((nref + 1))
  if [ "$acc_rc" -ne 2 ] || ! grep -q '^sandbox: .*loader' "$base/err"; then bad="$bad env-ld(rc=$acc_rc: $(one "$(head -n 1 "$base/err")"))"; fi
  # accept: a 0775 scratch on the private group runs.
  "$SELF" run --target "$target" --scratch "$base/scr-p" "${LIM[@]}" -- /usr/bin/true >/dev/null 2>"$base/err"; acc_rc=$?
  nref=$((nref + 1))
  [ "$acc_rc" -eq 0 ] || bad="$bad scratch-private-0775(rc=$acc_rc: $(one "$(head -n 1 "$base/err")"))"
  if [ -z "$bad" ]; then
    OK "refusals  $nref cases all as expected (overlap, home, passwd home, ~/.ssh, ~/.aws, empty and relative HOME, link//, /tmp, scratch other-writable$g_named, scratch with an ACL, LD_PRELOAD; 0775 scratch on the private group runs)$g_sk$g_ask"
  else FAIL "refusals  wrong:$bad"; fi

  # bind-race: the target path is exchanged, atomically and without pause
  # (renameat2 RENAME_EXCHANGE), between a real directory and a symlink to a
  # protected directory (fake ~/.ssh/x) while runs start. Each run cats the
  # canary name under the target's own path; the real directory holds a file of
  # that name with other content. The protected content must never be printed,
  # and the guard must have stopped at least one run ("mounted is not the
  # checked directory"), or the control proved nothing about the guard. Every
  # run must exit 0, 2 (refused at a check), or 125 from the guard or bwrap's
  # "Can't get type of source" or "Can't bind mount" (nothing ran). Up to 400 starts; stop once 100
  # are done and the guard has fired.
  local rc_t="$base/racet" rc_real rn_ok=0 rn_ref=0 rn_bw=0 rn_guard=0 rn_bad="" rn_leak=0 rn_i=0 rn_rc rn_cnt
  mkdir "$rc_t"
  echo benign >"$rc_t/canary"
  echo SA-RACE-CANARY-SECRET >"$fh/.ssh/x/canary"
  ln -s "$fh/.ssh/x" "$base/racet.lnk"
  rc_real="$(realpath -e -- "$rc_t")"
  /usr/bin/python3 -I -c '
import ctypes, sys
libc = ctypes.CDLL(None, use_errno=True)
a, b = sys.argv[1].encode(), sys.argv[2].encode()
while True:
    libc.renameat2(-100, a, -100, b, 2)
' "$rc_t" "$base/racet.lnk" &
  SELFCHECK_RACEPID=$!
  while [ "$rn_i" -lt 400 ] && { [ "$rn_i" -lt 100 ] || [ "$rn_guard" -eq 0 ]; }; do
    rn_i=$((rn_i + 1))
    o="$(HOME="$fh" "$SELF" run --target "$rc_t" --scratch "$scratch" "${LIM[@]}" -- /usr/bin/cat "$rc_real/canary" 2>"$base/err")"; rn_rc=$?
    if grep -q SA-RACE-CANARY-SECRET <<<"$o" || grep -q SA-RACE-CANARY-SECRET "$base/err"; then rn_leak=$((rn_leak + 1)); fi
    case "$rn_rc" in
      0) rn_ok=$((rn_ok + 1)) ;;
      2) rn_ref=$((rn_ref + 1)) ;;
      125) if grep -q "mounted is not the checked directory" "$base/err"; then rn_guard=$((rn_guard + 1))
           elif grep -q "Can't get type of source\|Can't find source path\|Can't bind mount" "$base/err"; then rn_bw=$((rn_bw + 1))
           else rn_bad="$rn_bad 125($(one "$(head -n 1 "$base/err")"))"; fi ;;
      *) rn_bad="$rn_bad $rn_rc" ;;
    esac
  done
  kill "$SELFCHECK_RACEPID" 2>/dev/null; wait "$SELFCHECK_RACEPID" 2>/dev/null; SELFCHECK_RACEPID=""
  rn_cnt="$rn_i starts: ran $rn_ok, refused at a check $rn_ref, stopped by the guard $rn_guard, bwrap source failures $rn_bw"
  if [ "$rn_leak" -ne 0 ]; then FAIL "bind-race  the protected canary was read in $rn_leak runs ($rn_cnt)"
  elif [ -n "$rn_bad" ]; then FAIL "bind-race  unexpected exit status(es):$rn_bad ($rn_cnt)"
  elif [ "$rn_guard" -eq 0 ]; then FAIL "bind-race  the guard never fired in $rn_i starts, so it was not shown to hold ($rn_cnt)"
  else OK "bind-race  target path atomically exchanged with a symlink to a protected dir: canary never read ($rn_cnt)"; fi

  [ "$fail" -eq 0 ]
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  run)       cmd_run "$@"; rc=$?; exit "$rc" ;;
  selfcheck) cmd_selfcheck "$@"; rc=$? ;;
  defaults)  cmd_defaults; rc=0 ;;
  *) usage ;;
esac
[ "$rc" -ne 0 ] && exit 1
[ "$fail" -ne 0 ] && exit 1
exit 0
