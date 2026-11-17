#!/usr/bin/env bash

# ===========================
# LOKI - NGINX Machine Configurator
# ===========================

VERSION=2.0.1

LOKI_HOME="$HOME/.loki"
CONF_PATH="$LOKI_HOME/machine.json"
ACTIVE_FILE="$LOKI_HOME/active"
TMP_CONF="$LOKI_HOME/remote.conf"
LOG_FILE="$LOKI_HOME/loki.log"

# ~/.loki holds machine addresses and sync settings, so the folder is owner-only like ~/.ssh (the
# macOS app does the same at launch): other users can't reach anything in it. Only the folder: a
# blanket chmod would quietly "fix" a world-writable config that the check below must refuse, and
# a umask would leak into nginx when loki starts it.
mkdir -p "$LOKI_HOME" && chmod 700 "$LOKI_HOME/"
# Bounded like the app's: past 1 MB the log becomes loki.log.1
[ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 1000000 ] && mv -f "$LOG_FILE" "$LOG_FILE.1"

# Settings such as LOKI_SSH_HOST can live here instead of .bashrc/.zshrc;
# apps opened from Finder (the macOS app) never read shell profiles.
# It runs as shell code, so only when it's yours and not writable by everyone. -H judges the file a
# symlink points to; group-writable is fine (Linux gives each user their own group).
if [ -f "$LOKI_HOME/config" ]; then
  if [ -O "$LOKI_HOME/config" ] && [ -z "$(find -H "$LOKI_HOME/config" -perm -002)" ]; then
    . "$LOKI_HOME/config"
  else
    echo "loki: ignoring $LOKI_HOME/config: it must be yours and not writable by everyone (chmod 600 $LOKI_HOME/config)" >&2
  fi
fi

# ---------- Colors ----------
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# Every log-file line gets the timestamp, including each line of multi-line messages (nginx output)
log() { echo -e "${BLUE}[loki]${RESET} $1"; printf '%s\n' "$1" | sed "s/^/[$(date '+%Y-%m-%d %H:%M:%S')] /" >> "$LOG_FILE"; }
ok() { echo -e "${GREEN}$1${RESET}"; }
warn() { echo -e "${YELLOW}$1${RESET}"; }
err() { echo -e "${RED}$1${RESET}" >&2; }

