#!/bin/bash
# Xcode 建置階段（project.yml 的 postBuildScripts）：把 build/vendor/tools 複製進 Squelch.app，由內往外逐一簽章
# （hardened runtime）。deno 是單一執行檔，放 Contents/Helpers；yt-dlp 的 onedir 混著資料檔（cacert.pem、.js），
# 放在 Helpers 會被當成沒簽章的程式，所以整包放 Contents/Resources/yt-dlp。Xcode 之後簽 App 本體時會把它們一起封進去；
# 發版時 xcodebuild -exportArchive 會再用 Developer ID 重簽。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/vendor-tools.sh"

SRC="$ROOT/build/vendor/tools"
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
YTDIR="$CONTENTS/Resources/yt-dlp"
DENO="$CONTENTS/Helpers/deno"
ENT="$ROOT/Resources/Entitlements"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="-"
TIMESTAMP="--timestamp=none"
[ "$CONFIGURATION" = "Release" ] && [ "$IDENTITY" != "-" ] && TIMESTAMP="--timestamp"

# 內容沒變而且已經簽過就跳過（Debug 每次建置都會跑，複製 150 MB 太慢）。
MARK="$DERIVED_FILE_DIR/embedded-tools.signed"
WANT="$(cat "$SRC/.stamp") $IDENTITY $CONFIGURATION"
if [ -f "$MARK" ] && [ "$(cat "$MARK")" = "$WANT" ] && codesign --verify "$YTDIR/yt-dlp_macos" 2>/dev/null; then
    exit 0
fi

rm -rf "$YTDIR" "$DENO"
mkdir -p "$CONTENTS/Helpers" "$DERIVED_FILE_DIR"
ditto "$SRC/yt-dlp" "$YTDIR"
ditto "$SRC/deno" "$DENO"

sign() { codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$@"; }
INTERNAL="$YTDIR/_internal"
find "$INTERNAL" -type f \( -name "*.so" -o -name "*.dylib" \) -not -path "*/Python.framework/*" -print0 \
    | xargs -0 -P 8 -n 16 codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP
sign "$INTERNAL/Python.framework"
sign --entitlements "$ENT/yt-dlp.entitlements" "$YTDIR/yt-dlp_macos"
sign --entitlements "$ENT/deno.entitlements" "$DENO"
echo "$WANT" > "$MARK"
