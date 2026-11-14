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

## Commands

```bash
loki init                    # create ~/.loki and fetch machine.json (runs sync)
loki list                    # list machines, the connected one marked
loki connect aws_machine     # route local ports to aws_machine
loki disconnect              # stop routing
loki status                  # connected machine and its port mappings
loki ping                    # HTTP-check every service through localhost
loki reload                  # regenerate and reload nginx config
loki sync                    # fetch machine.json over SSH
loki edit                    # open machine.json in $EDITOR
loki tui                     # tmux dashboard: menu plus live status
```

`connect`, `reload` and `disconnect` write `remote.conf` next to `nginx.conf`, run `nginx -t` (restoring the previous file if it fails), reload nginx, and only then update `~/.loki/active`. They use `sudo` only when nginx's config folder isn't writable or nginx runs as root, which is typical on Linux; Homebrew nginx run as you needs none.

## Sync settings

`loki sync` reads these from `~/.loki/config` (the macOS app's Sync tab writes the same file) or from your environment:

```bash
LOKI_SSH_USER='ubuntu'                       # default root
LOKI_SSH_HOST='54.123.45.67'                 # required
LOKI_SSH_PORT='22'                           # default 22
LOKI_REMOTE_MACHINES_JSON='/opt/machines.json'  # default /mnt/machines.json
```

## Troubleshooting

- **nginx -t fails:** run `nginx -t` yourself to see the error, and check that `nginx.conf` has `stream { include …/remote.conf; }` at the top level.
- **A service shows Down:** check the remote machine and service are up and that firewalls allow the port.
- **Sync fails:** test with `ssh -p "$LOKI_SSH_PORT" "$LOKI_SSH_USER@$LOKI_SSH_HOST" cat "$LOKI_REMOTE_MACHINES_JSON"`.
- **Logs:** `tail -f ~/.loki/loki.log`

## Tests

```bash
bash tests/run.sh   # sandboxed: fake nginx, scp and curl; never touches ~/.loki or your nginx
```
