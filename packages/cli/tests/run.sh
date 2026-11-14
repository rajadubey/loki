#!/usr/bin/env bash
# Test suite for loki.sh. No framework: plain bash, BSD + GNU userland.
#   bash packages/cli/tests/run.sh        (from anywhere)
# Every test runs in its own sandbox: HOME, fake nginx/sudo/pgrep/scp/curl
# first on PATH, and a temp nginx conf dir. Exits non-zero on any failure.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLI=$(dirname "$HERE")
SRC="$CLI/loki.sh"
REAL_REMOTE=/opt/homebrew/etc/nginx/remote.conf
REAL_SUM=""; [ -f "$REAL_REMOTE" ] && REAL_SUM=$(cksum < "$REAL_REMOTE")
ORIG_PATH=$PATH
REAL_NGINX=$(pgrep -f 'nginx: master' 2>/dev/null | head -1)
VERSION=$(sed -n 's/^VERSION=//p' "$SRC")

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/loki-tests.XXXXXX") || exit 2
TMPROOT=$(cd "$TMPROOT" && pwd -P)
trap 'chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
FAKEBIN="$TMPROOT/bin"
FALLBACK="$TMPROOT/fallback"
mkdir -p "$FAKEBIN"
unset LOKI_SSH_HOST LOKI_SSH_USER LOKI_SSH_PORT LOKI_REMOTE_MACHINES_JSON TMUX EDITOR

# Tests run a copy of loki.sh whose hardcoded fallback conf dirs point into the
# sandbox, so nothing can ever land in /opt/homebrew, /usr/local or /etc.
LOKI="$TMPROOT/loki.sh"
sed "s|\"/opt/homebrew/etc/nginx\" \"/usr/local/etc/nginx\" \"/etc/nginx\"|\"$FALLBACK/a\" \"$FALLBACK/b\" \"$FALLBACK/c\"|" "$SRC" > "$LOKI"
if grep -qE '/opt/homebrew|/usr/local/etc|"/etc/nginx"' "$LOKI"; then
  echo "ABORT: could not redirect loki.sh fallback dirs into the sandbox" >&2; exit 2
fi

# ---------- fakes (shared; controlled per test via files in $FAKE) ----------
cat > "$FAKEBIN/nginx" <<'EOF'
#!/usr/bin/env bash
echo "nginx $*" >> "$FAKE/calls.log"
if [ "${1-}" = -t ]; then
  if [ -f "$FAKE/t_output" ]; then cat "$FAKE/t_output" >&2
  elif [ -f "$FAKE/fail_t" ]; then
    printf 'nginx: [emerg] unexpected "}" in %s/remote.conf:3\nnginx: configuration file %s/nginx.conf test failed\n' "$FAKE_CONF" "$FAKE_CONF" >&2
  else
    printf 'nginx: the configuration file %s/nginx.conf syntax is ok\nnginx: configuration file %s/nginx.conf test is successful\n' "$FAKE_CONF" "$FAKE_CONF" >&2
  fi
  [ ! -f "$FAKE/fail_t" ]; exit
fi
if [ "${1-} ${2-}" = "-s reload" ]; then
  cat "$HOME/.loki/active" > "$FAKE/active_at_reload" 2>/dev/null || echo "<none>" > "$FAKE/active_at_reload"
  [ -f "$FAKE/fail_reload" ] && { echo 'nginx: [error] invalid PID number "" in "/x/nginx.pid"' >&2; exit 1; }
