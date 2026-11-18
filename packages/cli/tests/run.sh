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
unset LOKI_SSH_HOST LOKI_SSH_USER LOKI_SSH_PORT LOKI_REMOTE_MACHINES_JSON LOKI_SYNC_URL LOKI_VERSION TMUX EDITOR

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
echo "curl $*" >> "$FAKE/curl.log"
url="${!#}"; out=""; prev=""
for a; do
  [ "$prev" = -o ] && out=$a
  # loki's sync hands curl the URL in a config on stdin (-K -), never on the command line
  if [ "$prev" = -K ] && [ "$a" = - ]; then
    url=$(sed -n 's/^url = "\(.*\)"$/\1/p'); echo "stdin: url = \"$url\"" >> "$FAKE/curl.log"
  fi
  prev=$a
done
case "$url" in
  https://*)  # a download (sync URL, installer): $FAKE/download -> the -o file; fail_download: a 404
    [ -f "$FAKE/fail_download" ] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
    cp "$FAKE/download" "$out"; exit ;;
esac
# ping: $FAKE/curl_<port> holds "<exit code> <http code>"; default: refused.
rc=7; code=000
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
# c1 and c2 get the shared services; solo has its own
containers() {
  cat > "$(L machine.json)" <<'EOF'
{
  "containers": {"c1": "10.0.1.1", "c2": "10.0.1.2"},
  "services": {
    "web": {"local": 8080, "remote": 80},
    "api": {"local": 9000, "remote": 9001}
  },
  "solo": {"ip": "10.0.2.1", "services": {"ssh": {"local": 2222, "remote": 22}}}
}
EOF
}
header_ok() {  # header_ok <file> <name> <ip>
  local ip; ip=$(printf '%s' "$3" | sed 's/\./\\./g')
  head -1 "$1" | grep -qE "^# Auto-generated remote\.conf for $2 \($ip\) \[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]\$"
}
lines() { wc -l < "$1" | tr -d ' '; }
mode() { if stat --version >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }  # GNU, else BSD
# Sync saves the JSON as jq read it (reformatted), so compare content, not bytes
same_json() { [ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]; }

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
  { head -1 "$(DEST)"; printf '\nupstream api {\n    server 10.0.0.1:9001;\n}\nserver {\n    listen 127.0.0.1:9000;\n    proxy_pass api;\n}\n'
    printf '\nupstream web {\n    server 10.0.0.1:80;\n}\nserver {\n    listen 127.0.0.1:8080;\n    proxy_pass web;\n}\n'; } > "$SB/expected"
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
  has "service" "listen 127.0.0.1:2222;" "$(cat "$(DEST)")"
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
  check "machine.json replaced" same_json "$FAKE/remote.json" "$(L machine.json)"
  eq "nginx untouched" "" "$(calls)"
}

test_sync_success_with_active_reloads() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  machines; set_active m1
  echo '{"m1": {"ip": "9.9.9.9", "services": {"x": {"local": 1, "remote": 2}}}}' > "$FAKE/remote.json"
  loki sync
  rc_ok "sync"
  check "machine.json replaced" same_json "$FAKE/remote.json" "$(L machine.json)"
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
  check "machine.json fetched" same_json "$FAKE/remote.json" "$(L machine.json)"
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

# ---------- sync from a URL ----------

test_sync_url_downloads_with_curl_and_wins_over_ssh() {
  printf "LOKI_SSH_HOST=h.test\nLOKI_SYNC_URL='https://gist.githubusercontent.com/u/abc/raw/machine.json'\n" > "$(L config)"
  echo '{"new": {"ip": "1.1.1.1", "services": {"web": {"local": 8080, "remote": 80}}}}' > "$FAKE/download"
  loki sync
  rc_ok "sync"
  check "machine.json replaced" same_json "$FAKE/download" "$(L machine.json)"
  has "curl with the app's flags" "curl -q -K - -fsSL --proto =https --proto-redir =https --max-filesize 1000000 --max-time 30 -o $(L machine.json).tmp" "$(cat "$FAKE/curl.log")"
  has "the URL on stdin" 'stdin: url = "https://gist.githubusercontent.com/u/abc/raw/machine.json"' "$(cat "$FAKE/curl.log")"
  check "scp not used" test ! -e "$FAKE/scp.log"
}

test_sync_url_with_an_at_sign_in_the_query_is_not_a_password() {
  echo "LOKI_SYNC_URL='https://example.test?ref=a@b'" > "$(L config)"
  echo '{}' > "$FAKE/download"
  loki sync
  rc_ok "sync"
}

