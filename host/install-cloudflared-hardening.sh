#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# One-time (idempotent) hardening, ON the host, of the cloudflared
# unit: a systemd drop-in that sandboxes the process in front of the apps.
# cloudflared carries all internet-originated traffic and reads the tunnel
# credential, yet scores 9.6 UNSAFE under systemd-analyze security and runs
# with no sandbox (measured 2026-11-04 on Ubuntu 24.04, systemd 255).
# Run it as a sudoer (password once):
#
#     sudo ./install-cloudflared-hardening.sh [--dry-run [--user] | --user | --root | --remove]
#
# Does:
#   1. records `systemd-analyze security cloudflared.service | tail -1`
#   2. writes cloudflared.service.d/hardening.conf (0644): the root drop-in's
#      directives, still root; with --user also the dedicated-user block that runs
#      cloudflared as the system user `cloudflared`: User=, Group=,
#      LoadCredential=tunnel.json:<credentials-file from config.yml> and
#      Environment=TUNNEL_CRED_FILE=%d/tunnel.json (config.yml is not edited)
#   3. systemd-analyze verify, daemon-reload, restart cloudflared, then waits
#      up to 30 s for readyConnections >= 1 on http://127.0.0.1:20241/ready
#   4. prints "runs as: <user> (uid N)" (Uid: of the main process's status), the new
#      score, NRestarts and ActiveState, and the last 20 journal lines; with
#      --user it also lists /run/credentials/cloudflared.service/
#   5. on any failure (verify, unit not active, /ready never ready) it removes
#      the drop-in, daemon-reloads, restarts, waits for /ready again and exits
#      1, so the public face is not left down. With --user, a failure after the
#      drop-in is written and the unit restarted (including the main process
#      not running as cloudflared) goes back to the ROOT drop-in; if /ready is
#      still not back with that, the drop-in is removed entirely, the unit
#      restarted and /ready awaited once more, and the script says which state
#      the host ended in. A verify or daemon-reload failure (no restart yet)
#      puts back exactly the previous drop-in bytes, or no file, and runs
#      daemon-reload.
#
# Refuses (exit 2) before changing anything when: a hardening.conf exists
# without this script's marker line ("Installed by
# install-cloudflared-hardening.sh"; install, --remove and rollback alike; it
# is never overwritten, deleted or backed up: move it away); cloudflared.service
# does not exist; it is not active (a restart would start a stopped unit); or
# /ready does not answer (the metrics address: `metrics:` in CF_CONFIG, else
# READY_URL, else 127.0.0.1:20241; cloudflared binds the first free port in
# 20241-20245 unless --metrics or `metrics:` is set).
#
# The restart costs a few seconds of Cloudflare's 1033 page. If the unit
# fails to start, the script rolls back; try again without
# MemoryDenyWriteExecute, ReadOnlyPaths or BindReadOnlyPaths in the drop-in
# (the usual hint; ReadOnlyPaths=/run and BindReadOnlyPaths=/sys close the systemd
# 255 gap that leaves both rw under ProtectSystem=strict, and the unit still
# needs /run/systemd/notify).
# A verify failure rolls back without a restart: the running unit never
# loaded the drop-in.
#
#   --remove   take the drop-in out (daemon-reload, restart, wait for /ready);
#              the user cloudflared stays. Exit 0 with nothing done if there is
#              no drop-in
#   --dry-run  print the drop-in and the steps; change nothing (no root needed)
#   --user     everything above plus the dedicated-user block. Reads the
#              credential path from CF_CONFIG (default /etc/cloudflared/config.yml,
#              the first `credentials-file: <path>` line) and fails before
#              writing anything if the line is missing or the path is not a
#              regular file. Creates the system user cloudflared if `id` does
#              not find it (useradd --system, no home, nologin), then checks
#              that user can read CF_CONFIG (runuser; /etc/cloudflared needs
#              o+x and config.yml o+r) and fails before writing if not. This
#              script never deletes that user; userdel is the owner's.
#              config.yml itself must stay world-readable (0644): the service
#              user reads it. /etc/cloudflared/ holds the credential root 0600;
#              systemd mounts a read-only copy at /run/credentials/
#              cloudflared.service/ with an ACL for the user.
#   --root     the plain install (root drop-in), but also over a drop-in that is
#              in user mode. A plain install without --root refuses (exit 2)
#              when the existing drop-in has User=cloudflared.
#   --dry-run --user is the only flag pair allowed.
#
# `systemd-analyze verify` on a host without the credential file warns about
# LoadCredential=; expected clean where the credential file exists.
#
# Rerunning rewrites the file and re-verifies.
# Environment overrides, the hooks of test-cloudflared-hardening.sh (an offline
# test with stubbed systemctl, systemd-analyze, journalctl, curl, useradd, id
# and runuser):
#   ETC_DIR      the systemd unit directory (default /etc/systemd/system)
#   READY_URL    the /ready endpoint; overrides `metrics:` in CF_CONFIG (default:
#                `metrics:` address, else http://127.0.0.1:20241/ready)
#   WAIT_MAX     seconds to wait for readyConnections >= 1 (default 30)
#   CF_CONFIG    cloudflared config.yml (default /etc/cloudflared/config.yml)
#   PROC_DIR     the main process's status and mountinfo (default /proc)
#   HARDENING_ALLOW_NONROOT=1 (test only) skips the root gate.
set -uo pipefail

