#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# A stable signing identity lets macOS recognize updates and retain permissions.
# CI can explicitly request ad-hoc signing with OPENTILE_SIGNING_IDENTITY=-.
signing_identity="${OPENTILE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    identities="$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}) ".*/\1/p')"
    count="$(printf '%s\n' "$identities" | awk 'NF { n++ } END { print n+0 }')"
    if [[ "$count" != 1 ]]; then
        echo "Set OPENTILE_SIGNING_IDENTITY to a stable code-signing identity (found $count)." >&2
        exit 1
    fi
    signing_identity="$identities"
fi
version="${OPENTILE_VERSION:-0.2.1}"
build_number="${OPENTILE_BUILD_NUMBER:-3}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Use a semantic OPENTILE_VERSION and positive integer OPENTILE_BUILD_NUMBER." >&2
    exit 1
fi
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/package/OpenTile.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks" "$app_dir/Contents/Resources"
iconset="$PWD/.build/package/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
framework="$app_dir/Contents/Frameworks/Sparkle.framework"
ditto ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$bin_dir/OpenTile" "$app_dir/Contents/MacOS/OpenTile"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenTile</string>
<key>CFBundleIdentifier</key><string>com.mokshagna.opentile</string>
<key>CFBundleName</key><string>OpenTile</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>Workspace switching</string>
<key>CFBundleURLSchemes</key><array><string>opentile</string></array>
</dict></array>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://github.com/moKshagna-p/opentile/releases/latest/download/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUEnableSystemProfiling</key><false/>
</dict></plist>
PLIST
plutil -replace CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"
plutil -insert SUPublicEDKey -string "$(cat scripts/sparkle-public-key.txt)" "$app_dir/Contents/Info.plist"
# Sign nested Sparkle components inside out, preserving helper entitlements.
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$signing_identity" --options runtime --preserve-metadata=entitlements "$framework/Versions/B/$component"
done
codesign --force --sign "$signing_identity" "$framework"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/.build/package/OpenTile-macOS-arm64.zip"
(cd "$PWD/.build/package" && shasum -a 256 OpenTile-macOS-arm64.zip > SHA256.txt)