test_sync_url_failure_keeps_machine_json() {
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  machines; cp "$(L machine.json)" "$SB/before"
  touch "$FAKE/fail_download"
  loki sync
  rc_fail "sync"
  has "error" "Could not download https://example.test/m.json" "$OUT"
  check "machine.json unchanged" cmp -s "$SB/before" "$(L machine.json)"
  check "no temp file left" test ! -e "$(L machine.json.tmp)"
  eq "nginx untouched" "" "$(calls)"
}

# ---------- security (the app's side: SecurityTests.swift) ----------

test_security_sync_url_must_be_https() {
  local url
  for url in "http://example.test/m.json" "HTTPS://example.test/m.json" "file:///etc/passwd" "ftp://example.test/m.json"; do
    printf "LOKI_SYNC_URL='%s'\n" "$url" > "$(L config)"
    loki sync
    rc_fail "sync $url"
    has "$url refused" "must start with https://" "$OUT"
  done
  check "curl never ran" test ! -e "$FAKE/curl.log"
}

test_security_sync_url_credentials_refused() {
  echo "LOKI_SYNC_URL='https://user:secret@example.test/m.json'" > "$(L config)"
  loki sync
  rc_fail "sync"
  has "error" "Leave the user name and password out" "$OUT"
  check "curl never ran" test ! -e "$FAKE/curl.log"
  hasnt "secret not logged" "secret" "$(cat "$(L loki.log)" 2>/dev/null)"
}

test_security_sync_url_token_kept_out_of_log() {
  echo "LOKI_SYNC_URL='https://example.test/m.json?token=s3cret#frag'" > "$(L config)"
  echo '{}' > "$FAKE/download"
  loki sync
  rc_ok "sync"
  has "logged without the query" "Fetching machines.json from https://example.test/m.json ..." "$(cat "$(L loki.log)")"
  hasnt "no token in the log" "s3cret" "$(cat "$(L loki.log)")"
  hasnt "no token on curl's command line, where ps shows it" "s3cret" "$(grep '^curl ' "$FAKE/curl.log")"
}

test_security_sync_url_quotes_and_backslashes_refused() {
  local url
  for url in 'https://example.test/a"b' 'https://example.test/a\b'; do
    printf "LOKI_SYNC_URL='%s'\n" "$url" > "$(L config)"
    loki sync
    rc_fail "sync $url"
    has "$url refused" "can't contain spaces, quotes or backslashes" "$OUT"
  done
  check "curl never ran" test ! -e "$FAKE/curl.log"
}

test_security_sync_saves_what_it_checked() {
  # jq keeps the last of two duplicate keys, the app the first: the hostile first copy must not survive
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  printf '%s' '{"m": {"ip": "1.2.3.4\nserver { listen 4444; }", "services": {}}, "m": {"ip": "10.0.0.1", "services": {}}}' > "$FAKE/download"
  loki sync
  rc_ok "sync"
  eq "one machine left" '["m"]' "$(jq -c 'keys' "$(L machine.json)")"
  eq "its checked IP" "10.0.0.1" "$(jq -r '.m.ip' "$(L machine.json)")"
  hasnt "no hostile copy on disk" "4444" "$(cat "$(L machine.json)")"
}

test_security_disconnect_keeps_an_unchecked_ip_in_the_comment() {
  # disconnect doesn't check machine.json, so the header must not let a line break end the comment
  printf '%s' '{"m1": {"ip": "10.0.0.1\nserver { listen 2222; proxy_pass 10.9.9.9:22; } #", "services": {}}}' > "$(L machine.json)"
  set_active m1
  loki disconnect
  rc_ok "disconnect"
  eq "remote.conf is the header alone" 1 "$(lines "$(DEST)")"
  check "with the IP inside it" grep -q '^# Auto-generated remote.conf for m1 (10.0.0.1 server { listen 2222' "$(DEST)"
}

test_security_removed_machine_header_stays_one_line() {
  machines
  set_active $'gone\ninclude /etc/evil.conf;'
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  echo '{"m2": {"ip": "10.0.0.2", "services": {}}}' > "$FAKE/remote.json"
  loki sync
  rc_ok "sync"
  eq "remote.conf is one comment line" 1 "$(lines "$(DEST)")"
}

