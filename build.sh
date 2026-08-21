#!/bin/zsh
# OpenTile build script.
#
# NOTE: `swift build` is currently broken on this machine — the CommandLineTools
# install is a broken partial upgrade (compiler 6.2.3 vs SDK/ManifestAPI 6.2,
# duplicate SwiftBridging modulemaps). This script works around both issues:
#   1. -sdk MacOSX15.5.sdk        → SDK matching the compiler
#   2. -vfsoverlay .build/mask.yaml → masks the duplicate bridging.modulemap
#
# Once CLT is reinstalled (`sudo rm -rf /Library/Developer/CommandLineTools &&
# xcode-select --install`), plain `swift build` should work again.

set -e
cd "$(dirname "$0")"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
OVERLAY=.build/mask.yaml

mkdir -p .build/bin
if [[ ! -f "$OVERLAY" ]]; then
  : > /tmp/empty.modulemap
  printf '{\n "version": 0,\n "case-sensitive": false,\n "roots": [\n  { "name": "/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap", "type": "file", "external-contents": "/tmp/empty.modulemap" }\n ]\n}\n' > "$OVERLAY"
fi

swiftc -O \
  -sdk "$SDK" \
  -vfsoverlay "$OVERLAY" \
  Sources/OpenTile/main.swift \
  -Xcc -fmodule-map-file=Sources/OpenTile/include/module.modulemap \
  -F /System/Library/PrivateFrameworks \
  -framework MultitouchSupport \
  -o .build/bin/OpenTile

echo "built → .build/bin/OpenTile"
