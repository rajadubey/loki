#!/usr/bin/env bash
# Prepares a release of both packages: scripts/release.sh 1.1.0
#   1. sets VERSION and VERSION= in packages/cli/loki.sh
#   2. runs the CLI and macOS test suites and builds the app (fails before committing if anything breaks)
#   3. commits "Release 1.1.0"
#   4. after you confirm, pushes the branch. Open a PR from it; merging it into main starts
#      .github/workflows/release.yml, which creates tag 1.1.0 and publishes Loki-1.1.0.dmg.
#      Nothing is built or released before the merge.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh X.Y.Z (e.g. 1.1.0)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree has uncommitted changes; commit or stash them first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$version" >/dev/null && { echo "Tag $version already exists." >&2; exit 1; }
git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1 && { echo "Tag $version already exists on origin." >&2; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != main ] || { echo "Run this on a branch: releases go through a PR into main." >&2; exit 1; }
echo "Releasing $(cat VERSION) -> $version from branch $branch"

printf '%s\n' "$version" > VERSION
sed -i '' "s/^VERSION=.*/VERSION=$version/" packages/cli/loki.sh

echo "Running tests…"
bash packages/cli/tests/run.sh >/dev/null
packages/macos/scripts/test.sh >/dev/null
packages/macos/scripts/build.sh >/dev/null

git add VERSION packages/cli/loki.sh
git commit -q -m "Release $version"
echo "Committed Release $version on $branch."

read -r -p "Push $branch to origin? Merging it into main publishes $version. [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
  git push -u origin "$branch"
  echo "Pushed. Open a PR (gh pr create) and merge it to release; then: gh run watch -R rajadubey/loki"
else
  echo "Not pushed. When ready: git push -u origin $branch"
  echo "To undo: git reset --hard HEAD~1"
fi