# Each would write attacker-chosen text into nginx's config, or isn't a machine list (SecurityTests.unsafeDownloads)
test_security_sync_rejects_unsafe_downloads() {
  local payload
  machines; cp "$(L machine.json)" "$SB/before"
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  while IFS= read -r payload; do
    printf '%s' "$payload" > "$FAKE/download"
    loki sync
    rc_fail "sync accepted: $payload"
    has "rejected: $payload" "rejected, so your machines are unchanged" "$OUT"
  done <<'EOF'
{"m": {"ip": "1.2.3.4; include /etc/passwd", "services": {}}}
{"m": {"ip": "1.2.3.4\ninclude /etc/passwd;", "services": {}}}
{"m": {"ip": "-oProxyCommand=x", "services": {}}}
{"m": {"ip": "-1.2.3.4", "services": {}}}
{"m": {"ip": "1.2.3.4", "services": {"web}; server { listen 1": {"local": 8080, "remote": 80}}}}
{"m": {"ip": "1.2.3.4", "services": {"web": {"local": "8080; include /x", "remote": 80}}}}
{"m": {"ip": "1.2.3.4", "services": {"web": {"local": 70000, "remote": 80}}}}
{"m": {"ip": "1.2.3.4", "services": {"web": {"local": 8080, "remote": null}}}}
{"m": {"ip": "1.2.3.4", "services": {"a": {"local": 8080, "remote": 80}, "b": {"local": 8080, "remote": 81}}}}
{"../m": {"ip": "1.2.3.4", "services": {}}}
{"m\nx": {"ip": "1.2.3.4", "services": {}}}
{"m": {"ip": "1.2.3.4"}}
{"containers": {"m": "1.2.3.4; include /etc/passwd"}}
{"containers": {"m\nx": "1.2.3.4"}}
{"containers": {"services": "1.2.3.4"}}
{"containers": {"m": "1.2.3.4"}, "m": {"ip": "1.2.3.5", "services": {}}}
{"containers": ["1.2.3.4"]}
{"containers": {"m": "1.2.3.4"}, "services": {"web}; server { listen 1": {"local": 8080, "remote": 80}}}
{"containers": {"m": "1.2.3.4"}, "services": {"web": {"local": 8080, "remote": null}}}
{} {}
[]
<html><body>Sign in</body></html>
EOF
  : > "$FAKE/download"
  loki sync
  rc_fail "sync accepted an empty file"
  check "machine.json unchanged" cmp -s "$SB/before" "$(L machine.json)"
  check "no temp file left" test ! -e "$(L machine.json.tmp)"
  eq "nginx untouched" "" "$(calls)"
}

test_security_sync_rejects_oversized_download() {
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  { head -c 1000001 /dev/zero | tr '\0' ' '; echo '{}'; } > "$FAKE/download"  # valid JSON, padded
  loki sync
  rc_fail "sync"
  has "too big" "over 1 MB" "$OUT"
}

test_security_connect_refuses_unsafe_machine() {
  cat > "$(L machine.json)" <<'EOF'
{"m1": {"ip": "1.2.3.4;\n}\nserver { listen 9999; proxy_pass evil", "services": {"web": {"local": 8080, "remote": 80}}},
 "ok": {"ip": "10.0.0.1", "services": {}}}
EOF
  loki connect m1
  rc_fail "connect"
  has "error" "can't be used for m1" "$OUT"
  eq "active unchanged" "<none>" "$(active)"
  eq "nginx untouched" "" "$(calls)"
  check "nothing installed" test ! -e "$(DEST)"
  loki connect ok
  rc_ok "a valid machine in the same file still connects"
}

test_security_reload_refuses_machine_edited_after_connect() {
  machines; set_active m1
  jq '.m1.ip = "10.0.0.1; include /etc/passwd"' "$(L machine.json)" > "$SB/edited" && mv "$SB/edited" "$(L machine.json)"
  loki reload
  rc_fail "reload"
  eq "nginx untouched" "" "$(calls)"
}

test_security_active_name_is_never_run_as_jq() {
  machines
  set_active 'm1" | env, ."x'  # spliced into a jq filter, this prints the environment
  loki status
  hasnt "status: no environment dump" "FAKE_CONF" "$OUT"
  loki ping
  hasnt "ping: no environment dump" "FAKE_CONF" "$OUT"
}

test_security_data_folder_is_private() {
  chmod 755 "$HOME/.loki"  # as older versions left it
  machines
  loki connect m1
  eq "~/.loki" 700 "$(mode "$HOME/.loki")"
}

