#!/usr/bin/env bash
# Cuts a release of both packages: scripts/release.sh 1.1.0
# Optional: making a release on GitHub's release page works too (the tag is the version).
# This script also keeps the repo's version numbers in step:
#   1. sets VERSION and VERSION= in packages/cli/loki.sh
#   2. runs the CLI and macOS test suites and builds the app (fails before tagging if anything breaks)
#   3. commits "Release 1.1.0" and creates tag 1.1.0
#   4. after you confirm, pushes the branch and tag; .github/workflows/release.yml then
#      builds Loki-1.1.0.dmg and publishes the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh X.Y.Z (e.g. 1.1.0)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree has uncommitted changes; commit or stash them first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$version" >/dev/null && { echo "Tag $version already exists." >&2; exit 1; }
git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1 && { echo "Tag $version already exists on origin." >&2; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)
echo "Releasing $(cat VERSION) -> $version from branch $branch"

printf '%s\n' "$version" > VERSION
sed -i '' "s/^VERSION=.*/VERSION=$version/" packages/cli/loki.sh

echo "Running tests…"
bash packages/cli/tests/run.sh >/dev/null
packages/macos/scripts/test.sh >/dev/null
packages/macos/scripts/build.sh >/dev/null

git add VERSION packages/cli/loki.sh
git commit -q -m "Release $version"
git tag -a "$version" -m "Release $version"
echo "Created commit and tag $version."

read -r -p "Push $branch and tag $version to origin (starts the DMG build)? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
  git push origin "$branch"
  git push origin "$version"
  echo "Pushed. Watch the build: gh run watch -R rajadubey/loki"
else
  echo "Not pushed. When ready: git push origin $branch && git push origin $version"
  echo "To undo: git tag -d $version && git reset --hard HEAD~1"
fi
