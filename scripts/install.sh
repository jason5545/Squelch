#!/bin/bash
# 把公證版裝到 /Applications/Squelch.app。只裝 scripts/release.sh 產出的 zip。
#   scripts/install.sh 0.1.0
set -euo pipefail
VERSION="${1:?usage: scripts/install.sh <version>}"
cd "$(dirname "$0")/.."
ZIP="build/dist/Squelch-$VERSION.zip"
[ -f "$ZIP" ] || { echo "missing $ZIP, run scripts/release.sh $VERSION first"; exit 1; }

TMP=$(mktemp -d)
ditto -x -k "$ZIP" "$TMP"
codesign --verify --deep --strict "$TMP/Squelch.app"
spctl -a -vv -t exec "$TMP/Squelch.app" 2>&1 | grep -q "Notarized Developer ID" || { echo "not a notarized Developer ID build"; exit 1; }

# 進度每 5 秒存一次，直接結束不會丟。用 pkill 不用 osascript，免得跳「控制其他 App」的權限視窗。
pkill -x Squelch 2>/dev/null && sleep 1 || true
rm -rf /Applications/Squelch.app
ditto "$TMP/Squelch.app" /Applications/Squelch.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$TMP/Squelch.app" 2>/dev/null || true
find "$PWD/build" -name "Squelch.app" -type d -prune 2>/dev/null | while read -r app; do
    "$LSREGISTER" -u "$app" 2>/dev/null || true
done
rm -rf "$TMP"
"$LSREGISTER" -f /Applications/Squelch.app
echo "==> installed /Applications/Squelch.app $(defaults read /Applications/Squelch.app/Contents/Info.plist CFBundleShortVersionString)"
