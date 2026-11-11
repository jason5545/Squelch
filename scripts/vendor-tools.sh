#!/bin/bash
# 下載要包進 App 的 yt-dlp 和 deno（官方發行檔，核對 SHA-256），整理到 build/vendor/tools/：
#   yt-dlp/yt-dlp_macos、yt-dlp/_internal/…、yt-dlp/VERSION   官方 onedir 版，內含 Python 和 yt-dlp-ejs
#   deno                                                        yt-dlp 解 YouTube 需要的 JS 執行環境
# 只留 arm64，並補回 zip 裡丟掉的 symlink（Python.framework 才能當成 bundle 簽章）。
# 已經整理過同一版就什麼都不做。升級：改下面的版本和雜湊（雜湊在各自 Release 的 SHA2-256SUMS、.sha256sum）。
#   scripts/vendor-tools.sh [輸出目錄]
set -euo pipefail

YTDLP_VERSION=2026.10.26
YTDLP_SHA256=20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1
DENO_VERSION=2.9.8
DENO_SHA256=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/vendor/downloads"
OUT="${1:-$ROOT/build/vendor/tools}"
STAMP="$OUT/.stamp"
WANT="yt-dlp $YTDLP_VERSION deno $DENO_VERSION"
[ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] && exit 0

fetch() { # 網址 檔名 雜湊
    local file="$CACHE/$2"
    mkdir -p "$CACHE"
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$3" ]; then
        echo "==> download $2"
        curl -fsSL --retry 3 -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$3" ] || { echo "SHA-256 不符：$2"; exit 1; }
}

fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos.zip" \
    "yt-dlp_macos-$YTDLP_VERSION.zip" "$YTDLP_SHA256"
fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" \
    "deno-$DENO_VERSION.zip" "$DENO_SHA256"

STAGE="$OUT.stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/yt-dlp"
ditto -x -k "$CACHE/yt-dlp_macos-$YTDLP_VERSION.zip" "$STAGE/yt-dlp"
ditto -x -k "$CACHE/deno-$DENO_VERSION.zip" "$STAGE"

# zip 把 symlink 存成三份一樣的檔案；照 framework 的標準結構改回 symlink。
INTERNAL="$STAGE/yt-dlp/_internal"
FW="$INTERNAL/Python.framework"
PYVER=$(ls "$FW/Versions" | grep -v Current | head -1)
rm -rf "$FW/Versions/Current" "$FW/Python" "$FW/Resources" "$INTERNAL/Python"
ln -s "$PYVER" "$FW/Versions/Current"
ln -s Versions/Current/Python "$FW/Python"
ln -s Versions/Current/Resources "$FW/Resources"
ln -s "Python.framework/Versions/$PYVER/Python" "$INTERNAL/Python"

# 只留 arm64（App 本身也只有 arm64），原有的簽章拿掉，之後由 embed-tools.sh 用我們的身分簽。
find "$STAGE" -type f | while read -r f; do
    if file -b "$f" | grep -q "Mach-O"; then
        if lipo -archs "$f" 2>/dev/null | grep -qw x86_64; then
            lipo "$f" -thin arm64 -output "$f.thin" && mv "$f.thin" "$f"
        fi
        codesign --remove-signature "$f" 2>/dev/null || true
    fi
done
xattr -cr "$STAGE"
echo "$YTDLP_VERSION" > "$STAGE/yt-dlp/VERSION"
echo "$WANT" > "$STAGE/.stamp"
rm -rf "$OUT" && mv "$STAGE" "$OUT"
echo "==> tools ready: $WANT ($(du -sh "$OUT" | cut -f1))"
