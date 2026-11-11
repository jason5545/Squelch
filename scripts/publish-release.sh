#!/bin/bash
# 把 build/dist/Squelch-<版本>.zip 發成 GitHub Release（tag 要先推上去）。
# 除了帶版本號的 zip，也上傳一份 Squelch.zip，讓
# https://github.com/jason5545/Squelch/releases/latest/download/Squelch.zip 永遠指到最新版（介紹頁的下載按鈕用這個）。
#   scripts/publish-release.sh 0.6.0 [上一版]
set -euo pipefail
VERSION="${1:?usage: scripts/publish-release.sh <version> [previous-version]}"
PREV="${2:-}"
cd "$(dirname "$0")/.."
ZIP="build/dist/Squelch-$VERSION.zip"
[ -f "$ZIP" ] || { echo "找不到 $ZIP"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$ZIP" "$STAGE/Squelch.zip"

{
    echo "Developer ID 簽章、Apple 公證。需要 macOS 26（Apple Silicon）。yt-dlp 和 deno 已經包在 App 裡，不用另外安裝。"
    echo
    echo "Signed with Developer ID and notarized by Apple. Requires macOS 26 on Apple Silicon. yt-dlp and deno are included; nothing else to install."
    echo
    echo "## 這一版"
    echo
    if [ -n "$PREV" ] && git rev-parse "v$PREV" >/dev/null 2>&1; then
        git log --format='- %s' "v$PREV..v$VERSION" --no-merges
    else
        git log --format='- %s' -20 "v$VERSION" --no-merges
    fi
} > "$STAGE/notes.md"

gh release create "v$VERSION" "$ZIP" "$STAGE/Squelch.zip" \
    --repo jason5545/Squelch --title "Squelch $VERSION" --notes-file "$STAGE/notes.md" --latest
echo "==> https://github.com/jason5545/Squelch/releases/tag/v$VERSION"
