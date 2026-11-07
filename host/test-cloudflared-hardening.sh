#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joe Fernandez
#
# Offline test of install-cloudflared-hardening.sh (found beside this file). Touches no real /etc
# or systemd: stub systemctl, systemd-analyze, journalctl, curl, useradd, id and
# runuser sit first on PATH in a temp bin dir, and the script is pointed at temp
# directories through ETC_DIR, READY_URL, WAIT_MAX, CF_CONFIG and
# HARDENING_ALLOW_NONROOT=1. Every stub appends its call to $LOG. Prints
# "ok    name" or "FAIL  name: why" per case and a final count. Exit 0 only
# if nothing failed.
#
#   ./test-cloudflared-hardening.sh
#
# Stub switches (environment of one run): STUB_READY_FAIL=1 (curl never
# answers), STUB_READY_AFTER=N (curl answers from its Nth call), STUB_READY_UNTIL=N
# (answers only up to its Nth call), STUB_READY_NODROPIN=1 (answers only while
# there is no drop-in), STUB_USER_EXISTS=1 (id finds the user), STUB_RUNS_UID=N
# (the Uid: line of the fake /proc/4242/status; default 999, which the id stub
# names cloudflared, 0 is root), STUB_CONFIG_UNREADABLE=1 (runuser's cat fails),
# STUB_VERIFY_FAIL=1 (systemd-analyze verify fails), STUB_RESTART_FAIL=N (the Nth
# restart fails), STUB_INACTIVE=1 (ActiveState is inactive), STUB_NO_UNIT=1
# (systemctl cat fails), STUB_FOREIGN_ON_RESTART=1 (a restart leaves a foreign
# hardening.conf behind). The userdel stub logs; the run helper fails any case
# that calls it or changes the sha256 of config.yml files or the credential.
# systemctl show -p MainPID prints 4242; /proc/4242 need not exist.
# SC2015: `test && ok || bad` is used throughout; ok and bad only echo and count,
# so the bad branch cannot run after a passing test.
# shellcheck disable=SC2015
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
SCRIPT="$HERE/install-cloudflared-hardening.sh"

pass=0; failn=0; skipn=0
ok()   { pass=$((pass + 1)); echo "ok    $1"; }
bad()  { failn=$((failn + 1)); echo "FAIL  $1: $2"; }
# check NAME WHY CMD...: ok if CMD succeeds
check() { local n="$1" w="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n" "$w"; fi; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; LOG="$T/calls.log"; mkdir -p "$BIN"
REAL_ID=$(command -v id)
PROC="$T/proc"; mkdir -p "$PROC/4242"

cat > "$BIN/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "cat cloudflared.service") [ "${STUB_NO_UNIT:-}" = 1 ] && exit 1 ;;
  "show -p MainPID --value"*) echo 4242 ;;
  "show -p ActiveState --value"*) if [ "${STUB_INACTIVE:-}" = 1 ]; then echo inactive; else echo active; fi ;;
  "show -p NRestarts,ActiveState"*) printf 'NRestarts=0\nActiveState=active\n' ;;
  "restart cloudflared")
    c=$(cat "$LOG.restart" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$LOG.restart"
    [ "${STUB_FOREIGN_ON_RESTART:-}" = 1 ] && printf '[Service]\nNice=5\n' > "$STUB_DROPIN"
    [ "${STUB_RESTART_FAIL:-0}" = "$c" ] && exit 1 ;;
esac
exit 0
STUB
cat > "$BIN/systemd-analyze" <<'STUB'
#!/bin/bash
echo "systemd-analyze $*" >> "$LOG"
[ "$1" = security ] && echo "-> Overall exposure level for cloudflared.service: 2.0 OK"
[ "$1" = verify ] && [ "${STUB_VERIFY_FAIL:-}" = 1 ] && exit 1
exit 0
STUB
cat > "$BIN/journalctl" <<'STUB'
#!/bin/bash
echo "journalctl $*" >> "$LOG"
exit 0
STUB
cat > "$BIN/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$LOG"
c=$(cat "$LOG.curl" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$LOG.curl"
[ "${STUB_READY_FAIL:-}" = 1 ] && exit 22
[ -n "${STUB_READY_AFTER:-}" ] && [ "$c" -lt "$STUB_READY_AFTER" ] && exit 22
[ -n "${STUB_READY_UNTIL:-}" ] && [ "$c" -gt "$STUB_READY_UNTIL" ] && exit 22
[ "${STUB_READY_NODROPIN:-}" = 1 ] && [ -e "$STUB_DROPIN" ] && exit 22
echo '{"status":200,"readyConnections":4}'
STUB
cat > "$BIN/userdel" <<'STUB'
#!/bin/bash
echo "userdel $*" >> "$LOG"
exit 0
STUB
cat > "$BIN/useradd" <<'STUB'
#!/bin/bash
echo "useradd $*" >> "$LOG"
exit 0
STUB
cat > "$BIN/id" <<STUB
#!/bin/bash
if [ "\$*" = cloudflared ]; then
  echo "id cloudflared" >> "\$LOG"
  [ "\${STUB_USER_EXISTS:-}" = 1 ]
  exit \$?
fi
if [ "\$1" = -nu ]; then
  echo "id \$*" >> "\$LOG"
  case "\$2" in 0) echo root ;; *) echo cloudflared ;; esac
  exit 0
