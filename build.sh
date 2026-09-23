#!/bin/bash
# Builds Music Island into build/MusicIsland.app (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# The .noindex suffix keeps Spotlight from listing the build copy next to the installed app.
APP="build.noindex/Music Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MusicIsland "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $APP"

# ./build.sh install — replace the copy in /Applications and relaunch it.
if [[ "${1:-}" == "install" ]]; then
    pkill -x MusicIsland || true
    rm -rf "/Applications/Music Island.app"
    cp -R "$APP" /Applications/
    open "/Applications/Music Island.app"
    echo "Installed to /Applications"
fi
