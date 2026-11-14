#!/usr/bin/env bash
# Builds Loki.app with swiftc (the Command Line Tools are enough; no Xcode or SwiftPM needed).
#   scripts/build.sh            build for this Mac's architecture -> .build/app/Loki.app
#   scripts/build.sh --install  build and copy to /Applications
#   scripts/build.sh --dmg      universal (Apple silicon + Intel) build -> .build/app/Loki-<version>.dmg
# The version comes from the repo's VERSION file.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < ../../VERSION)
[ -n "$version" ] || { echo "VERSION file is empty" >&2; exit 1; }
mode="${1:-}"
archs=$(uname -m)
[ "$mode" = --dmg ] && archs="arm64 x86_64"

out=.build/app
app="$out/Loki.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Same flags as Package.swift: Swift 5 mode, bare /regex/ literals, macOS 14+.
flags=(-parse-as-library -O -swift-version 5 -enable-bare-slash-regex)
for arch in $archs; do
  obj="$out/obj/$arch"
  mkdir -p "$obj"
  swiftc "${flags[@]}" -target "$arch-apple-macos14" -module-name LokiCore \
    -emit-module -emit-module-path "$obj/LokiCore.swiftmodule" \
    -emit-library -static -o "$obj/libLokiCore.a" Sources/LokiCore/*.swift
  swiftc "${flags[@]}" -target "$arch-apple-macos14" -module-name LokiApp \
    -I "$obj" -L "$obj" -lLokiCore \
    $(find Sources/LokiApp -name '*.swift') -o "$obj/Loki"
done
lipo -create "$out"/obj/*/Loki -output "$app/Contents/MacOS/Loki"
rm -rf "$out/obj"

cp Resources/Info.plist "$app/Contents/"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
codesign --force -s - "$app"  # ad-hoc; Developer ID signing would remove the Gatekeeper prompt
echo "Built $app $version ($archs)"

case "$mode" in
  --install)
    rm -rf /Applications/Loki.app
    cp -R "$app" /Applications/
    echo "Installed /Applications/Loki.app"
    ;;
  --dmg)
    dmg="$out/Loki-$version.dmg"
    stage="$out/dmg"
    mkdir -p "$stage"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"  # drag-to-install target
    hdiutil create -quiet -volname "Loki $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
    rm -rf "$stage"
    (cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
    echo "Packaged $dmg"
    ;;
esac
