# Loki

Loki switches your local ports between remote machines. You list machines and their services once; Loki writes an nginx TCP (`stream`) proxy so `localhost:8081` reaches `user_service_api` on whichever machine you pick, and tells you which services are up.

Two packages share the same data in `~/.loki/`, so you can use either or both:

| Package | What | Platforms |
|---|---|---|
| [`packages/macos`](packages/macos) | **Loki.app**, a menu bar app: switch machines, live health, machine editor, sync and a setup assistant | macOS 14+ |
| [`packages/cli`](packages/cli) | `loki`, a bash CLI with a tmux dashboard | macOS, Linux |

## Install

Step by step, including nginx and a clean reinstall: **[SETUP.md](SETUP.md)**. In short:

- **App:** download `Loki-<version>.dmg` from [Releases](https://github.com/rajadubey/loki/releases), drag Loki to Applications, and allow the first launch in System Settings → Privacy & Security → Open Anyway (the app isn't notarized). On first launch, Setup checks nginx and fixes what's missing.
- **CLI:** `curl -o- https://raw.githubusercontent.com/rajadubey/loki/main/packages/cli/install.sh | bash`

## Shared data (`~/.loki/`)

| File | Contents |
|---|---|
| `machine.json` | Machines and their services (format below) |
| `active` | Name of the connected machine |
| `config` | Sync settings (`LOKI_SSH_HOST='…'` etc.), written by the app's Sync tab, sourced by the CLI |
| `remote.conf` | Last generated nginx config (the live copy sits next to `nginx.conf`) |
| `loki.log` | Log of every operation, from both packages |

```json
{
  "aws_machine": {
    "ip": "54.123.45.67",
    "services": {
      "organisation_common_api": { "local": 8082, "remote": 80 },
      "lambda_helper_api": { "local": 8083, "remote": 3000 }
    }
  }
}
```

nginx listens on each `local` port and forwards it to `ip:remote`. nginx.conf needs the generated file inside a top-level `stream` block; the app's Setup adds it for you:

```nginx
stream {
    include /opt/homebrew/etc/nginx/remote.conf;
}
```

## Repository layout

```
VERSION                  single version for both packages
packages/cli/            loki.sh, install.sh, uninstall.sh, tests/run.sh
packages/macos/          Swift package: LokiCore (engine), LokiApp (menu bar app), tests, scripts/
scripts/release.sh       bump version, test, commit, push a branch to open the release PR from
.github/workflows/       ci.yml, codeql.yml, release.yml: all run only after a merge into main
```

## Development

```bash
bash packages/cli/tests/run.sh       # CLI tests
packages/macos/scripts/test.sh       # Swift tests (unit, CLI parity, integration)
packages/macos/scripts/build.sh      # builds packages/macos/.build/app/Loki.app
```

GitHub Actions run only after a PR merges into main (CI, CodeQL, and Release when `VERSION` changed); nothing runs on PRs or other branches, so run both test suites before you merge. CodeQL's repo-level *default setup* must stay off (Settings → Code security → CodeQL analysis), because it scans every PR and blocks `codeql.yml`.

## Releasing

A release is a PR that bumps `VERSION`. Run `scripts/release.sh 2.1.0` on a branch from a clean working tree: it sets `VERSION` and the CLI's `VERSION=`, runs both test suites, commits and pushes the branch after you confirm. Open a PR and merge it.

The merge starts `.github/workflows/release.yml`. It tests again, builds a universal DMG stamped with the version, creates tag `2.1.0` on the merged commit and publishes a release with `Loki-2.1.0.dmg`, its SHA-256 and `loki.sh`. If that version was already released, the run fails and nothing is replaced. The CLI's `install.sh` always downloads `loki.sh` from the latest release, or a given one with `LOKI_VERSION=2.1.0`.

To rebuild an existing release (or add the files to one drafted on GitHub's release page), run the workflow by hand from main: **Actions → Release → Run workflow** with its tag, or `gh workflow run release.yml -f tag=2.1.0`. It builds the tagged commit and replaces the files.
