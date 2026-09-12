#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools bundle Swift Testing, but SwiftPM needs its framework
# and runtime paths explicitly. Full Xcode supplies these automatically.
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
frameworks="$developer_dir/Library/Developer/Frameworks"
flags=(--disable-xctest)
if [[ -d "$frameworks/Testing.framework" ]]; then
    flags+=(
        -Xswiftc "-F$frameworks"
        -Xlinker "-F$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
    )
fi

exec swift test "${flags[@]}" "$@"
