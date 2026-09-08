#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/package/OpenTile.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/OpenTile" "$app_dir/Contents/MacOS/OpenTile"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenTile</string>
<key>CFBundleIdentifier</key><string>com.mokshagna.opentile</string>
<key>CFBundleName</key><string>OpenTile</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/.build/package/OpenTile-macOS-arm64.zip"
(cd "$PWD/.build/package" && shasum -a 256 OpenTile-macOS-arm64.zip > SHA256.txt)
