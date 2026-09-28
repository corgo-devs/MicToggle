#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_dir="$script_dir/MicToggle.app"
mkdir -p "$app_dir/Contents/MacOS"
cache_dir="${TMPDIR:-/tmp}/mictoggle-swift-cache"
mkdir -p "$cache_dir"

/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$cache_dir" \
  "$script_dir/MicToggle.swift" -o "$app_dir/Contents/MacOS/MicToggle" \
  -framework AppKit -framework Carbon -framework CoreAudio -framework ServiceManagement

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.mictoggle.app</string>
  <key>CFBundleName</key><string>MicToggle</string>
  <key>CFBundleDisplayName</key><string>MicToggle</string>
  <key>CFBundleExecutable</key><string>MicToggle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$script_dir/MicToggle.zip"
echo "Créés : $app_dir et $script_dir/MicToggle.zip"