test_security_config_everyone_can_write_is_not_sourced() {
  echo 'LOKI_SSH_HOST=h.test' > "$(L config)"
  chmod 666 "$(L config)"
  echo '{}' > "$FAKE/remote.json"
  loki sync
  rc_fail "sync"
  has "warning" "ignoring $HOME/.loki/config" "$OUT"
  check "scp not called" test ! -e "$FAKE/scp.log"
  eq "left for you to check, not quietly fixed" 666 "$(mode "$(L config)")"
  chmod 664 "$(L config)"  # group-writable is fine: Linux gives each user their own group
  loki sync
  rc_ok "sourced again once only you (and your group) can write it"
}

test_security_config_symlink_is_judged_by_its_target() {
  echo 'LOKI_SSH_HOST=h.test' > "$SB/real-config"
  ln -s "$SB/real-config" "$(L config)"
  echo '{}' > "$FAKE/remote.json"
  chmod 666 "$SB/real-config"
  loki sync
  rc_fail "a symlink to a world-writable file is refused"
  chmod 644 "$SB/real-config"
  loki sync
  rc_ok "a symlink to a normal file is sourced (stow, home-manager)"
}

test_connect_skips_services_missing_a_port_like_the_app() {
  # The app skips such services entirely: no duplicate or range check on them either
  echo '{"m": {"ip": "10.0.0.1", "services": {"a": {"local": 8080, "remote": 80}, "b": {"local": 8080, "remote": null}, "c": {"local": 70000}}}}' > "$(L machine.json)"
  loki connect m
  rc_ok "connect"
  eq "only a is proxied" 1 "$(grep -c '^upstream ' "$(DEST)")"
}

test_connect_writes_whole_number_ports() {
  # jq 1.7 keeps number literals as written; nginx rejects "8080.0" and "1E+2"
  echo '{"m": {"ip": "10.0.0.1", "services": {"web": {"local": 8080.0, "remote": 1e2}}}}' > "$(L machine.json)"
  loki connect m
  rc_ok "connect"
  has "listen" "listen 127.0.0.1:8080;" "$(cat "$(DEST)")"
  has "server" "server 10.0.0.1:100;" "$(cat "$(DEST)")"
}

test_log_rotates_past_1mb() {
  head -c 1000001 /dev/zero | tr '\0' x > "$(L loki.log)"
  loki status
  eq "old log kept" 1000001 "$(wc -c < "$(L loki.log.1)" | tr -d ' ')"
  check "a fresh log starts" test ! -e "$(L loki.log)"
}

# run_installer <env assignments…>: the installer piped into bash, like the documented `curl … | bash`
# (a prompt would read end-of-input and abort). Never near the real /usr/local/bin or shell profile.
run_installer() {
  grep -q 'LOKI_BIN_DIR:-' "$CLI/install.sh" || { echo "ABORT: install.sh ignores LOKI_BIN_DIR" >&2; exit 99; }
  mkdir -p "$SB/bin"
  OUT=$(cat "$CLI/install.sh" | env LOKI_DIR="$HOME/.loki" LOKI_BIN_DIR="$SB/bin" PROFILE="" "$@" "$BASH" 2>&1); RC=$?
  OUT=$(printf '%s' "$OUT" | strip)
}
OLD_LOKI='#!/usr/bin/env bash
VERSION=1.0.0'

test_containers_are_listed_with_the_other_machines() {
  containers; set_active c2
  loki list
  rc_ok "list"
  eq "output" "Available machines:
  - c1
  * c2
  - solo" "$OUT"
}

test_connect_container_gets_the_shared_services() {
  containers
  loki connect c1
  rc_ok "connect"
  eq "active" c1 "$(active)"
  check "header has the container's IP" header_ok "$(DEST)" c1 10.0.1.1
  { head -1 "$(DEST)"; printf '\nupstream api {\n    server 10.0.1.1:9001;\n}\nserver {\n    listen 127.0.0.1:9000;\n    proxy_pass api;\n}\n'
    printf '\nupstream web {\n    server 10.0.1.1:80;\n}\nserver {\n    listen 127.0.0.1:8080;\n    proxy_pass web;\n}\n'; } > "$SB/expected"
  check "remote.conf exact" cmp -s "$SB/expected" "$(DEST)"
}

test_connect_machine_of_its_own_gets_only_its_services() {
  containers
  loki connect solo
  rc_ok "connect"
  eq "one upstream" 1 "$(grep -c '^upstream ' "$(DEST)")"
  has "its own service" "server 10.0.2.1:22;" "$(cat "$(DEST)")"
}

