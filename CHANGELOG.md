# Changelog

All notable changes to LOKI are documented here.

## [Unreleased]

### Added
- The macOS app has its own icon instead of the generic one.
- **Shared services in `machine.json`**: `containers` maps machine names to IPs, and each of those machines
  gets the top-level `services`, so machines that run the same services list them once. Every other key
  is still a machine with its own `ip` and `services`, so existing files work unchanged. Both packages
  read it, sync and import keep it as written, and the app's Machines tab has *Use shared services*. A
  machine can no longer be called `containers` or `services`.
- **Sync from a URL**: `machine.json` can come from an `https://` address such as a gist's Raw link, in the
  app's Sync tab (with *Test download*) or `LOKI_SYNC_URL` for the CLI. It wins over SSH when set.
- **Health check interval** in the app's Settings → General: every 15 seconds to 10 minutes (default 1 minute).
- **Update button**: the app checks GitHub for a newer release at launch and daily (hourly while it can't
  be reached) and shows a link to the releases page in the panel and an Update button in Settings →
  General. Nothing installs by itself.
- Security tests for both packages (`SecurityTests.swift`, `test_security_*` in the CLI suite) and parity
  tests that both reject the same unsafe downloads.

### Changed
- **nginx listens on 127.0.0.1 only.** Before, every proxied port was open on all network interfaces, so
  anyone on the same network could use your machine to reach the remote ones (VPN-only hosts included).
  Reaching them from another device no longer works. If another device can still reach a port after you
  update and reconnect, restart nginx once (`brew services restart nginx`).
- **CLI sync is as strict as the app's:** a downloaded `machine.json` with a service missing a port, a
  local port used twice, or anything else the app never accepted is now rejected, and your machines are
  kept. 2.0.1 accepted such files, so a shared file that worked for CLI-only users may need fixing.
- `~/.loki` is owner-only (0700); both packages tighten a folder older versions created world-readable.
  The app writes its files there 0600. Its own preferences stay in its macOS defaults.
- `loki.log` moves to `loki.log.1` past 1 MB instead of growing forever, in both packages.

### Fixed
- Disconnect could write an unchecked IP from `machine.json` into nginx's config, where a line break ended
  the header comment and started real directives (both packages). Header values now stay on one line.
- The CLI's `sync` now checks the download like the app does and saves the JSON it checked (a file listing
  a machine twice could pass the CLI's check with one copy and reach the app with the other). `connect`
  and `reload` refuse a machine whose name, address or ports could inject a directive into nginx's config,
  and ports written like `8080.0` are written as `8080`.
- The sync URL is never on curl's command line, where other users could read it with `ps`.
- The CLI only sources `~/.loki/config` when it's yours and not writable by everyone (judging a symlink by
  its target), and `status`/`ping` no longer splice the active machine's name into a `jq` filter.
- Re-running the CLI installer (`curl … | bash`) updates an existing install instead of stopping at a prompt
  a piped script can't answer, keeps the working `loki` when the download fails, and doesn't ask for sudo
  when the link is already in place.

## [2.0.1] - 2026-11-16

### Fixed
- The app's Setup fix **Switch to my user** now deletes nginx's `/Library/LaunchDaemons` job
  (`homebrew.mxcl.nginx` or Homebrew 7's `sh.brew.nginx`, left by `sudo brew services`) instead of
  only unloading it, so nginx no longer comes back as root after a reboot.

### Changed
- GitHub Actions run only after a PR merges into main: CI on every merge, CodeQL on every merge
  (replacing the default setup that scanned PRs), Release when `VERSION` changed. A release is
  now a merged PR that bumps `VERSION`; the workflow creates the tag. Tag pushes no longer
  start a build.
- New [SETUP.md](SETUP.md): install from scratch, run nginx as yourself, fix a root nginx, and
  remove everything for a clean reinstall.

## [2.0.0] - 2026-11-14

### Added
- **Loki for macOS** (`packages/macos`): menu bar app with live service health, machine switcher,
  machine editor with import/export, sync settings and a setup assistant. It has its own Swift
  engine (LokiCore) on the same `~/.loki` files, so it doesn't need the CLI.
- Repo split into `packages/cli` and `packages/macos`, one `VERSION` file, `scripts/release.sh`,
  CI on every push and a DMG release workflow on tags.

### Changed
- CLI uses `sudo` only when nginx's config folder isn't writable or nginx runs as root.
- CLI reads sync settings from `~/.loki/config` (also written by the app).
- The 1.0.2 reload fallback now starts nginx only when no master is running, retries only on
  `Address already in use`, and matches nginx's retitled processes (`pgrep -x nginx` never did).

### Fixed
- `active` is written only after nginx accepts the config; a rejected config restores the
  previous `remote.conf` instead of deleting it; reload and copy failures now exit non-zero.
- `sync` no longer empties `machine.json` on a failed download, and disconnects when the
  connected machine was removed upstream.
- `ping` no longer hangs on a service that never answers.

## [1.0.2] - 2026-08-17

### Fixed
- `loki connect` / `loki refresh` no longer fail with `bind() ... Address already in use`
  when nginx has no running master (stale pid). Reload now falls back to killing
  stragglers and retrying `nginx` for up to 10s so listen sockets are free first.

## [1.0.1] - 2025-10-28

- Install script and CLI fixes.

## [1.0.0] - 2025-10-27

- Initial release.