ETC_DIR="${ETC_DIR:-/etc/systemd/system}"
READY_URL_OVERRIDE="${READY_URL:-}"
READY_URL="${READY_URL_OVERRIDE:-http://127.0.0.1:20241/ready}"
WAIT_MAX="${WAIT_MAX:-30}"
UNIT=cloudflared.service
DROPIN_DIR="$ETC_DIR/$UNIT.d"
DROPIN="$DROPIN_DIR/hardening.conf"
CF_CONFIG="${CF_CONFIG:-/etc/cloudflared/config.yml}"
SVC_USER=cloudflared
CRED_DIR="/run/credentials/$UNIT"
PROC_DIR="${PROC_DIR:-/proc}"

usage() { echo "usage: $0 [--dry-run [--user] | --user | --root | --remove]" >&2; exit 2; }

mode=install
user_mode=0
force_root=0
case "$#:${1:-}:${2:-}" in
  0::) ;;
  1:--remove:) mode=remove ;;
  1:--dry-run:) mode=dry ;;
  1:--user:) user_mode=1 ;;
  1:--root:) force_root=1 ;;
  2:--dry-run:--user) mode=dry; user_mode=1 ;;
  *) usage ;;
esac

# resolve_cred: set $cred from the first `credentials-file:` line of $CF_CONFIG
# (whitespace and one pair of quotes stripped); exit 1 if absent or not a file.
cred=""
resolve_cred() {
  cred=$(sed -n '/^[[:space:]]*credentials-file:/{
s/^[[:space:]]*credentials-file:[[:space:]]*//
s/[[:space:]]*$//
s/^"\(.*\)"$/\1/
s/^'"'"'\(.*\)'"'"'$/\1/
p
q
}' "$CF_CONFIG" 2>/dev/null) || cred=""
  if [ -z "$cred" ]; then
    echo "FAIL: credentials-file not found in $CF_CONFIG" >&2
    exit 1
  fi
  if [ ! -f "$cred" ]; then
    echo "FAIL: credential $cred is not a file" >&2
    exit 1
  fi
}

# print_dropin root|user
print_dropin() {
  cat <<'CONF'
# Installed by install-cloudflared-hardening.sh.
# Remove with: sudo install-cloudflared-hardening.sh --remove
# Runs as root unless the Dedicated user block below is present (--user adds it).
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
# systemd 255.4 (Ubuntu): ProtectKernelTunables=yes leaves /sys read-write and
# overrides ReadOnlyPaths=/sys; a read-only bind stacked on top holds (measured 2026-11-05).
ReadOnlyPaths=/run
BindReadOnlyPaths=/sys
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=
CONF
  if [ "$1" = user ]; then
    cat <<'CONF'
# Dedicated user. The /etc credential stays root 0600;
# systemd mounts a read-only copy at %d (/run/credentials/cloudflared.service)
# with an ACL for the user, and TUNNEL_CRED_FILE points cloudflared at it, so
# config.yml's credentials-file: line is left alone (it is read as root only
# when this block is absent). config.yml itself must stay world-readable (0644).
User=cloudflared
Group=cloudflared
CONF
    printf '%s\n' "LoadCredential=tunnel.json:$cred" "Environment=TUNNEL_CRED_FILE=%d/tunnel.json"
  fi
}

