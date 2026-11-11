#!/bin/bash
# 發版：自我測試 → Xcode 雲端 Developer ID 簽章 → Apple 公證 → build/dist/Squelch-<版本>.zip
# 用 Xcode 設定裡已登入的開發者帳號（-allowProvisioningUpdates），不需要本機的 Developer ID 憑證或公證密碼。
#   scripts/release.sh 0.1.0
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
OUT=build/release
TEAM=$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)
BUILD=$(git rev-list --count HEAD)
ARCHIVE="$OUT/Squelch.xcarchive"

rm -rf "$OUT" && mkdir -p "$OUT" build/dist
make selftest
xcodegen generate --quiet

echo "==> archive $VERSION ($BUILD)"
xcodebuild archive -quiet -project Squelch.xcodeproj -scheme Squelch -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath build/xcode-release \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

echo "==> sign with Developer ID and upload for notarization"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/upload" -allowProvisioningUpdates

echo "==> waiting for notarization"
for i in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" >"$OUT/notarized.log" 2>&1; then
        break
    fi
    [ "$i" = 60 ] && { cat "$OUT/notarized.log"; echo "notarization did not finish in 30 minutes"; exit 1; }
    sleep 30
done

APP="$OUT/notarized/Squelch.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

ZIP="build/dist/Squelch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 清掉建置過程留下的 App 副本並取消 LaunchServices 登記，免得同一個 bundle ID 登記好幾份。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
find "$PWD/build" -name "Squelch.app" -type d -prune 2>/dev/null | while read -r app; do
    "$LSREGISTER" -u "$app" 2>/dev/null || true
done
rm -rf build/xcode-release "$ARCHIVE" "$OUT/notarized" "$OUT/upload"
echo "==> done: $ZIP"