fi
exec "$REAL_ID" "\$@"
STUB
cat > "$BIN/runuser" <<'STUB'
#!/bin/bash
echo "runuser $*" >> "$LOG"
[ "${STUB_CONFIG_UNREADABLE:-}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$BIN"/*

CRED="$T/cred.json"
printf '{"id":"z"}\n' > "$CRED"
CONF_OK="$T/config.yml"
printf 'tunnel: abc\n  credentials-file:   %s  \ningress: []\n' "$CRED" > "$CONF_OK"
CONF_QUOTED="$T/config-quoted.yml"
printf 'tunnel: abc\ncredentials-file: "%s"\n' "$CRED" > "$CONF_QUOTED"
CONF_NOLINE="$T/config-noline.yml"
printf 'tunnel: abc\ningress: []\n' > "$CONF_NOLINE"
CONF_METRICS="$T/config-metrics.yml"
printf 'tunnel: abc\ncredentials-file: %s\nmetrics: 0.0.0.0:20243 # local\n' "$CRED" > "$CONF_METRICS"
CONF_METRICS_Q="$T/config-metrics-q.yml"
printf 'tunnel: abc\ncredentials-file: %s\nmetrics: "localhost:9000"\n' "$CRED" > "$CONF_METRICS_Q"
CONF_NOFILE="$T/config-nofile.yml"
printf 'tunnel: abc\ncredentials-file: %s/absent.json\n' "$T" > "$CONF_NOFILE"

n=0; E=""; out=""; rc=0; before=""; after=""; sumbad=0; userdelbad=0
# newcase: fresh ETC_DIR and call log
newcase() { n=$((n + 1)); E="$T/etc$n"; mkdir -p "$E"; : > "$LOG"; rm -f "$LOG.curl" "$LOG.restart"; }
DI() { echo "$E/cloudflared.service.d/hardening.conf"; }
# run [VAR=val ...] -- ARGS...: run the script with the stubs, set $out and $rc
run() {
  local envs=() uid=999 e
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  for e in "${envs[@]}"; do case "$e" in STUB_RUNS_UID=*) uid="${e#*=}" ;; esac; done
  printf 'Name:\tcloudflared\nUid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" > "$PROC/4242/status"
  before=$(sha256sum "$CRED" "$T"/config*.yml)
  out=$(env PATH="$BIN:$PATH" LOG="$LOG" ETC_DIR="$E" READY_URL=http://stub/ready WAIT_MAX=2 PROC_DIR="$PROC" \
    STUB_DROPIN="$(DI)" CF_CONFIG="$CONF_OK" HARDENING_ALLOW_NONROOT=1 "${envs[@]}" "$SCRIPT" "$@" 2>&1); rc=$?
  after=$(sha256sum "$CRED" "$T"/config*.yml)
  [ "$before" = "$after" ] || { sumbad=$((sumbad + 1)); bad "config/credential unchanged" "sha256 differs in case $n"; }
  if called userdel; then userdelbad=$((userdelbad + 1)); bad "no userdel" "userdel called in case $n"; fi
}
called() { grep -q "$1" "$LOG"; }
# the unit was reloaded or restarted (the read-only unit checks do not count)
changed_unit() { called 'systemctl restart\|systemctl daemon-reload'; }
restarts() { grep -c 'systemctl restart cloudflared' "$LOG"; }
MARK='# Installed by install-cloudflared-hardening.sh.'
# a root drop-in: present, sandboxed, no User= or LoadCredential= line
is_root_dropin() {
  [ -f "$(DI)" ] && grep -qx 'CapabilityBoundingSet=' "$(DI)" \
    && ! grep -Eq '^(User|Group|LoadCredential|Environment)=' "$(DI)"
}
is_user_dropin() {
  local f; f="$(DI)"
  [ -f "$f" ] && grep -qx 'User=cloudflared' "$f" && grep -qx 'Group=cloudflared' "$f" \
    && grep -qx "LoadCredential=tunnel.json:$CRED" "$f" \
    && grep -qx 'Environment=TUNNEL_CRED_FILE=%d/tunnel.json' "$f"
}
USER_DROPIN_TEXT="$MARK"$'\n[Service]\nUser=cloudflared\nGroup=cloudflared\n'
FOREIGN_TEXT=$'[Service]\nNice=5\n'

# 1. dry runs
newcase; run -- --dry-run
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qx 'CapabilityBoundingSet=' && ! printf '%s' "$out" | grep -q '^User=' \
  && [ ! -e "$E/cloudflared.service.d" ] && [ ! -s "$LOG" ] \
  && ok "dry-run prints the root drop-in and writes nothing" || bad "dry-run" "rc=$rc"

newcase; run -- --dry-run --user
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qx 'User=cloudflared' \
   && printf '%s' "$out" | grep -qx "LoadCredential=tunnel.json:$CRED" \
   && printf '%s' "$out" | grep -qx 'Environment=TUNNEL_CRED_FILE=%d/tunnel.json' \
   && printf '%s' "$out" | grep -q 'ensure the user cloudflared' && printf '%s' "$out" | grep -q 'runs as' \
   && [ ! -e "$E/cloudflared.service.d" ] && [ ! -s "$LOG" ]; then
  ok "dry-run --user prints the user block with the resolved credential path, writes nothing"
else bad "dry-run --user" "rc=$rc out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi

newcase; run CF_CONFIG="$CONF_NOLINE" -- --dry-run --user
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "FAIL: credentials-file not found in $CONF_NOLINE" \
  && ok "dry-run --user with no credentials-file line fails" || bad "dry-run --user, no line" "rc=$rc"

# 2. plain install
newcase; run -- 
if [ "$rc" -eq 0 ] && is_root_dropin && called 'systemctl restart cloudflared' && ! called useradd \
   && printf '%s' "$out" | grep -q 'ready: readyConnections=4' && printf '%s' "$out" | grep -q '^runs as: cloudflared'; then
  ok "plain install: root drop-in (no User=), restarted, ready, exit 0, runs-as printed"
else bad "plain install" "rc=$rc out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi

newcase; run STUB_RUNS_UID=0 -- 
[ "$rc" -eq 0 ] && is_root_dropin && printf '%s' "$out" | grep -q '^runs as: root' \
  && ok "plain install: runs as root is printed, not judged" || bad "plain install runs-as root" "rc=$rc"

newcase; run STUB_READY_UNTIL=1 -- 
[ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && called 'systemctl restart cloudflared' \
  && ok "plain install: /ready never ready, drop-in removed, exit 1" || bad "plain install, not ready" "rc=$rc"

# 3. --user
newcase; run -- --user
if [ "$rc" -eq 0 ] && called 'useradd .*--system' && called 'useradd .*--no-create-home' \
   && called 'useradd .*--shell /usr/sbin/nologin' && is_user_dropin && called 'systemctl restart cloudflared' \
   && printf '%s' "$out" | grep -q '^user cloudflared: created' && printf '%s' "$out" | grep -q '^runs as: cloudflared' \
   && printf '%s' "$out" | grep -q 'no readable .*/proc/4242/mountinfo'; then
  ok "--user, user absent: useradd --system, four lines with the resolved path, exit 0"
else bad "--user, user absent" "rc=$rc out=$(printf '%s' "$out" | tail -n 4 | tr '\n' '|')"; fi

newcase; run STUB_USER_EXISTS=1 -- --user
[ "$rc" -eq 0 ] && ! called useradd && is_user_dropin && printf '%s' "$out" | grep -q '^user cloudflared: exists' \
  && ok "--user, user present: useradd not called" || bad "--user, user present" "rc=$rc"

newcase; run CF_CONFIG="$CONF_QUOTED" STUB_USER_EXISTS=1 -- --user
[ "$rc" -eq 0 ] && is_user_dropin && ok "--user: quoted credentials-file path is unquoted" || bad "--user quoted" "rc=$rc"

newcase; run CF_CONFIG="$CONF_NOLINE" -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && [ ! -e "$E/cloudflared.service.d" ] && ! called systemctl && ! called useradd \
   && printf '%s' "$out" | grep -q "FAIL: credentials-file not found in $CONF_NOLINE"; then
  ok "--user, no credentials-file line: exit 1, nothing written, no restart, no useradd"
else bad "--user, no line" "rc=$rc out=$out"; fi

newcase; run CF_CONFIG="$CONF_NOFILE" -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && ! called systemctl && ! called useradd \
   && printf '%s' "$out" | grep -q "FAIL: credential $T/absent.json is not a file"; then
  ok "--user, credential file missing: exit 1, nothing written, no restart, no useradd"
else bad "--user, no file" "rc=$rc out=$out"; fi

newcase; run STUB_USER_EXISTS=1 STUB_CONFIG_UNREADABLE=1 -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && ! changed_unit && called 'runuser -u cloudflared -- cat' \
   && printf '%s' "$out" | grep -q 'not readable by cloudflared' && printf '%s' "$out" | grep -q 'nothing changed'; then
  ok "--user, config unreadable by the user (user existed): exit 1, nothing written, no restart, 'nothing changed'"
else bad "--user, config unreadable" "rc=$rc out=$(printf '%s' "$out" | tail -n 2 | tr '\n' '|')"; fi

newcase; run STUB_USER_EXISTS=1 -- --user
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^runs as: cloudflared (uid 999)' && called 'id -nu 999' \
  && ok "--user: runs as read from Uid: of status, not the /proc owner" || bad "--user, runs-as source" "rc=$rc"

newcase; run CF_CONFIG="$T/no-such-config.yml" -- --user
[ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && ! called systemctl \
  && ok "--user, config.yml missing: exit 1, nothing written" || bad "--user, no config" "rc=$rc"

newcase; run STUB_READY_UNTIL=1 STUB_USER_EXISTS=1 -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && [ "$(restarts)" -eq 3 ] \
   && printf '%s' "$out" | grep -q 'host state: no drop-in (cloudflared unsandboxed), /ready is NOT ready'; then
  ok "--user, /ready never ready, root rollback too: drop-in removed, restarted again, state named, exit 1"
else bad "--user, not ready" "rc=$rc out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi

newcase; run STUB_RUNS_UID=0 STUB_USER_EXISTS=1 -- --user
if [ "$rc" -eq 1 ] && is_root_dropin && printf '%s' "$out" | grep -q 'FAIL at step: runs as' \
   && [ "$(grep -c 'systemctl restart cloudflared' "$LOG")" -eq 2 ]; then
  ok "--user, main process runs as root: exit 1, rolled back to the ROOT drop-in, restarted again"
else bad "--user, runs as root" "rc=$rc restarts=$(grep -c 'systemctl restart' "$LOG")"; fi

# 4. refusal, --root, --remove, flags
newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$USER_DROPIN_TEXT" > "$(DI)"
run -- 
if [ "$rc" -eq 2 ] && [ "$(cat "$(DI)"; echo x)" = "${USER_DROPIN_TEXT}x" ] && ! called systemctl \
   && printf '%s' "$out" | grep -q 'drop-in is in user mode; rerun with --user, or --root to go back to root'; then
  ok "plain install over a user-mode drop-in: exit 2, file unchanged, no restart"
else bad "plain over user mode" "rc=$rc"; fi

newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$USER_DROPIN_TEXT" > "$(DI)"
run -- --root
[ "$rc" -eq 0 ] && is_root_dropin && called 'systemctl restart cloudflared' \
  && ok "--root over a user-mode drop-in: root drop-in, restarted, exit 0" || bad "--root over user mode" "rc=$rc"

newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$USER_DROPIN_TEXT" > "$(DI)"
run STUB_USER_EXISTS=1 -- --user
[ "$rc" -eq 0 ] && is_user_dropin && ok "--user over a user-mode drop-in: rewritten, exit 0" || bad "--user rerun" "rc=$rc"

newcase; run -- --user >/dev/null; run -- --remove
[ "$rc" -eq 0 ] && [ ! -e "$(DI)" ] && called 'systemctl restart cloudflared' && ! called userdel \
  && ok "--remove: drop-in gone, restarted, exit 0" || bad "--remove" "rc=$rc"

for combo in "--user --remove" "--dry-run --root" "--user --root" "--bogus" "--dry-run --user --user"; do
  newcase
  # shellcheck disable=SC2086  # the words are the arguments
  run -- $combo
  [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'usage: ' && [ ! -e "$(DI)" ] && ! called systemctl \
    && ok "flags '$combo': usage, exit 2, nothing done" || bad "flags '$combo'" "rc=$rc"
done

# 5. fix 1: user-mode failure whose root rollback also fails
newcase; run STUB_READY_NODROPIN=1 STUB_USER_EXISTS=1 -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && [ ! -e "$E/cloudflared.service.d" ] && [ "$(restarts)" -eq 3 ] \
   && printf '%s' "$out" | grep -q 'the root drop-in did not bring /ready back' \
   && printf '%s' "$out" | grep -q 'host state: no drop-in (cloudflared unsandboxed), /ready back (readyConnections=4)'; then
  ok "--user, root rollback also not ready: drop-in removed, restart, ready, exit 1, state named"
else bad "--user, root rollback fails" "rc=$rc restarts=$(restarts) out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi

newcase; run STUB_USER_EXISTS=1 STUB_RESTART_FAIL=1 -- --user
if [ "$rc" -eq 1 ] && is_root_dropin && [ "$(restarts)" -eq 2 ] && printf '%s' "$out" | grep -q 'rolled back: root drop-in restored, /ready back' \
   && printf '%s' "$out" | grep -q '^hint: if it failed to start'; then
  ok "--user, first restart fails: ROOT drop-in restored and restarted, ready, exit 1, start hint printed"
else bad "--user, restart fails" "rc=$rc restarts=$(restarts)"; fi

newcase; run STUB_RESTART_FAIL=1 --
[ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && [ "$(restarts)" -eq 2 ] && printf '%s' "$out" | grep -q '^hint: if it failed to start' \
  && ok "plain install, restart fails: drop-in removed, restarted, exit 1, start hint printed" || bad "plain, restart fails" "rc=$rc"

# 6. fix 2: a drop-in without the marker is never touched
for args in "" "--user" "--root" "--remove"; do
  newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$FOREIGN_TEXT" > "$(DI)"
  # shellcheck disable=SC2086  # the words are the arguments
  run STUB_USER_EXISTS=1 -- $args
  if [ "$rc" -eq 2 ] && [ "$(cat "$(DI)"; echo x)" = "${FOREIGN_TEXT}x" ] && ! changed_unit && ! called useradd \
     && [ "$(ls -A "$E/cloudflared.service.d" | wc -l)" -eq 1 ] \
     && printf '%s' "$out" | grep -qF "$(DI)" && printf '%s' "$out" | grep -q 'Move it away'; then
    ok "foreign hardening.conf, '${args:-plain}': exit 2, file untouched, named, move-away advice, no backup, no reload"
  else bad "foreign hardening.conf '${args:-plain}'" "rc=$rc out=$out"; fi
done

# The marker as the 2026-11-05 version wrote it, with tools/ before the name
# (the host's live drop-in): ours, not foreign.
newcase; mkdir -p "$E/cloudflared.service.d"; printf '# Installed by tools/install-cloudflared-hardening.sh (posture review 2026-11-04, F1)\n[Service]\nProtectSystem=strict\n' > "$(DI)"
run -- --remove
[ "$rc" -eq 0 ] && [ ! -e "$(DI)" ] \
  && ok "old marker with a directory before the script name: ours, --remove proceeds" || bad "old marker" "rc=$rc out=$out"

newcase; mkdir -p "$E/cloudflared.service.d"; printf '[Service]\nUser=cloudflared\n' > "$(DI)"
run --
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "$(DI)" && printf '%s' "$out" | grep -q 'not written by this script' && ! changed_unit \
  && ok "foreign drop-in with User=cloudflared and no marker: refused as foreign" || bad "foreign with User=" "rc=$rc"

newcase; run STUB_USER_EXISTS=1 STUB_RESTART_FAIL=1 STUB_FOREIGN_ON_RESTART=1 -- --user
if [ "$rc" -eq 2 ] && [ "$(cat "$(DI)"; echo x)" = "${FOREIGN_TEXT}x" ] && [ "$(restarts)" -eq 1 ] \
   && [ "$(grep -c 'systemctl daemon-reload' "$LOG")" -eq 1 ] \
   && printf '%s' "$out" | grep -q 'rollback abandoned'; then
  ok "foreign drop-in appearing mid-run: rollback refuses, file untouched, no second restart, exit 2"
else bad "foreign on rollback" "rc=$rc restarts=$(restarts) out=$(printf '%s' "$out" | tail -n 2 | tr '\n' '|')"; fi

# 7. fix 3: a verify failure puts back exactly what was there
PREV_TEXT="$MARK"$'\n# local note kept\n[Service]\nNoNewPrivileges=yes\n'
for args in "" "--user"; do
  newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$PREV_TEXT" > "$(DI)"; chmod 0640 "$(DI)"
  cp -p "$(DI)" "$T/prev.bytes"
  # shellcheck disable=SC2086  # the words are the arguments
  run STUB_VERIFY_FAIL=1 STUB_USER_EXISTS=1 -- $args
  if [ "$rc" -eq 1 ] && cmp -s "$(DI)" "$T/prev.bytes" && [ "$(stat -c %a "$(DI)")" = 640 ] \
     && called 'systemctl daemon-reload' && [ "$(restarts)" -eq 0 ] \
     && printf '%s' "$out" | grep -q 'previous drop-in restored byte for byte'; then
    ok "verify fails (${args:-plain}) over an earlier drop-in: restored byte for byte and mode, daemon-reload, no restart, exit 1"
  else bad "verify fail restore '${args:-plain}'" "rc=$rc restarts=$(restarts) out=$(printf '%s' "$out" | tail -n 2 | tr '\n' '|')"; fi
done

newcase; run STUB_VERIFY_FAIL=1 STUB_USER_EXISTS=1 -- --user
if [ "$rc" -eq 1 ] && [ ! -e "$(DI)" ] && [ ! -e "$E/cloudflared.service.d" ] && called 'systemctl daemon-reload' && [ "$(restarts)" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'no drop-in (none existed before)'; then
  ok "--user verify fails with no earlier drop-in: no file left (not the root drop-in), daemon-reload, no restart"
else bad "--user verify fail, none before" "rc=$rc"; fi

# 8. fix 4: the unit's state is checked before anything changes
newcase; run STUB_INACTIVE=1 --
if [ "$rc" -eq 2 ] && [ ! -e "$E/cloudflared.service.d" ] && ! changed_unit \
   && printf '%s' "$out" | grep -q 'unit is not active; start it first, or this script would start it'; then
  ok "inactive unit: exit 2, nothing written, no restart"
else bad "inactive unit" "rc=$rc out=$out"; fi

newcase; run STUB_INACTIVE=1 STUB_USER_EXISTS=0 -- --user
[ "$rc" -eq 2 ] && [ ! -e "$E/cloudflared.service.d" ] && ! changed_unit && ! called useradd \
  && ok "--user, inactive unit: exit 2 before useradd" || bad "--user inactive" "rc=$rc"

newcase; run STUB_NO_UNIT=1 --
if [ "$rc" -eq 2 ] && [ ! -e "$E/cloudflared.service.d" ] && ! changed_unit && printf '%s' "$out" | grep -q 'no such unit'; then
  ok "missing unit: exit 2 'no such unit', nothing written, no wait"
else bad "no unit" "rc=$rc out=$out"; fi

newcase; mkdir -p "$E/cloudflared.service.d"; printf '%s' "$USER_DROPIN_TEXT" > "$(DI)"
run STUB_INACTIVE=1 -- --remove
[ "$rc" -eq 2 ] && [ -f "$(DI)" ] && ! changed_unit \
  && ok "--remove with an inactive unit: exit 2, drop-in kept, no restart" || bad "--remove inactive" "rc=$rc"

newcase; run -- --remove
if [ "$rc" -eq 0 ] && ! called 'systemctl restart' && ! called 'systemctl daemon-reload' && ! called curl \
   && printf '%s' "$out" | grep -q 'nothing to remove'; then
  ok "--remove with no drop-in: exit 0, 'nothing to remove', no restart"
else bad "--remove nothing" "rc=$rc out=$out"; fi

# 9. fix 5: the /ready address
newcase; run READY_URL= CF_CONFIG="$CONF_METRICS" STUB_READY_AFTER=2 --
if [ "$rc" -eq 0 ] && is_root_dropin && called 'curl .*http://127.0.0.1:20243/ready' && ! called 'curl .*20241' && [ "$(grep -c '^curl' "$LOG")" -ge 2 ] \
   && printf '%s' "$out" | grep -q 'metrics address: 127.0.0.1:20243'; then
  ok "metrics: 0.0.0.0:20243 in config.yml: /ready read at 127.0.0.1:20243, no probe of 20241, polled until ready"
else bad "metrics honoured" "rc=$rc out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi

newcase; run READY_URL= CF_CONFIG="$CONF_METRICS_Q" --
[ "$rc" -eq 0 ] && called 'curl .*http://localhost:9000/ready' \
  && ok "metrics: \"localhost:9000\" (quoted) is honoured" || bad "metrics quoted" "rc=$rc"

newcase; run READY_URL= --
[ "$rc" -eq 0 ] && called 'curl .*http://127.0.0.1:20241/ready' && is_root_dropin \
  && ok "no metrics: line: the default 127.0.0.1:20241 is probed before the change, then used" || bad "default probe" "rc=$rc"

for args in "" "--user"; do
  newcase
  # shellcheck disable=SC2086  # the words are the arguments
  run READY_URL= STUB_READY_FAIL=1 -- $args
  if [ "$rc" -eq 2 ] && [ ! -e "$E/cloudflared.service.d" ] && ! changed_unit && ! called useradd \
     && ! printf '%s' "$out" | grep -q '^hint:' \
     && printf '%s' "$out" | grep -q 'metrics address could not be found' && printf '%s' "$out" | grep -q 'READY_URL='; then
    ok "port probe fails (${args:-plain}): exit 2 before any write, READY_URL remedy named, no start hint"
  else bad "probe fails '${args:-plain}'" "rc=$rc out=$out"; fi
done

newcase; run STUB_USER_EXISTS=1 STUB_RUNS_UID=0 -- --user
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL at step: runs as' && ! printf '%s' "$out" | grep -q '^hint:' \
  && ok "'runs as' failure prints no start hint" || bad "runs-as hint" "rc=$rc"

# 10. fix 6: the message after useradd
newcase; run STUB_CONFIG_UNREADABLE=1 -- --user
if [ "$rc" -eq 1 ] && called 'useradd' && [ ! -e "$(DI)" ] && ! changed_unit \
   && printf '%s' "$out" | grep -q 'the user cloudflared was created; nothing else changed' \
   && ! printf '%s' "$out" | grep -q 'nothing changed'; then
  ok "--user, user created then config unreadable: says the user was created, not 'nothing changed'"
else bad "created then unreadable" "rc=$rc out=$(printf '%s' "$out" | tail -n 2 | tr '\n' '|')"; fi

# 11. every run left config.yml and the credential alone and never called userdel
[ "$sumbad" -eq 0 ] && ok "config.yml files and the credential byte-identical (sha256) before and after every run" \
  || bad "sha256 check" "$sumbad runs changed a file"
[ "$userdelbad" -eq 0 ] && ok "userdel never called in any run" || bad "userdel" "$userdelbad runs"

echo "$pass passed, $failn failed, $skipn skipped"
[ "$failn" -eq 0 ]