if [ "$mode" = dry ]; then
  kind=root
  if [ "$user_mode" = 1 ]; then kind=user; resolve_cred; fi
  echo "=== dry run: nothing is changed ==="
  echo "would write $DROPIN (0644):"
  echo "-----"
  print_dropin "$kind"
  echo "-----"
  echo "steps:"
  echo "  0. refuse (exit 2) if the drop-in exists without this script's marker, $UNIT is missing or not active, or /ready does not answer (metrics: in $CF_CONFIG, else $READY_URL)"
  echo "  1. record: systemd-analyze security $UNIT | tail -1"
  if [ "$user_mode" = 1 ]; then
    echo "  1a. read credentials-file from $CF_CONFIG (want a regular file: $cred)"
    echo "  1b. ensure the user $SVC_USER (id, else useradd --system --no-create-home --shell /usr/sbin/nologin); never deleted by this script"
    echo "  1c. check $SVC_USER can read $CF_CONFIG (runuser); /etc/cloudflared needs o+x, config.yml o+r"
  fi
  echo "  2. write the drop-in"
  echo "  3. systemd-analyze verify $UNIT"
  echo "  4. systemctl daemon-reload; systemctl restart cloudflared"
  echo "  5. wait up to ${WAIT_MAX} s for readyConnections >= 1 at $READY_URL"
  if [ "$user_mode" = 1 ]; then
    echo "  5a. print: runs as: <owner of the main process>; must be $SVC_USER, else roll back"
  else
    echo "  5a. print: runs as: <owner of the main process> (not judged)"
  fi
  [ "$user_mode" = 1 ] && echo "  5b. ls -l $CRED_DIR/"
  echo "  6. print the new score, NRestarts/ActiveState, the effective mount of each
     /run and /sys mount point from the main process's mountinfo (ro or RW),
     journalctl -u cloudflared -n 20"
  if [ "$user_mode" = 1 ]; then
    echo "  on failure: rewrite the ROOT drop-in (no user block), daemon-reload, restart, wait for /ready; if still not ready, remove the drop-in, restart, wait again; exit 1"
  else
    echo "  on failure: remove the drop-in, daemon-reload, restart, wait for /ready, exit 1"
  fi
  exit 0
fi

if [ "${HARDENING_ALLOW_NONROOT:-}" != 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
fi
command -v systemctl >/dev/null || { echo "FAIL: systemctl not found" >&2; exit 1; }
command -v systemd-analyze >/dev/null || { echo "FAIL: systemd-analyze not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "FAIL: curl not installed" >&2; exit 1; }

# A drop-in this script did not write (no marker line) is never touched.
foreign_dropin() {
  # The marker, with or without a directory before the script name: the
  # version of 2026-11-05 wrote "Installed by tools/install-cloudflared-hardening.sh".
  { [ -e "$DROPIN" ] || [ -L "$DROPIN" ]; } && ! grep -Eq '^# Installed by ([^ ]*/)?install-cloudflared-hardening\.sh' "$DROPIN" 2>/dev/null
}
refuse_foreign() {
  echo "FAIL: $DROPIN exists and was not written by this script (no 'Installed by install-cloudflared-hardening.sh' line); not touching it. Move it away (mv $DROPIN to somewhere safe) and rerun." >&2
}
if foreign_dropin; then refuse_foreign; exit 2; fi

# A plain install over a drop-in in user mode would silently drop the user.
if [ "$mode" = install ] && [ "$user_mode" = 0 ] && [ "$force_root" = 0 ] \
   && grep -q '^User=cloudflared' "$DROPIN" 2>/dev/null; then
  echo "drop-in is in user mode; rerun with --user, or --root to go back to root" >&2
  exit 2
fi

if [ "$mode" = remove ] && [ ! -e "$DROPIN" ] && [ ! -L "$DROPIN" ]; then
  echo "nothing to remove: $DROPIN does not exist; no restart"
  exit 0
fi

# metrics_addr: the host:port of a top-level `metrics:` line in $CF_CONFIG
# (quotes and a trailing comment stripped; a wildcard bind becomes loopback);
# prints nothing if there is none.
metrics_addr() {
  local a
  a=$(sed -n '/^metrics:/{
s/^metrics:[[:space:]]*//
s/[[:space:]]*#.*$//
s/[[:space:]]*$//
s/^"\(.*\)"$/\1/
s/^'"'"'\(.*\)'"'"'$/\1/
p
q
}' "$CF_CONFIG" 2>/dev/null) || a=""
  case "$a" in
    :*) a="127.0.0.1$a" ;;
    0.0.0.0:*) a="127.0.0.1:${a#*:}" ;;
    "[::]:"*) a="127.0.0.1:${a##*:}" ;;
  esac
  case "$a" in *:[0-9]*) printf '%s' "$a" ;; esac
}

