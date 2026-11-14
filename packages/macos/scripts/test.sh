#!/usr/bin/env bash
# Runs the LokiCore tests (Swift Testing).
#   scripts/test.sh                  all tests
#   scripts/test.sh --filter Sync    only matching tests
# Uses `swift test` when SwiftPM works; otherwise (e.g. a broken Command Line Tools
# install) compiles LokiCore + Tests with swiftc and runs them with the same test library.
set -euo pipefail
cd "$(dirname "$0")/.."

if swift package describe >/dev/null 2>&1; then
  exec swift test "$@"
fi

echo "SwiftPM unavailable, running tests with swiftc" >&2
dev=$(xcode-select -p)
frameworks="$dev/Library/Developer/Frameworks"
[ -d "$frameworks" ] || frameworks="$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libs="$dev/Library/Developer/usr/lib"
[ -d "$libs" ] || libs="$dev/Platforms/MacOSX.platform/Developer/usr/lib"
plugins="$dev/usr/lib/swift/host/plugins/testing"

# TEST_OUT / TEST_FILES let parallel runs use separate build folders or a subset of test files.
out="${TEST_OUT:-.build/swiftc-tests}"
files=(${TEST_FILES:-Tests/LokiCoreTests/*.swift})
rm -rf "$out"
mkdir -p "$out"
common=(-parse-as-library -Onone -swift-version 5 -enable-bare-slash-regex -target "$(uname -m)-apple-macos14")

swiftc "${common[@]}" -enable-testing -module-name LokiCore \
  -emit-module -emit-module-path "$out/LokiCore.swiftmodule" \
  -emit-library -static -o "$out/libLokiCore.a" Sources/LokiCore/*.swift

cat > "$out/main.swift" <<'EOF'
import Testing
@main struct TestMain { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }
EOF

swiftc "${common[@]}" -module-name LokiCoreTests -I "$out" -L "$out" -lLokiCore \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs" \
  -plugin-path "$plugins" \
  "${files[@]}" "$out/main.swift" -o "$out/run-tests"

exec "$out/run-tests" "$@"