get_active() { [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE"; }
set_active() { echo "$1" > "$ACTIVE_FILE"; }
# For remote.conf's header comment, which ends at a line break: CR and LF become spaces (the app's
# NginxConfig.oneLine), so an unchecked value (disconnect doesn't check) can't start a directive.
one_line() { printf '%s' "$1" | tr '\r\n' '  '; }

# What's wrong with the machine list on stdin, one problem per line; nothing when it's fine.
# Names, IPs and ports are written into nginx's config, so anything that could inject a directive
# is refused: the app's rules. Strict (downloads) also wants both ports of every service; otherwise
# a service missing one is allowed and skipped, as connect always did.
machine_problems() {
  jq -rs --argjson strict "${1:-false}" '
    def ok($re): type == "string" and test($re);
    if length != 1 or (.[0] | type) != "object" then "it is not a JSON object of machines"
    else .[0] | to_entries[] | .key as $m | .value as $v |
      if ($m | ok("\\A[A-Za-z0-9._-]+\\z") | not) then "machine name \($m | tojson) can only use letters, digits, \".\", \"_\" and \"-\""
      elif ($v | type) != "object" then "\($m): not an object"
      elif ($v.ip | ok("\\A[A-Za-z0-9.:\\[\\]-]+\\z") | not) or ($v.ip | startswith("-")) then "\($m): \($v.ip | tojson) is not a valid IP address or hostname"
      elif ($v.services | type) != "object" then "\($m): \"services\" must be an object"
      else
        ($v.services | to_entries[] | .key as $s | .value as $p |
          if ($s | ok("\\A[A-Za-z0-9_-]+\\z") | not) then "\($m): service name \($s | tojson) can only use letters, digits, \"_\" and \"-\""
          elif ($p | type) != "object" then "\($m) → \($s): not an object"
          elif any($p.local, $p.remote; . != null and (type != "number" or . != floor)) then "\($m) → \($s): ports must be whole numbers from 1 to 65535"
          elif $p.local == null or $p.remote == null then (if $strict then "\($m) → \($s): set both the local and the remote port" else empty end)
          elif any($p.local, $p.remote; . < 1 or . > 65535) then "\($m) → \($s): ports must be whole numbers from 1 to 65535"
          else empty end),
        # Like the app, a service missing a port is skipped, so it neither clashes nor needs a range
        ([$v.services[] | objects | select(.local != null and .remote != null) | .local] | group_by(.)[] | select(length > 1) | "\($m): local port \(.[0]) is used by more than one service")
      end
    end' 2>/dev/null || echo "it is not valid JSON"
}

detect_nginx_conf_dir() {
  log "Detecting nginx configuration directory..."

  # Run nginx -t and capture output. No sudo: the config path is printed even
  # when the test itself fails on permissions.
  if ! output=$(nginx -t 2>&1); then
    log "nginx -t returned error, but will try to parse config path anyway"
  fi

  log "nginx -t output: $output"

  # Parse the configuration file path from output
  local nginx_conf=""
  if echo "$output" | grep -q "configuration file"; then
    # nginx prints the path twice ("syntax is ok" / "test is successful"); keep one
    nginx_conf=$(echo "$output" | grep "configuration file" | head -1 | sed -E 's/.*configuration file ([^ ]+nginx\.conf).*/\1/')
  fi

  if [ -n "$nginx_conf" ] && [ -f "$nginx_conf" ]; then
    conf_dir=$(dirname "$nginx_conf")
    log "Found nginx config: $nginx_conf"
    log "Resolved conf directory: $conf_dir"
    # ONLY output the directory path, no logs
    echo "$conf_dir"
    return 0
  fi

  # Fallback to common paths
  warn "Could not detect nginx config path automatically, trying common paths"
  for path in "/opt/homebrew/etc/nginx" "/usr/local/etc/nginx" "/etc/nginx"; do
    if [ -d "$path" ]; then
      log "Using fallback path: $path"
      # ONLY output the directory path, no logs
      echo "$path"
      return 0
    fi
  done

  err "Could not detect nginx conf.d directory"
  return 1
}

# ---------- Commands ----------

cmd_init() {
  log "Initializing LOKI home at $LOKI_HOME"

  cmd_sync

  touch "$LOG_FILE"
  ok "✅ LOKI initialized successfully."
}

cmd_list() {
  [ ! -f "$CONF_PATH" ] && { err "machine.json not found. Run 'loki init' first."; exit 1; }
  active=$(get_active)
  echo "Available machines:"
  jq -r 'keys[]' "$CONF_PATH" | while read -r key; do
    if [ "$key" = "$active" ]; then
      echo -e "  * ${GREEN}${key}${RESET}"
    else
      echo "  - $key"
    fi
  done
}

cmd_connect() {
  local name="$1"
  [ -z "$name" ] && { err "Usage: loki connect <machine>"; exit 1; }
  [ ! -f "$CONF_PATH" ] && { err "machine.json not found. Run 'loki init' first."; exit 1; }

  jq -e --arg n "$name" 'has($n)' "$CONF_PATH" >/dev/null || { err "Machine '$name' not found in $CONF_PATH"; exit 1; }

  log "Attempting to connect to machine: $name"
  apply_conf "$name"
  # Only after nginx accepted the new config, so 'active' never lies.
  set_active "$name"
  ok "✅ Connected to: $name and nginx reloaded successfully"
}

# Writes remote.conf for machine $1 (header only when $2 is false), installs it
# next to nginx.conf, tests it and reloads nginx. Exits non-zero on any failure,
# leaving the previous remote.conf in place.
apply_conf() {
  local name="$1" with_config="${2:-true}" ip conf_dir dest out s local_port remote_port problems

  if [ "$(jq -r --arg n "$name" 'has($n)' "$CONF_PATH" 2>/dev/null)" = false ]; then
    # Machine is gone from machine.json (e.g. after sync): empty the proxy. Same text as the macOS app.
    echo "# Auto-generated remote.conf: $(one_line "$name") was removed from machine.json" > "$TMP_CONF"
  else
  # Checked before anything is written or logged, like the app's connect and reload
  if [ "$with_config" = true ]; then
    problems=$( { jq --arg n "$name" '{($n): .[$n]}' "$CONF_PATH" 2>/dev/null || echo "not JSON"; } | machine_problems)
    # printf, not err's echo -e: the text quotes machine.json, which could hold escape sequences
    [ -n "$problems" ] && { err "machine.json can't be used for $name:"; printf '%s\n' "$problems" >&2; exit 1; }
  fi
  ip=$(jq -r --arg n "$name" '.[$n].ip' "$CONF_PATH")
  log "Generating NGINX config for $name ($ip)"
  {
    echo "# Auto-generated remote.conf for $(one_line "$name") ($(one_line "$ip")) [$(date '+%Y-%m-%d %H:%M:%S')]"
    if [ "$with_config" = true ]; then
      # Sorted by name, services missing a port skipped, ports as whole numbers (8080.0 -> 8080):
      # the macOS app renders the same file. 127.0.0.1 only: on every interface, anyone on the
      # network could use this machine to reach the remote ones.
      jq -r --arg n "$name" '.[$n].services | to_entries | sort_by(.key)[] | select(.value.local != null and .value.remote != null)
        | "\(.key) \(.value.local | floor) \(.value.remote | floor)"' "$CONF_PATH" |
        while read -r s local_port remote_port; do
          printf '\nupstream %s {\n    server %s:%s;\n}\nserver {\n    listen 127.0.0.1:%s;\n    proxy_pass %s;\n}\n' \
            "$s" "$ip" "$remote_port" "$local_port" "$s"
        done
    fi
  } > "$TMP_CONF"
  fi

  conf_dir=$(detect_nginx_conf_dir 2>/dev/null | tail -1 | tr -d '[:space:]')
  [ -d "$conf_dir" ] || { err "Could not detect nginx conf directory"; exit 1; }
  dest="$conf_dir/remote.conf"
  log "Detected nginx conf directory: $conf_dir"

  # sudo only when nginx is root's: a writable conf dir and no root-owned nginx
  # (Homebrew nginx run as you) needs none, which is what lets the macOS app drive loki.
  local SUDO=sudo
  # (-f: nginx retitles itself "nginx: master process …", so -x never matches)
  if [ -w "$conf_dir" ] && ! pgrep -u 0 -f 'nginx: master' >/dev/null 2>&1; then SUDO=""; fi

  # Drop any .prev from an earlier run so a failed test never "restores" it
  $SUDO rm -f "$dest.prev"
  [ -f "$dest" ] && $SUDO cp "$dest" "$dest.prev"
  log "Copying remote.conf to: $dest"
  $SUDO cp "$TMP_CONF" "$dest" || { err "Failed to copy remote.conf to $dest"; exit 1; }

  log "Testing nginx configuration with new remote.conf..."
  if ! out=$($SUDO nginx -t 2>&1); then
    log "nginx -t output: $out"
    err "nginx rejected the new config, restoring the previous remote.conf:"
    err "$out"
    # Restore rather than delete: nginx.conf includes this file by path.
    if [ -f "$dest.prev" ]; then $SUDO mv "$dest.prev" "$dest"; else $SUDO cp /dev/null "$dest"; fi
    exit 1
  fi

  log "Reloading nginx..."
  if ! out=$(reload_nginx); then
    log "nginx reload output: $out"
    err "nginx reload failed (is nginx running? brew services start nginx):"
    err "$out"
    exit 1
  fi
  log "Nginx reload successful"
}

# `nginx -s reload`, or, when no nginx master is running (e.g. a stale pid file), stop any
# stragglers and start nginx, retrying while the old listen sockets are still bound
# ("Address already in use") for up to LOKI_START_ATTEMPTS seconds. A running nginx that
# refuses to reload is a real error and is left alone. Uses $SUDO from apply_conf.
reload_nginx() {
  local out i
  out=$($SUDO nginx -s reload 2>&1) && return 0
  if pgrep -f 'nginx: master' >/dev/null 2>&1; then echo "$out"; return 1; fi

  log "nginx isn't running, starting it..." >&2
  # -f: nginx retitles itself "nginx: master process …", so -x never matches
  $SUDO pkill -f 'nginx: (master|worker)' 2>/dev/null || true
  for ((i = 0; i < ${LOKI_START_ATTEMPTS:-10}; i++)); do
    out=$($SUDO nginx 2>&1) && return 0
    # brew services / launchd may have respawned it already; then a reload loads our config
    pgrep -f 'nginx: master' >/dev/null 2>&1 && $SUDO nginx -s reload >/dev/null 2>&1 && return 0
    case "$out" in *"Address already in use"*) sleep 1 ;; *) break ;; esac
  done
  echo "$out"
  return 1
}