# resolve_ready: READY_URL override, else the `metrics:` address, else the
# default; the default and the override are probed (any HTTP answer counts)
# before anything changes.
resolve_ready() {
  local m=""
  if [ -z "$READY_URL_OVERRIDE" ]; then
    m=$(metrics_addr)
    if [ -n "$m" ]; then
      READY_URL="http://$m/ready"
      echo "metrics address: $m (from $CF_CONFIG)"
      return 0
    fi
  fi
  if ! curl -s --max-time 2 -o /dev/null "$READY_URL" 2>/dev/null; then
    echo "FAIL: no answer from $READY_URL and the metrics address could not be found (no metrics: line in $CF_CONFIG; cloudflared binds the first free port in 20241-20245 unless --metrics or metrics: is set). Find it (ss -ltnp | grep cloudflared) and rerun as: sudo env READY_URL=http://127.0.0.1:PORT/ready $0 ...; nothing changed" >&2
    exit 2
  fi
}

[ "$mode" = install ] && [ "$user_mode" = 1 ] && resolve_cred

if ! systemctl cat "$UNIT" >/dev/null 2>&1; then
  echo "FAIL: no such unit $UNIT (systemctl cat failed); nothing changed" >&2
  exit 2
fi
state=$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null)
if [ "$state" != active ]; then
  echo "FAIL: unit is not active; start it first, or this script would start it (ActiveState=${state:-unknown}); nothing changed" >&2
  exit 2
fi
resolve_ready

if [ "$mode" = install ] && [ "$user_mode" = 1 ]; then
  command -v useradd >/dev/null || { echo "FAIL: useradd not found" >&2; exit 1; }
  user_created=0
  if id "$SVC_USER" >/dev/null 2>&1; then
    echo "user $SVC_USER: exists"
  else
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group "$SVC_USER" \
      || { echo "FAIL: useradd $SVC_USER" >&2; exit 1; }
    user_created=1
    echo "user $SVC_USER: created"
  fi
  command -v runuser >/dev/null || { echo "FAIL: runuser not found" >&2; exit 1; }
  if runuser -u "$SVC_USER" -- cat "$CF_CONFIG" >/dev/null 2>&1; then
    echo "config readable by $SVC_USER: yes"
  else
    left="nothing changed"
    [ "$user_created" = 1 ] && left="the user $SVC_USER was created; nothing else changed"
    echo "FAIL: $CF_CONFIG is not readable by $SVC_USER (want $(dirname "$CF_CONFIG") o+x and $CF_CONFIG o+r); $left" >&2
    exit 1
  fi
fi

# Wait up to WAIT_MAX s for readyConnections >= 1; sets $ready_n and $ready_body.
ready_n=""
ready_body=""
wait_ready() {
  local start=$SECONDS n
  while :; do
    ready_body=$(curl -fsS --max-time 2 "$READY_URL" 2>/dev/null) || ready_body=""
    n=$(printf '%s' "$ready_body" | sed -n 's/.*"readyConnections"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$n" ] && [ "$n" -ge 1 ]; then
      ready_n=$n
      return 0
    fi
    [ $((SECONDS - start)) -ge "$WAIT_MAX" ] && return 1
    sleep 1
  done
}

# mount_report FILE: read a mountinfo file and print "<path> ro" or "<path> RW"
# for each mount point at or under /run or /sys, using the effective mount,
# resolved top-down. Fields: 1 mount id, 2 parent id, 5 mount point, 6 options.
# Mount points are taken shallowest first. At a point P the candidates are the
# mounts whose parent is the effective mount of P's nearest ancestor mount
# point, plus mounts stacked on them at P itself (parent is another mount at
# P); the effective one is the topmost, which no other candidate has as parent.
# A stacked read-only bind therefore reports ro, and each sub-mount is judged
# under the effective parent, not under the covered one.
mount_report() {
  python3 -I -c '
import sys
ms = []
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) >= 6:
        ms.append((f[0], f[1], f[4], f[5].split(",")[0]))
at = {}
for m in ms:
    at.setdefault(m[2], []).append(m)
eff = {}
for p in sorted(at, key=lambda p: (p.count("/") if p != "/" else 0, p)):
    anc = None
    q = p
    while q != "/":
        q = q.rsplit("/", 1)[0] or "/"
        if q in eff:
            anc = eff[q][0]
            break
    ids = {m[0] for m in at[p]}
    roots = [m for m in at[p] if (m[1] == anc if anc else m[1] not in ids)]
    cand = list(roots)
    grew = True
    while grew:
        grew = False
        have = {m[0] for m in cand}
        for m in at[p]:
            if m[0] not in have and m[1] in have:
                cand.append(m)
                grew = True
    cand = cand or at[p]
    parents = {m[1] for m in cand}
    top = [m for m in cand if m[0] not in parents]
    eff[p] = max(top or cand, key=lambda m: int(m[0]))
for p in sorted(eff):
    if p in ("/run", "/sys") or p.startswith(("/run/", "/sys/")):
        print(p, "ro" if eff[p][3] == "ro" else "RW")
' "$1"
}