fi
# bare `nginx` = start; fail_start holds the error to print
if [ $# -eq 0 ] && [ -f "$FAKE/fail_start" ]; then cat "$FAKE/fail_start" >&2; exit 1; fi
exit 0
EOF
# Never let tests reach the real pkill: it would stop the developer's running nginx.
cat > "$FAKEBIN/pkill" <<'EOF'
#!/usr/bin/env bash
echo "pkill $*" >> "$FAKE/calls.log"
exit 0
EOF
cat > "$FAKEBIN/sudo" <<'EOF'
#!/usr/bin/env bash
# "Elevates" by unlocking the conf dir for the duration of the command.
echo "sudo $*" >> "$FAKE/sudo.log"
locked=0; [ -w "$FAKE_CONF" ] || { locked=1; chmod u+w "$FAKE_CONF"; }
"$@"; rc=$?
[ $locked = 1 ] && chmod u-w "$FAKE_CONF"
exit $rc
EOF
cat > "$FAKEBIN/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "pgrep $*" >> "$FAKE/pgrep.log"
[ -f "$FAKE/root_nginx" ] && { echo 1; exit 0; }
# master_running: an nginx master owned by the user (not matched by `-u 0`)
case "$*" in *"-u 0"*) ;; *) [ -f "$FAKE/master_running" ] && { echo 1; exit 0; } ;; esac
exit 1
EOF
cat > "$FAKEBIN/scp" <<'EOF'
#!/usr/bin/env bash
echo "scp $*" >> "$FAKE/scp.log"
dest="${!#}"
# Like real scp/sftp: the destination is truncated before a transfer that dies.
[ -f "$FAKE/fail_scp" ] && { : > "$dest"; echo "scp: Connection closed" >&2; exit 1; }
cp "$FAKE/remote.json" "$dest"
EOF
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
# $FAKE/curl_<port> holds "<exit code> <http code>"; default: refused.
echo "curl $*" >> "$FAKE/curl.log"
url="${!#}"; rc=7; code=000
[ -f "$FAKE/curl_${url##*:}" ] && read -r rc code < "$FAKE/curl_${url##*:}"
printf '%s' "$code"; exit "$rc"
EOF
chmod +x "$FAKEBIN"/*

# ---------- helpers ----------
ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }
pass() { echo . >> "$SB/meta/asserts"; }
fail() { echo . >> "$SB/meta/asserts"; echo "$*" >> "$SB/meta/failures"; }
skip() { echo "$*" > "$SB/meta/skip"; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1"$'\n'"    expected: [$2]"$'\n'"    got:      [$3]"; fi; }
has() { case "$3" in *"$2"*) pass ;; *) fail "$1: [$2] not in:"$'\n'"$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1: [$2] unexpectedly in:"$'\n'"$3" ;; *) pass ;; esac; }
check() { local m=$1; shift; if "$@"; then pass; else fail "$m"; fi; }
rc_fail() { if [ "$RC" -ne 0 ]; then pass; else fail "$1: expected non-zero exit, output:"$'\n'"$OUT"; fi; }
rc_ok() { if [ "$RC" -eq 0 ]; then pass; else fail "$1: exit $RC, output:"$'\n'"$OUT"; fi; }

# loki <args>: runs the script; sets OUT (stdout+stderr, colors stripped) and RC.
loki() {
  case "$HOME" in "$TMPROOT"/*) ;; *) echo "ABORT: HOME=$HOME is not the sandbox" >&2; exit 99 ;; esac
  OUT=$("$BASH" "$LOKI" "$@" 2>&1); RC=$?
  OUT=$(printf '%s' "$OUT" | strip)
}
calls() { [ -f "$FAKE/calls.log" ] && tr '\n' ',' < "$FAKE/calls.log"; }
L() { echo "$HOME/.loki/$1"; }
DEST() { echo "$FAKE_CONF/remote.conf"; }
active() { cat "$(L active)" 2>/dev/null || echo "<none>"; }
set_active() { printf '%s\n' "$1" > "$(L active)"; }
machines() {
  cat > "$(L machine.json)" <<'EOF'
{
  "m1": {"ip": "10.0.0.1", "services": {
    "web": {"local": 8080, "remote": 80},
    "api": {"local": 9000, "remote": 9001},
    "broken": {"local": null, "remote": 81},
    "half": {"local": 7000}
  }},
  "m2": {"ip": "10.0.0.2", "services": {"ssh": {"local": 2222, "remote": 22}}}
}
EOF
}
header_ok() {  # header_ok <file> <name> <ip>
  local ip; ip=$(printf '%s' "$3" | sed 's/\./\\./g')
  head -1 "$1" | grep -qE "^# Auto-generated remote\.conf for $2 \($ip\) \[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]\$"
}
lines() { wc -l < "$1" | tr -d ' '; }

# ---------- tests ----------

test_syntax_all_scripts() {
  local f
  for f in loki.sh install.sh uninstall.sh; do check "bash -n $f" bash -n "$CLI/$f"; done
}

test_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || { skip "shellcheck not installed"; return; }
  check "shellcheck -S warning loki.sh" shellcheck -S warning "$SRC"
}

test_sandbox_copy_only_changes_fallback_dirs() {
  eq "diff lines" 2 "$(diff "$SRC" "$LOKI" | grep -c '^[<>]')"
}

test_unknown_command_prints_usage() {
  loki frobnicate
  has "usage" "Usage: loki <command>" "$OUT"
  has "lists connect" "connect <machine>" "$OUT"
}

test_version_line() {
  check "VERSION is semver" grep -qE '^VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$SRC"
  loki
  has "version line" $'\n'"version:$VERSION"$'\n' "$OUT"
}

test_connect_happy_path() {
  machines; set_active m2
  loki connect m1
  rc_ok "connect"
  eq "active file" "m1" "$(active)"
  eq "active is name + newline" "$(printf 'm1\n' | cksum)" "$(cksum < "$(L active)")"
  eq "nginx call order" "nginx -t,nginx -t,nginx -s reload," "$(calls)"
  eq "active not yet written at reload" "m2" "$(cat "$FAKE/active_at_reload")"
  check "header line format" header_ok "$(DEST)" m1 10.0.0.1
  { head -1 "$(DEST)"; printf '\nupstream api {\n    server 10.0.0.1:9001;\n}\nserver {\n    listen 9000;\n    proxy_pass api;\n}\n'
    printf '\nupstream web {\n    server 10.0.0.1:80;\n}\nserver {\n    listen 8080;\n    proxy_pass web;\n}\n'; } > "$SB/expected"
  check "remote.conf exact (sorted, null ports skipped)" cmp -s "$SB/expected" "$(DEST)"
  check "staged copy matches installed" cmp -s "$(L remote.conf)" "$(DEST)"
  has "success message" "Connected to: m1" "$OUT"
}

test_connect_unknown_machine() {
  machines; set_active m2
  loki connect nope
  rc_fail "connect nope"
  has "error" "Machine 'nope' not found" "$OUT"
  eq "active unchanged" m2 "$(active)"
  eq "nginx untouched" "" "$(calls)"
}

test_connect_without_machine_json() {
  loki connect m1
  rc_fail "connect"
  has "error" "machine.json not found" "$OUT"
  eq "no active" "<none>" "$(active)"
}

test_connect_without_name() {
  machines
  loki connect
  rc_fail "connect"
  has "usage" "Usage: loki connect <machine>" "$OUT"
}

test_connect_failed_test_restores_previous() {
  machines; set_active m2
  printf '# previous\nstream stuff;\n\ttabs \xe2\x9c\x93\n' > "$(DEST)"; cp "$(DEST)" "$SB/prev"
  touch "$FAKE/fail_t"
  loki connect m1
  rc_fail "connect"
  has "error" "nginx rejected the new config" "$OUT"
  eq "active unchanged" m2 "$(active)"
  check "previous remote.conf restored byte-for-byte" cmp -s "$SB/prev" "$(DEST)"
  hasnt "no reload" "reload" "$(calls)"
}

test_connect_failed_test_without_previous_writes_empty() {
  machines
  touch "$FAKE/fail_t"
  loki connect m1
  rc_fail "connect"
  check "remote.conf exists" test -f "$(DEST)"
  eq "remote.conf empty" 0 "$(wc -c < "$(DEST)" | tr -d ' ')"
  eq "no active" "<none>" "$(active)"
}

test_connect_failed_test_ignores_stale_prev() {
  # A remote.conf.prev left behind by an earlier run must not be "restored".
  machines
  echo "stale" > "$(DEST).prev"
  touch "$FAKE/fail_t"
  loki connect m1
  rc_fail "connect"
  eq "remote.conf empty" 0 "$(wc -c < "$(DEST)" | tr -d ' ')"
}

test_connect_failed_reload() {
  machines; set_active m2
  touch "$FAKE/fail_reload" "$FAKE/master_running"  # nginx runs but refuses the reload
  loki connect m1
  rc_fail "connect"
  has "error" "nginx reload failed" "$OUT"
  eq "active unchanged" m2 "$(active)"
  hasnt "running nginx not killed" "pkill" "$(calls)"
  hasnt "running nginx not restarted" "nginx ," "$(calls),"
}

test_reload_starts_nginx_when_not_running() {
  machines; set_active m2
  touch "$FAKE/fail_reload"  # stale pid file, no master: reload can't work
  loki connect m1
  rc_ok "connect"
  has "stragglers stopped" "pkill -f nginx: (master|worker)" "$(calls)"
  has "nginx started" "nginx -s reload,pkill -f nginx: (master|worker),nginx ," "$(calls),"
  eq "active switched" m1 "$(active)"
}

test_start_retries_while_address_in_use() {
  machines; set_active m2
  touch "$FAKE/fail_reload"
  echo 'nginx: [emerg] bind() to 0.0.0.0:1111 failed (48: Address already in use)' > "$FAKE/fail_start"
  export LOKI_START_ATTEMPTS=2
  loki connect m1
  rc_fail "connect"
  has "error shown" "Address already in use" "$OUT"
  eq "retried" 2 "$(grep -c '^nginx $' "$FAKE/calls.log")"
  eq "active unchanged" m2 "$(active)"
}

test_start_does_not_retry_other_errors() {
  machines; set_active m2
  touch "$FAKE/fail_reload"
  echo 'nginx: [emerg] unknown directive "x" in nginx.conf:1' > "$FAKE/fail_start"
  loki connect m1
  rc_fail "connect"
  has "error shown" "unknown directive" "$OUT"
  eq "no retry" 1 "$(grep -c '^nginx $' "$FAKE/calls.log")"
}

test_reload_without_active() {
  machines
  loki reload
  rc_fail "reload"
  has "error" "No active machine" "$OUT"
  eq "nginx untouched" "" "$(calls)"
}

test_reload_regenerates_active() {
  machines; set_active m2
  loki reload
  rc_ok "reload"
  check "header" header_ok "$(DEST)" m2 10.0.0.2
  has "service" "listen 2222;" "$(cat "$(DEST)")"
  eq "call order" "nginx -t,nginx -t,nginx -s reload," "$(calls)"
}

test_reload_no_withconfig_header_only() {
  machines; set_active m1
  loki reload --no-withConfig
  rc_ok "reload"
  eq "one line" 1 "$(lines "$(DEST)")"
  check "header" header_ok "$(DEST)" m1 10.0.0.1
  eq "active unchanged" m1 "$(active)"
}

test_disconnect_success() {
  machines; set_active m1
  loki disconnect
  rc_ok "disconnect"
  eq "active cleared" "<none>" "$(active)"
  eq "header only" 1 "$(lines "$(DEST)")"
  check "header" header_ok "$(DEST)" m1 10.0.0.1
  eq "reload happened while still active" m1 "$(cat "$FAKE/active_at_reload")"
}

test_disconnect_failed_reload_keeps_active() {
  machines; set_active m1
  touch "$FAKE/fail_reload" "$FAKE/master_running"
  loki disconnect
  rc_fail "disconnect"
  eq "active kept" m1 "$(active)"
}

test_disconnect_failed_test_keeps_active() {
  machines; set_active m1
  touch "$FAKE/fail_t"
  loki disconnect
  rc_fail "disconnect"
  eq "active kept" m1 "$(active)"
}

test_sync_missing_host() {
  loki sync
  rc_fail "sync"
  has "error" "LOKI_SSH_HOST" "$OUT"
  check "scp not called" test ! -e "$FAKE/scp.log"
}

test_sync_reads_config() {
  printf 'LOKI_SSH_USER=bob\nLOKI_SSH_HOST=sync.example.test\nLOKI_SSH_PORT=2222\nLOKI_REMOTE_MACHINES_JSON=/srv/m.json\n' > "$(L config)"
  echo '{}' > "$FAKE/remote.json"
  loki sync
  rc_ok "sync"
  has "scp args" "scp -P 2222 bob@sync.example.test:/srv/m.json " "$(cat "$FAKE/scp.log")"
}

test_sync_defaults() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  echo '{}' > "$FAKE/remote.json"
  loki sync
  has "scp default args" "scp -P 22 root@h.test:/mnt/machines.json " "$(cat "$FAKE/scp.log")"
}

test_sync_success_without_active_no_reload() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  machines
  echo '{"new": {"ip": "1.1.1.1", "services": {}}}' > "$FAKE/remote.json"
  loki sync
  rc_ok "sync"
  check "machine.json replaced" cmp -s "$FAKE/remote.json" "$(L machine.json)"
  eq "nginx untouched" "" "$(calls)"
}

test_sync_success_with_active_reloads() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  machines; set_active m1
  echo '{"m1": {"ip": "9.9.9.9", "services": {"x": {"local": 1, "remote": 2}}}}' > "$FAKE/remote.json"
  loki sync
  rc_ok "sync"
  check "machine.json replaced" cmp -s "$FAKE/remote.json" "$(L machine.json)"
  eq "reloaded" "nginx -t,nginx -t,nginx -s reload," "$(calls)"
  check "conf uses new ip" header_ok "$(DEST)" m1 9.9.9.9
}

test_sync_scp_failure_keeps_machine_json() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  machines; cp "$(L machine.json)" "$SB/before"
  touch "$FAKE/fail_scp"
  loki sync
  rc_fail "sync"
  has "error" "Could not fetch" "$OUT"
  check "machine.json unchanged" cmp -s "$SB/before" "$(L machine.json)"
  eq "nginx untouched" "" "$(calls)"
}

test_init_syncs() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  echo '{}' > "$FAKE/remote.json"
  loki init
  rc_ok "init"
  check "machine.json fetched" cmp -s "$FAKE/remote.json" "$(L machine.json)"
  check "log file" test -f "$(L loki.log)"
}

test_status_without_active() {
  machines
  loki status
  rc_ok "status"
  eq "output" "No active machine" "$OUT"
}

test_status_with_active() {
  machines; set_active m1
  loki status
  rc_ok "status"
  eq "output" "📡 Active machine: m1 (10.0.0.1)
 - web: local=8080, remote=80
 - api: local=9000, remote=9001
 - broken: local=null, remote=81
 - half: local=7000, remote=null" "$OUT"
}

test_list_without_active() {
  machines
  loki list
  rc_ok "list"
  eq "output" "Available machines:
  - m1
  - m2" "$OUT"
}

test_list_with_active() {
  machines; set_active m2
  loki list
  eq "output" "Available machines:
  - m1
  * m2" "$OUT"
}

test_list_without_machine_json() {
  loki list
  rc_fail "list"
  has "error" "machine.json not found" "$OUT"
}

test_ping_maps_curl_results() {
  echo '{"p": {"ip": "1.1.1.1", "services": {"a": {"local": 1001}, "b": {"local": 1002}, "c": {"local": 1003}, "d": {"local": 1004}}}}' > "$(L machine.json)"
  set_active p
  echo "7 000" > "$FAKE/curl_1001"; echo "28 000" > "$FAKE/curl_1002"
  echo "0 200" > "$FAKE/curl_1003"; echo "0 500" > "$FAKE/curl_1004"
  loki ping
  eq "output" "[loki] 🔍 Checking services for p
  a (localhost:1001): Down (Connection refused)
  b (localhost:1002): Down (Timeout)
  c (localhost:1003): Up (HTTP 200)
  d (localhost:1004): Up (HTTP 500)" "$OUT"
  has "curl bounded by a timeout" "--max-time" "$(cat "$FAKE/curl.log")"
}

test_ping_without_active() {
  machines
  loki ping
  rc_fail "ping"
  has "error" "No active machine" "$OUT"
}

test_detect_uses_first_reported_path() {
  machines
  mkdir -p "$SB/other"; : > "$SB/other/nginx.conf"
  printf 'nginx: the configuration file %s/nginx.conf syntax is ok\nnginx: configuration file %s/nginx.conf test is successful\n' "$FAKE_CONF" "$SB/other" > "$FAKE/t_output"
  loki connect m1
  rc_ok "connect"
  check "written to first path" test -s "$(DEST)"
  check "not written to second path" test ! -e "$SB/other/remote.conf"
}

test_detect_no_path_and_no_fallback_errors() {
  machines
  echo "nginx: something unexpected" > "$FAKE/t_output"
  loki connect m1
  rc_fail "connect"
  has "error" "Could not detect nginx conf directory" "$OUT"
  eq "no active" "<none>" "$(active)"
  hasnt "no reload" "reload" "$(calls)"
}

test_detect_no_path_uses_fallback_dir() {
  machines
  mkdir -p "$FALLBACK/b"
  echo "nginx: something unexpected" > "$FAKE/t_output"
  loki connect m1
  rc_ok "connect"
  check "written to first existing fallback" header_ok "$FALLBACK/b/remote.conf" m1 10.0.0.1
}

test_sudo_not_used_when_dir_writable() {
  machines
  loki connect m1
  rc_ok "connect"
  check "sudo not called" test ! -e "$FAKE/sudo.log"
  has "root nginx probe" "pgrep -u 0 -f nginx: master" "$(cat "$FAKE/pgrep.log")"
}

test_sudo_used_when_dir_unwritable() {
  [ "$(id -u)" = 0 ] && { skip "running as root, dirs are always writable"; return; }
  machines
  chmod a-w "$FAKE_CONF"
  loki connect m1
  rc_ok "connect"
  local log; log=$(cat "$FAKE/sudo.log" 2>/dev/null)
  has "sudo cp" "sudo cp " "$log"
  has "sudo nginx -t" "sudo nginx -t" "$log"
  has "sudo reload" "sudo nginx -s reload" "$log"
  check "conf installed" header_ok "$(DEST)" m1 10.0.0.1
}

test_sudo_used_when_root_nginx_runs() {
  machines
  touch "$FAKE/root_nginx"
  loki connect m1
  rc_ok "connect"
  has "sudo reload" "sudo nginx -s reload" "$(cat "$FAKE/sudo.log" 2>/dev/null)"
}

tui_bin() {  # PATH with only what loki (and strip) need, plus optional fake $1
  mkdir -p "$SB/tuibin"; ln -s "$(command -v mkdir)" "$SB/tuibin/mkdir"; ln -s "$(command -v sed)" "$SB/tuibin/sed"
  [ -n "${1-}" ] && { printf '#!/bin/sh\nexit 0\n' > "$SB/tuibin/$1"; chmod +x "$SB/tuibin/$1"; }
}

test_tui_missing_tmux() {
  tui_bin
  PATH="$SB/tuibin" loki tui
  rc_fail "tui"
  has "message" "tmux is not installed" "$OUT"
}

test_tui_missing_fzf() {
  tui_bin tmux
  PATH="$SB/tuibin" loki tui
  rc_fail "tui"
  has "message" "fzf is not installed" "$OUT"
}

test_tui_entrypoints_exist() {
  local fns; fns=$(set +u --; . "$LOKI" >/dev/null 2>&1; declare -F cmd_tui_menu cmd_tui_watch)
  has "cmd_tui_menu" "cmd_tui_menu" "$fns"
  has "cmd_tui_watch" "cmd_tui_watch" "$fns"
  local src; src=$(cat "$SRC")
  has "dispatch _tui_menu" "_tui_menu) cmd_tui_menu" "$src"
  has "dispatch _tui_watch" "_tui_watch) cmd_tui_watch" "$src"
}

# ---------- runner ----------
N=0 TPASS=0 TFAIL=0 TSKIP=0 ASSERTS=0
for t in $(compgen -A function test_); do
  N=$((N+1)); SB="$TMPROOT/t$N"
  mkdir -p "$SB/home/.loki" "$SB/conf" "$SB/fake" "$SB/meta"
  : > "$SB/conf/nginx.conf"; rm -rf "$FALLBACK"
  ( export HOME="$SB/home" PATH="$FAKEBIN:$ORIG_PATH" FAKE="$SB/fake" FAKE_CONF="$SB/conf"; "$t" )
  rc=$?
  [ $rc = 99 ] && { echo "ABORTED in $t" >&2; exit 2; }
  [ -f "$SB/meta/asserts" ] && ASSERTS=$((ASSERTS + $(wc -l < "$SB/meta/asserts")))
  if [ -f "$SB/meta/skip" ]; then TSKIP=$((TSKIP+1)); echo "skip $t ($(cat "$SB/meta/skip"))"
  elif [ $rc = 0 ] && [ ! -s "$SB/meta/failures" ]; then TPASS=$((TPASS+1)); echo "ok   $t"
  else TFAIL=$((TFAIL+1)); echo "FAIL $t"; [ -s "$SB/meta/failures" ] && sed 's/^/     /' "$SB/meta/failures"; [ $rc != 0 ] && echo "     (test exited $rc)"
  fi
done

# The real Homebrew nginx config must be untouched.
N=$((N+1))
if [ -n "$REAL_SUM" ] && [ "$REAL_SUM" != "$(cksum < "$REAL_REMOTE")" ]; then
  TFAIL=$((TFAIL+1)); echo "FAIL real $REAL_REMOTE changed during the run"
else TPASS=$((TPASS+1)); echo "ok   real_remote_conf_unchanged"; fi

# A real nginx running before the run must still be running (tests must never reach real pkill/nginx).
N=$((N+1))
if [ -n "$REAL_NGINX" ] && [ "$REAL_NGINX" != "$(pgrep -f 'nginx: master' 2>/dev/null | head -1)" ]; then
  TFAIL=$((TFAIL+1)); echo "FAIL the real nginx (pid $REAL_NGINX) was stopped during the run"
else TPASS=$((TPASS+1)); echo "ok   real_nginx_untouched"; fi

echo
echo "$N tests, $TPASS passed, $TFAIL failed, $TSKIP skipped ($ASSERTS assertions)"
[ $TFAIL = 0 ]
