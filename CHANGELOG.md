# Changelog

All notable changes to LOKI are documented here.

## [Unreleased]

### Added
- The macOS app has its own icon instead of the generic one.

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
