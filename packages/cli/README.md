# loki CLI

`loki` is the bash version of Loki for macOS and Linux. It reads and writes the same `~/.loki/` files as the macOS app (see the [repo README](../../README.md) for the file formats), so you can switch between the two.

## Install

```bash
curl -o- https://raw.githubusercontent.com/rajadubey/loki/main/packages/cli/install.sh | bash
```

Dependencies:

```bash
brew install jq curl nginx tmux fzf                          # macOS (jq ships with macOS 15+)
sudo apt install jq curl nginx tmux fzf openssh-client       # Ubuntu/Debian
```

`tmux` and `fzf` are only needed for `loki tui`. Uninstall with `bash uninstall.sh`.

To update, run the install command again: it replaces the `loki` script with the latest release's and keeps your machines and settings. If the download fails, the installed `loki` stays as it was.

## Commands

```bash
loki init                    # create ~/.loki and fetch machine.json (runs sync)
loki list                    # list machines, the connected one marked
loki connect aws_machine     # route local ports to aws_machine
loki disconnect              # stop routing
loki status                  # connected machine and its port mappings
loki ping                    # HTTP-check every service through localhost
loki reload                  # regenerate and reload nginx config
loki sync                    # fetch machine.json from LOKI_SYNC_URL, or over SSH
loki edit                    # open machine.json in $EDITOR
loki tui                     # tmux dashboard: menu plus live status
```

`connect`, `reload` and `disconnect` write `remote.conf` next to `nginx.conf`, run `nginx -t` (restoring the previous file if it fails), reload nginx, and only then update `~/.loki/active`. They use `sudo` only when nginx's config folder isn't writable or nginx runs as root, which is typical on Linux; Homebrew nginx run as you needs none.

## Sync settings

`loki sync` reads these from `~/.loki/config` (the macOS app's Sync tab writes the same file) or from your environment:

```bash
# From a URL (wins when set): https only, e.g. a gist's Raw link without the commit id
LOKI_SYNC_URL='https://gist.githubusercontent.com/you/abc123/raw/machine.json'

# Or over SSH
LOKI_SSH_USER='ubuntu'                       # default root
LOKI_SSH_HOST='54.123.45.67'                 # required for SSH
LOKI_SSH_PORT='22'                           # default 22
LOKI_REMOTE_MACHINES_JSON='/opt/machines.json'  # default /mnt/machines.json
```

The download replaces `machine.json` only if it passes the app's checks: valid JSON, names and addresses nginx can't misread, ports from 1 to 65535 and no local port used twice. Otherwise sync says what's wrong and changes nothing. `connect` and `reload` check the machine the same way before writing nginx's config. A token in the URL's query (`?token=…`) is never written to `loki.log`.

## Your data

`~/.loki/` holds machine addresses and maybe a sync token, so `loki` keeps the folder owner-only (0700) like `~/.ssh`; an older world-readable folder is tightened on the next run. `config` runs as shell code, so `loki` only reads it when it's yours and not writable by everyone, judging a symlinked config by the file it points to; it warns and leaves the file for you to check (`chmod 600 ~/.loki/config`). The sync URL reaches curl on stdin, never its command line, where `ps` would show it to other users. `loki.log` moves to `loki.log.1` once it passes 1 MB.

The ports nginx opens listen on 127.0.0.1 only, so other devices on your network can't use your machine to reach the remote ones.

## Troubleshooting

- **nginx -t fails:** run `nginx -t` yourself to see the error, and check that `nginx.conf` has `stream { include …/remote.conf; }` at the top level.
- **A service shows Down:** check the remote machine and service are up and that firewalls allow the port.
- **Sync fails:** test with `curl -fsSL "$LOKI_SYNC_URL"`, or `ssh -p "$LOKI_SSH_PORT" "$LOKI_SSH_USER@$LOKI_SSH_HOST" cat "$LOKI_REMOTE_MACHINES_JSON"`. *The downloaded file was rejected* lists what to fix in the shared `machine.json`.
- **Logs:** `tail -f ~/.loki/loki.log`

## Tests

```bash
bash tests/run.sh   # sandboxed: fake nginx, scp and curl; never touches ~/.loki or your nginx (test_security_* cover the checks above)
```