cmd_status() {
  active=$(get_active)
  [ -z "$active" ] && { warn "No active machine"; exit 0; }
  # --arg: spliced into the filter, a quote in the name would change what jq runs
  ip=$(jq -r --arg n "$active" '.[$n].ip' "$CONF_PATH")
  ok "📡 Active machine: $active (${ip})"
  jq -r --arg n "$active" '.[$n].services | to_entries[] | " - \(.key): local=\(.value.local), remote=\(.value.remote)"' "$CONF_PATH"
}

cmd_ping() {
  active=$(get_active)
  [ -z "$active" ] && { err "No active machine"; exit 1; }
  log "🔍 Checking services for $active"
  jq -r --arg n "$active" '.[$n].services | to_entries[] | "\(.key) \(.value.local)"' "$CONF_PATH" |
    while read -r name port; do
      echo -n "  $name (localhost:$port): "
      
      # Use curl with more options to get detailed status
      response=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port" 2>/dev/null)
      curl_exit_code=$?
      
      if [ $curl_exit_code -eq 0 ]; then
        if [ "$response" = "200" ]; then
          ok "Up (HTTP $response)"
        else
          warn "Up (HTTP $response)"
        fi
      else
        case $curl_exit_code in
          6)  err "Down (Cannot resolve host)" ;;
          7)  err "Down (Connection refused)" ;;
          28) err "Down (Timeout)" ;;
          52) err "Down (Empty reply from server)" ;;
          56) err "Down (Connection reset)" ;;
          *)  err "Down (curl error: $curl_exit_code)" ;;
        esac
      fi
    done
}