# The drop-in as it was before this run, saved before the first write.
prev_tmp=""
prev_exists=0
trap '[ -n "$prev_tmp" ] && rm -f "$prev_tmp"' EXIT
save_previous() {
  if [ -f "$DROPIN" ]; then
    prev_tmp=$(mktemp) && cp -p "$DROPIN" "$prev_tmp" || { echo "FAIL: save $DROPIN" >&2; exit 1; }
    prev_exists=1
  fi
}

# remove_dropin: no drop-in at all.
remove_dropin() {
  rm -f "$DROPIN" || echo "FAIL: rm $DROPIN" >&2
  rmdir "$DROPIN_DIR" 2>/dev/null || true
}

# Take the drop-in out and bring the tunnel back. $1 = "restart" or "norestart"
# (norestart: the running unit never loaded the drop-in, so put back exactly
# the previous drop-in, or no file, and only reload).
# With rollback_to_root=1 (--user, restart mode) the drop-in is rewritten as the
# root one instead of removed; if /ready does not come back with it, it is
# removed entirely and the unit restarted once more.
# Returns 0 when /ready is back, 1 when not, 2 when the drop-in is not ours.
rollback_to_root=0
back_out() {
  local what
  if foreign_dropin; then
    echo "FAIL: $DROPIN is no longer a file this script wrote; not touching it (rollback abandoned). Move it away and check: systemctl status cloudflared" >&2
    return 2
  fi
  if [ "$1" = norestart ]; then
    if [ "$prev_exists" = 1 ]; then
      what="previous drop-in restored byte for byte"
      cp -p "$prev_tmp" "$DROPIN" || echo "FAIL: restore $DROPIN" >&2
    else
      what="no drop-in (none existed before)"
      remove_dropin
    fi
    systemctl daemon-reload || echo "FAIL: daemon-reload (rollback)" >&2
    if wait_ready; then
      echo "rolled back: $what, daemon-reload done, no restart (the running unit never loaded the drop-in), /ready ok (readyConnections=$ready_n)"
      return 0
    fi
    echo "FAIL: rolled back ($what, no restart) but /ready is NOT ready after ${WAIT_MAX} s (last /ready: ${ready_body:-no answer}); check: journalctl -u cloudflared -n 50" >&2
    return 1
  fi
  if [ "$rollback_to_root" = 1 ]; then
    what="root drop-in restored"
    { print_dropin root > "$DROPIN" && chmod 0644 "$DROPIN"; } || echo "FAIL: rewrite $DROPIN" >&2
  else
    what="drop-in removed"
    remove_dropin
  fi
  systemctl daemon-reload || echo "FAIL: daemon-reload (rollback)" >&2
  systemctl restart cloudflared || echo "FAIL: restart cloudflared (rollback)" >&2
  if wait_ready; then
    echo "rolled back: $what, /ready back (readyConnections=$ready_n)"
    return 0
  fi
  if [ "$rollback_to_root" = 1 ]; then
    echo "FAIL: the root drop-in did not bring /ready back (last /ready: ${ready_body:-no answer}); removing the drop-in entirely" >&2
    remove_dropin
    systemctl daemon-reload || echo "FAIL: daemon-reload (rollback)" >&2
    systemctl restart cloudflared || echo "FAIL: restart cloudflared (rollback)" >&2
    if wait_ready; then
      echo "rolled back: host state: no drop-in (cloudflared unsandboxed), /ready back (readyConnections=$ready_n); the hardening is not installed"
      return 1
    fi
    echo "FAIL: host state: no drop-in (cloudflared unsandboxed), /ready is NOT ready after ${WAIT_MAX} s (last /ready: ${ready_body:-no answer}); check: journalctl -u cloudflared -n 50" >&2
    return 1
  fi
  echo "FAIL: rolled back but /ready is NOT ready after ${WAIT_MAX} s (last /ready: ${ready_body:-no answer}); check: journalctl -u cloudflared -n 50" >&2
  return 1
}

