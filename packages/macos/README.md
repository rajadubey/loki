# Loki for macOS

A menu bar app for switching your local ports between remote machines. It doesn't need the CLI: the Swift engine in `LokiCore` reads and writes the same `~/.loki/` files, so the two stay interchangeable.

## Using it

The menu bar shows the connected machine and how many of its services are up: green when all are up, orange when some are slow or down, red when all are down or Setup needs attention. Click it, or press **⌥⌘L** anywhere:

- **Services:** health ring and one row per service with latency and HTTP status, problems first. Click a row to open `http://localhost:<port>`; right-click to copy it.
- **Machines:** every machine with a reachability dot. Click one to connect.
- **Log:** the latest lines of `~/.loki/loki.log`.
- **Options:** check now, sync, reload, disconnect, Settings (⌘,), Setup, quit.

Every 60 seconds it opens a TCP connection to each service's `ip:remote` (so non-HTTP services work too) and notifies you when one has been down for over a minute.

**Settings** has four tabs:

- **Machines:** add, edit and delete machines and services, with validation (names nginx accepts, ports 1–65535, no duplicate local ports). Import and export `machine.json`. Saving keeps `machine.json.bak` and reloads nginx when the connected machine changed.
- **Sync:** SSH host, user, port and remote path for fetching `machine.json`, with *Test connection* and *Import from shell profile* (reads `LOKI_SSH_*` exports from `~/.zshrc` and friends). SSH runs without prompts, so the host needs key login and must be in `~/.ssh/known_hosts`.
- **Setup:** checks nginx is installed, running as you, has a writable config folder and includes `remote.conf` in a `stream` block, plus machines and sync. Each problem has a fix button; the ones needing root (a stale root-owned pid file, a root nginx, folder ownership) use the standard macOS password prompt. Switching a root nginx to you also deletes its `/Library/LaunchDaemons` job, which would otherwise start it as root again at every boot. Setup opens by itself on first launch when something's missing.
- **General:** open at login, shortcut, data folder.

The app never runs `sudo`: nginx has to run as you, which is what `brew services start nginx` does, and local ports above 1024 don't need root.

## Layout

```
Package.swift
Sources/LokiCore/      engine, no UI: Machines, Store, Nginx, Sync, Health, Engine, Setup, Commands
Sources/LokiApp/       menu bar app: App, AppModel, Components, Panel/, Settings/
Tests/LokiCoreTests/   Swift Testing: unit, CLI parity and integration tests
Resources/Info.plist
Resources/AppIcon.icns app icon (see Building)
scripts/build.sh       compiles with swiftc and assembles Loki.app (--install, --dmg)
scripts/test.sh        runs the tests (swift test, or swiftc when SwiftPM isn't usable)
```

## Building

The Xcode Command Line Tools are enough:

```bash
scripts/test.sh                # all tests; scripts/test.sh --filter Sync for some
scripts/build.sh               # .build/app/Loki.app for this Mac
scripts/build.sh --install     # and copy it to /Applications
scripts/build.sh --dmg         # universal build -> .build/app/Loki-<version>.dmg
```

Two toolchain notes:

- `build.sh` uses `swiftc` directly rather than `swift build`, so it also works where SwiftPM is broken, and `test.sh` falls back the same way. `Package.swift` describes the same targets for Xcode and `swift test`.
- On the macOS 27 SDK, SwiftUI's `@State` and `@Bindable` are macros that only Xcode ships. The app keeps view state in `@Observable` classes and builds bindings with `Binding(object, \.keyPath)` (see `Components.swift`), so it builds with or without Xcode.

To change the app icon, start from a 1024×1024 PNG with the rounded tile on a transparent background (Apple's macOS template leaves about 100px around it), then convert it with tools that ship with macOS:

```bash
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```