test_status_and_ping_read_a_containers_shared_services() {
  containers; set_active c2
  loki status
  rc_ok "status"
  eq "output" "📡 Active machine: c2 (10.0.1.2)
 - web: local=8080, remote=80
 - api: local=9000, remote=9001" "$OUT"
  loki ping
  has "pings a shared port" "api (localhost:9000)" "$OUT"
}

test_sync_keeps_containers_and_reloads_an_active_one() {
  containers; set_active c1
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  jq '.containers.c1 = "10.0.1.9"' "$(L machine.json)" > "$FAKE/download"
  loki sync
  rc_ok "sync"
  check "saved as written" same_json "$FAKE/download" "$(L machine.json)"
  eq "still connected" c1 "$(active)"
  has "reloaded with the new IP" "server 10.0.1.9:80;" "$(cat "$(DEST)")"
}

test_sync_disconnects_a_container_that_was_removed() {
  containers; set_active c2
  echo "LOKI_SYNC_URL='https://example.test/m.json'" > "$(L config)"
  jq 'del(.containers.c2)' "$(L machine.json)" > "$FAKE/download"
  loki sync
  rc_ok "sync"
  eq "disconnected" "<none>" "$(active)"
  has "says why" "c2 was removed from machine.json" "$OUT"
}

test_security_connect_refuses_a_container_with_unsafe_shared_services() {
  echo '{"containers": {"c": "10.0.0.1"}, "services": {"web}; server { listen 9999": {"local": 8080, "remote": 80}}}' > "$(L machine.json)"
  loki connect c
  rc_fail "connect"
  has "error" "can't be used for c" "$OUT"
  eq "nginx untouched" "" "$(calls)"
}

test_installer_rerun_updates_in_place() {
  machines; cp "$(L machine.json)" "$SB/before"
  printf '%s\n' "$OLD_LOKI" > "$(L loki)"
  printf '#!/usr/bin/env bash\nVERSION=9.9.9\necho "loki 9.9.9"\n' > "$FAKE/download"
  run_installer
  rc_ok "piped re-run"
  hasnt "no abort" "aborted" "$OUT"
  has "says it updated" "Updated loki to 9.9.9" "$OUT"
  hasnt "no getting-started steps (loki init would re-sync)" "loki init" "$OUT"
  check "loki replaced" grep -q '^VERSION=9.9.9$' "$(L loki)"
  check "loki executable" test -x "$(L loki)"
  check "machines kept" cmp -s "$SB/before" "$(L machine.json)"
  eq "symlink" "$(L loki)" "$(readlink "$SB/bin/loki")"
  has "latest release, hardened curl" "curl -q -fsSL --proto =https --proto-redir =https -o $(L loki.new) https://github.com/rajadubey/loki/releases/latest/download/loki.sh" "$(cat "$FAKE/curl.log")"
}

test_installer_keeps_a_working_loki_when_the_download_breaks() {
  printf '%s\n' "$OLD_LOKI" > "$(L loki)"
  touch "$FAKE/fail_download"
  run_installer
  rc_fail "failed download"
  check "old loki kept" grep -q '^VERSION=1.0.0$' "$(L loki)"
  rm "$FAKE/fail_download"
  printf '#!/usr/bin/env bash\nVERSION=9.9.9\necho "cut off' > "$FAKE/download"  # a dropped connection
  run_installer
  rc_fail "truncated download"
  check "old loki still kept" grep -q '^VERSION=1.0.0$' "$(L loki)"
  check "no leftover" test ! -e "$(L loki.new)"
}

test_installer_skips_sudo_when_the_link_is_already_there() {
  printf '#!/usr/bin/env bash\nVERSION=9.9.9\n' > "$FAKE/download"
  mkdir -p "$SB/bin" && ln -s "$(L loki)" "$SB/bin/loki" && chmod 555 "$SB/bin"
  run_installer
  chmod 755 "$SB/bin"
  rc_ok "update"
  check "no sudo" test ! -e "$FAKE/sudo.log"
}

test_installer_missing_dependency_fails_without_prompting() {
  printf '#!/usr/bin/env bash\nVERSION=9.9.9\n' > "$FAKE/download"
  run_installer PATH="$FAKEBIN:/bin"  # no jq there
  rc_fail "missing jq"
  has "says what to do" "Install them, then run the installer again" "$OUT"
  hasnt "no prompt" "Continue anyway" "$OUT"
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