if [ "$mode" = remove ]; then
  echo "=== removing $DROPIN ==="
  back_out restart
  exit $?
fi

# fail STEP DETAIL RESTARTED: report, roll back, exit 1 (2 if the drop-in is not ours).
fail() {
  local rc
  echo "FAIL at step: $1 ($2)" >&2
  case "$1" in
    restart|"unit not active"|/ready)
      echo "hint: if it failed to start, try again without MemoryDenyWriteExecute, ReadOnlyPaths or BindReadOnlyPaths" >&2 ;;
  esac
  echo "=== rolling back ===" >&2
  back_out "$3"; rc=$?
  [ "$rc" -eq 2 ] && exit 2
  exit 1
}

echo "=== security score before ==="
before=$(systemd-analyze security "$UNIT" 2>&1 | tail -1)
echo "${before:-no output}"

save_previous
install -d -m 0755 "$ETC_DIR" "$DROPIN_DIR" || { echo "FAIL: create $DROPIN_DIR" >&2; exit 1; }
kind=root
[ "$user_mode" = 1 ] && kind=user
print_dropin "$kind" > "$DROPIN" || { echo "FAIL: write $DROPIN" >&2; exit 1; }
chmod 0644 "$DROPIN" || { echo "FAIL: chmod $DROPIN" >&2; exit 1; }
[ "$user_mode" = 1 ] && rollback_to_root=1
echo "wrote $DROPIN ($kind)"

echo "=== systemd-analyze verify ==="
systemd-analyze verify "$UNIT" || fail "systemd-analyze verify" "verify exited non-zero" norestart

systemctl daemon-reload || fail "daemon-reload" "daemon-reload failed" norestart
echo "=== restarting cloudflared ==="
systemctl restart cloudflared || fail "restart" "systemctl restart failed" restart

state=$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null)
[ "$state" = active ] || fail "unit not active" "ActiveState=${state:-unknown}" restart

if ! wait_ready; then
  fail "/ready" "readyConnections never reached 1 in ${WAIT_MAX} s (last /ready: ${ready_body:-no answer})" restart
fi
echo "ready: readyConnections=$ready_n"

mainpid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
# Uid: from status, not the owner of /proc/PID, which reads root for any
# non-dumpable process whatever its uid.
runs_as=""; runs_uid=""
if [ -n "$mainpid" ] && [ "$mainpid" != 0 ]; then
  runs_uid=$(awk '/^Uid:/ {print $2; exit}' "$PROC_DIR/$mainpid/status" 2>/dev/null) || runs_uid=""
  [ -n "$runs_uid" ] && { runs_as=$(id -nu "$runs_uid" 2>/dev/null) || runs_as=""; }
fi
echo "runs as: ${runs_as:-unknown}${runs_uid:+ (uid $runs_uid)}"
if [ "$user_mode" = 1 ]; then
  [ "$runs_as" = "$SVC_USER" ] || fail "runs as" "main process runs as ${runs_as:-unknown}, want $SVC_USER" restart
  echo "=== ls -l $CRED_DIR/ ==="
  ls -l "$CRED_DIR/" 2>&1 || echo "no credentials dir"
fi

echo "=== security score after ==="
echo "before: ${before:-no output}"
echo "after:  $(systemd-analyze security "$UNIT" 2>&1 | tail -1)"
echo "=== systemctl show ==="
systemctl show -p NRestarts,ActiveState cloudflared
echo "=== /run and /sys mounts of the main process, effective mount each (want ro) ==="
if [ -n "$mainpid" ] && [ "$mainpid" != 0 ] && [ -r "$PROC_DIR/$mainpid/mountinfo" ]; then
  mount_report "$PROC_DIR/$mainpid/mountinfo" || echo "mount report failed (non-fatal)"
else
  echo "no readable $PROC_DIR/${mainpid:-?}/mountinfo"
fi
echo "=== journalctl -u cloudflared -n 20 ==="
journalctl -u cloudflared -n 20 --no-pager
echo "OK: cloudflared hardened; fetch each hostname the tunnel serves from outside your network"
