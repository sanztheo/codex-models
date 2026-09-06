#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
app_bundle="$script_dir/../Codex Models.app"
binary_path="$app_bundle/Contents/MacOS/CodexModels"

rm -rf -- "$app_bundle"
mkdir -p -- "$(dirname -- "$binary_path")"
mkdir -p -- "$app_bundle/Contents/Resources"
cp -- "$script_dir/Resources/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"

xcrun swiftc \
    -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -parse-as-library \
    -framework AppKit \
    -framework SwiftUI \
    "$script_dir"/Sources/*.swift \
    -o "$binary_path"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Codex Models</string>
    <key>CFBundleExecutable</key>
    <string>CodexModels</string>
    <key>CFBundleIdentifier</key>
    <string>local.sanz.codexmodels</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Models</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app_bundle"
printf 'Built %s\n' "$app_bundle"
