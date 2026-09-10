#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: scripts/prepare-release.sh VERSION BUILD_NUMBER (increase both for each release)" >&2
    exit 1
fi
export OPENTILE_VERSION="$1" OPENTILE_BUILD_NUMBER="$2"
swift package resolve
sparkle="$PWD/.build/artifacts/sparkle/Sparkle/bin"
account="com.mokshagna.opentile"
# Never silently generate a replacement key: existing installations trust this key.
if [[ "$("$sparkle/generate_keys" --account "$account" -p)" != "$(cat scripts/sparkle-public-key.txt)" ]]; then
    echo "The release signing key in Keychain must match scripts/sparkle-public-key.txt." >&2
    exit 1
fi
release_dir="$PWD/.build/releases/v$1"
if [[ -e "$release_dir" ]]; then
    echo "Release output already exists: $release_dir. Use a new version or move it aside." >&2
    exit 1
fi
scripts/package.sh
mkdir -p "$release_dir"
archive="OpenTile-$1-macOS-arm64.zip"
cp .build/package/OpenTile-macOS-arm64.zip "$release_dir/$archive"
"$sparkle/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/moKshagna-p/opentile/releases/download/v$1/" \
    "$release_dir"
(cd "$release_dir" && shasum -a 256 "$archive" > SHA256.txt)
echo "Prepared signed release in $release_dir"
echo "To enable updates, publish appcast.xml, $archive, and SHA256.txt on GitHub release v$1."