cmd_reload() {
  local withConfig=true
  # Parse flags
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-withConfig)
        withConfig=false
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  active=$(get_active)
  [ -z "$active" ] && { err "No active machine"; exit 1; }
  [ ! -f "$CONF_PATH" ] && { err "machine.json not found"; exit 1; }

  apply_conf "$active" "$withConfig"
  ok "✅ Reloaded NGINX with new config for $active"
}

cmd_sync() {
  local active src problems
  # Download beside machine.json and swap: a failed transfer leaves a truncated target
  if [ -n "${LOKI_SYNC_URL:-}" ]; then
    # The app's rules: https only; no quotes, backslashes or spaces (it goes into curl's config as "…");
    # no user:password@ (config and log are plain text)
    case "$LOKI_SYNC_URL" in https://*) ;; *) err "LOKI_SYNC_URL must start with https://"; exit 1 ;; esac
    case "$LOKI_SYNC_URL" in *\"*|*\\*|*[[:space:][:cntrl:]]*) err "LOKI_SYNC_URL can't contain spaces, quotes or backslashes"; exit 1 ;; esac
    src="${LOKI_SYNC_URL#https://}"; src="${src%%[/?#]*}"
    case "$src" in *@*) err "Leave the user name and password out of LOKI_SYNC_URL"; exit 1 ;; esac
    src="${LOKI_SYNC_URL%%[?#]*}"  # the query may hold a token: keep it out of the log
    log "Fetching machines.json from $src ..."
    # Same flags as the app. -q (first) skips ~/.curlrc; the URL comes on stdin (-K -), not the command
    # line, where any user could read it with ps; https only, redirects included; size and time capped.
    printf 'url = "%s"\n' "$LOKI_SYNC_URL" |
      curl -q -K - -fsSL --proto =https --proto-redir =https --max-filesize 1000000 --max-time 30 -o "$CONF_PATH.tmp" ||
      { rm -f "$CONF_PATH.tmp"; err "Could not download $src"; exit 1; }
  else
    ssh_user="${LOKI_SSH_USER:-root}"
    ssh_host="${LOKI_SSH_HOST:?Please set LOKI_SSH_HOST (or LOKI_SYNC_URL) in ~/.loki/config or your shell profile}"
    ssh_port="${LOKI_SSH_PORT:-22}"
    remote_path="${LOKI_REMOTE_MACHINES_JSON:-/mnt/machines.json}"

    log "Fetching machines.json from $ssh_user@$ssh_host:$remote_path ..."
    scp -P "$ssh_port" "$ssh_user@$ssh_host:$remote_path" "$CONF_PATH.tmp" || { rm -f "$CONF_PATH.tmp"; err "Could not fetch $remote_path from $ssh_host"; exit 1; }
  fi
  # Checked as the app checks it, before it replaces anything
  if [ "$(wc -c < "$CONF_PATH.tmp")" -gt 1000000 ]; then problems="it is over 1 MB, which no machine list is"
  else problems=$(machine_problems true < "$CONF_PATH.tmp"); fi
  if [ -n "$problems" ]; then
    rm -f "$CONF_PATH.tmp"
    err "The downloaded file was rejected, so your machines are unchanged:"
    printf '%s\n' "$problems" >&2  # not echo -e: it quotes the download, which could hold escape sequences
    exit 1
  fi
  # Save what was checked, as jq read it, not the raw bytes: jq keeps the last of two duplicate keys and
  # the app the first, so a hostile first copy could otherwise pass this check and reach the app.
  if ! { jq . "$CONF_PATH.tmp" > "$CONF_PATH.new" && mv -f "$CONF_PATH.new" "$CONF_PATH"; }; then
    rm -f "$CONF_PATH.tmp" "$CONF_PATH.new"
    err "Could not save machine.json"
    exit 1
  fi
  rm -f "$CONF_PATH.tmp"
  ok "✅ Updated local machines.json"
  active=$(get_active)
  [ -z "$active" ] && return 0  # nothing connected, nothing to reload
  if jq -e --arg n "$active" 'has($n)' "$CONF_PATH" >/dev/null; then
    cmd_reload
  else
    log "Active machine $active is no longer in machine.json, disconnecting"
    apply_conf "$active"
    rm -f "$ACTIVE_FILE"
    ok "✅ Disconnected: $active was removed from machine.json"
  fi
  return 0
}

