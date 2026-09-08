#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
printf 'Built OpenTile in %s\n' "$(swift build -c release --show-bin-path)"
