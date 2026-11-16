# Setting up Loki

Loki needs nginx running **as you**, then the app, the CLI, or both. They share `~/.loki/`.

## 1. Requirements

- macOS 14 or later for the app; macOS or Linux for the CLI
- [Homebrew](https://brew.sh) on macOS
- For the CLI: `jq` and `curl` (`tmux` and `fzf` only for `loki tui`)

## 2. nginx, running as you

```bash
brew install nginx
brew services start nginx
```

Never start it with `sudo nginx` or `sudo brew services`. That runs nginx as root, leaves root-owned files behind, and installs a launchd job in `/Library/LaunchDaemons` that starts root nginx again at every boot. Loki only proxies ports above 1024, which don't need root.

Check that it runs as you; this prints your user name:

```bash
ps -o user= -p "$(pgrep -f 'nginx: master')"
```

If it prints `root`, see [nginx runs as root](#nginx-runs-as-root).

## 3. The app (macOS)

1. Download `Loki-<version>.dmg` from [Releases](https://github.com/rajadubey/loki/releases), open it and drag Loki to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loki.app
   ```
3. On first launch, **Setup** opens and checks everything. Click the fix next to each problem: install or start nginx, switch a root nginx to you, make the config folder yours, add `stream { include …/remote.conf; }` to nginx.conf. Fixes that need root show the macOS password prompt once.
4. Add machines: **Settings → Sync** with your team's SSH host, user, port and the path of `machine.json` there (key login, host in `~/.ssh/known_hosts`), then **Sync**. Or add or import them in **Settings → Machines**.
5. Pick a machine from the menu bar icon.

## 4. The CLI (macOS and Linux, optional)

```bash
brew install jq curl                    # macOS; Linux: sudo apt install jq curl nginx openssh-client
curl -o- https://raw.githubusercontent.com/rajadubey/loki/main/packages/cli/install.sh | bash
loki connect <machine>
loki status
```

It uses `sudo` only when nginx's config folder isn't writable or nginx runs as root (the norm on Linux, where nginx comes from apt).

## 5. Check it works

After connecting, every `local` port in `machine.json` reaches its machine:

```bash
nc -z localhost 8081 && echo ok         # use one of your local ports
```

## nginx runs as root

The app says *"nginx here belongs to root"*, or Setup shows *nginx runs as root*. In Setup, click **Switch to my user**. By hand, the same fix (errors about jobs or files that don't exist are fine):

```bash
sudo launchctl bootout system/homebrew.mxcl.nginx; sudo launchctl bootout system/sh.brew.nginx
sudo rm -f /Library/LaunchDaemons/homebrew.mxcl.nginx.plist /Library/LaunchDaemons/sh.brew.nginx.plist
sudo nginx -s stop; sudo rm -f /opt/homebrew/var/run/nginx.pid
sudo chown -R "$USER" /opt/homebrew/etc/nginx /opt/homebrew/var/run/nginx /opt/homebrew/var/log/nginx
brew services restart nginx
```

Unloading the launchd job isn't enough: as long as its plist stays in `/Library/LaunchDaemons`, root nginx comes back at the next boot.

## Remove everything (clean reinstall)

```bash
# 1. Keep a copy of your machines and logs
cp -R ~/.loki ~/loki-backup

# 2. The app and its settings
osascript -e 'quit app "Loki"'
rm -rf /Applications/Loki.app
defaults delete local.loki.bar

# 3. The CLI and the shared data
sudo rm -f /usr/local/bin/loki
rm -rf ~/.loki
# then delete the LOKI lines from ~/.profile (LOKI_DIR, PATH) and ~/.zshrc (LOKI_SSH_*)

# 4. Loki's nginx wiring
rm -f /opt/homebrew/etc/nginx/remote.conf /opt/homebrew/etc/nginx/remote.conf.prev
# then delete the `include …/remote.conf;` line from the stream block in nginx.conf

# 5. nginx itself (Homebrew keeps /opt/homebrew/etc/nginx)
brew services stop nginx
brew uninstall nginx
```

If nginx ever ran as root, also remove its launchd job as in [nginx runs as root](#nginx-runs-as-root). To set up again, start from step 2; restore your machines with `mkdir -p ~/.loki && cp ~/loki-backup/machine.json ~/.loki/`, or sync them.