cmd_disconnect() {
  cmd_reload --no-withConfig  # exits on failure, so 'active' is only cleared once nginx let go
  rm -f "$ACTIVE_FILE"
  ok "✅ Disconnected"
}

cmd_edit() {
  "${EDITOR:-vi}" "$CONF_PATH"
}

cmd_tui() {
  command -v tmux >/dev/null 2>&1 || { err "tmux is not installed. Install it with: brew install tmux (or apt/yum equivalent)"; exit 1; }
  command -v fzf >/dev/null 2>&1 || { err "fzf is not installed. Install it with: brew install fzf (or apt/yum equivalent)"; exit 1; }

  local session="loki-tui"
  # tmux runs pane commands via a plain shell, which can't find a bare
  # relative $0 (e.g. "loki.sh" from `bash loki.sh tui`) -- resolve to an
  # absolute path so the pane can always re-invoke this same script.
  local self_path
  self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  if tmux has-session -t "$session" 2>/dev/null; then
    if [ -n "$TMUX" ]; then
      tmux switch-client -t "$session"
    else
      tmux attach-session -t "$session"
    fi
    return
  fi

  tmux new-session -d -s "$session" -n loki "$self_path" _tui_menu
  tmux split-window -h -t "$session:loki" -p 33 "$self_path" _tui_watch
  tmux select-pane -t "$session:loki.0"

  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

tui_pause() {
  echo
  read -n 1 -s -r -p "Press any key to continue..."
}

# One arrow-key list covering connect/reconnect/disconnect: every machine is
# a row (active one marked), plus a leading "Disconnect" row when applicable.
# Picking a machine (even the active one) reconnects it; no separate
# "reconnect" command needed.
tui_pick_machine() {
  if [ ! -f "$CONF_PATH" ]; then
    err "machine.json not found. Run 'loki init' first."
    tui_pause
    return
  fi

  local active picked name
  active=$(get_active)
  picked=$(
    {
      [ -n "$active" ] && echo "x Disconnect"
      jq -r --arg active "$active" '
        keys[] | if . == $active then "* " + . + "  (active)" else "  " + . end
      ' "$CONF_PATH"
    } | fzf --height=90% --reverse --header="Enter to connect, Esc to cancel" --prompt="machine > "
  )

  [ -z "$picked" ] && return

  if [ "$picked" = "x Disconnect" ]; then
    ( cmd_disconnect )
  else
    name=$(echo "$picked" | sed -E 's/^\* //; s/^  //; s/  \(active\)$//')
    ( cmd_connect "$name" )
  fi
  tui_pause
}

cmd_tui_menu() {
  local choice
  while true; do
    clear
    choice=$(printf '%s\n' \
      "Switch machine" \
      "Status" \
      "Reload config" \
      "Sync machines" \
      "Ping services" \
      "Edit machines" \
      "Quit" | fzf --height=90% --reverse --header="loki -- Enter to select, Esc to cancel" --prompt="loki > ")

    case "$choice" in
      "") continue ;;
      "Switch machine") tui_pick_machine ;;
      "Status") ( cmd_status ); tui_pause ;;
      "Reload config") ( cmd_reload ); tui_pause ;;
      "Sync machines") ( cmd_sync ); tui_pause ;;
      "Ping services") ( cmd_ping ); tui_pause ;;
      "Edit machines") cmd_edit ;;
      "Quit")
        tmux kill-session -t loki-tui 2>/dev/null
        exit 0
        ;;
    esac
  done
}

