#!/bin/zsh
# Builds AgentHub.app into ./build.
#   --install  copy it to /Applications (release build)
#   --debug    fast incremental debug build, used by scripts/dev.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="0.1.0"
APP="build/AgentHub.app"
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

swift build -c "$CONFIG" --product AgentHub
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AgentHub"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentHub"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentHub</string>
    <key>CFBundleDisplayName</key><string>AgentHub</string>
    <key>CFBundleIdentifier</key><string>dev.agenthub.app</string>
    <key>CFBundleExecutable</key><string>AgentHub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. After a rebuild macOS may ask once more for Keychain access.
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/AgentHub.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/AgentHub.app"
else
    echo "Built $APP (open it with: open $APP)"
fi