cmd_tui_watch() {
  local interval=60 min=10 max=300 step=10 key status_snapshot
  # status rarely changes (only on connect/disconnect from the menu pane), so
  # it's captured once instead of re-querying it on every refresh tick; only
  # ping (genuinely time-varying) re-runs on the interval.
  status_snapshot=$( ( cmd_status ) 2>&1 )
  while true; do
    clear
    ok "[ - ]  refresh: ${interval}s  [ + ]   (press -/+ to adjust)"
    echo
    ok "== status =="
    echo "$status_snapshot"
    echo
    ok "== ping =="
    ( cmd_ping )

    key=""
    read -t "$interval" -n 1 -s key
    case "$key" in
      +|=) interval=$((interval + step)); [ "$interval" -gt "$max" ] && interval=$max ;;
      -|_) interval=$((interval - step)); [ "$interval" -lt "$min" ] && interval=$min ;;
    esac
  done
}


# ---------- CLI Dispatcher ----------

cmd="$1"; shift || true
case "$cmd" in
  init) cmd_init ;;
  list) cmd_list ;;
  connect) cmd_connect "$@" ;;
  disconnect) cmd_disconnect ;;
  status) cmd_status ;;
  ping) cmd_ping ;;
  reload) cmd_reload "$@" ;;
  sync) cmd_sync "$@" ;;
  edit) cmd_edit ;;
  tui) cmd_tui ;;
  _tui_menu) cmd_tui_menu ;;
  _tui_watch) cmd_tui_watch ;;
  *)
    echo "Usage: loki <command>"
    echo
    echo "Commands:"
    echo "  init                     Initialize ~/.loki"
    echo "  list                     List all machines"
    echo "  connect <machine>        Set active machine"
    echo "  disconnect               Disconnect from active machine"
    echo "  status                   Show active machine and ports"
    echo "  ping                     Curl-check services on localhost"
    echo "  reload                   Generate & reload remote.conf"
    echo "  sync                     Fetch machine.json from LOKI_SYNC_URL (https) or over SSH"
    echo "  edit                     Edit machine.json in \$EDITOR"
    echo "  tui                      Open interactive tmux dashboard"
    echo
    ok "-------------------------\nversion:$VERSION\n-------------------------"
    echo
    ;;
esac
