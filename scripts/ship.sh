#!/bin/bash
# 一鍵發版：算出下一個版本 → scripts/release.sh（自我測試、Developer ID 簽章、公證）→ scripts/install.sh → git tag。
# T3 的「發版並安裝」按鈕跑的就是這支。
#   scripts/ship.sh            小版號加一（v0.5.1 → 0.5.2）
#   scripts/ship.sh 0.6.0      指定版本
#   scripts/ship.sh --dry-run  只印出下一個版本
set -euo pipefail
cd "$(dirname "$0")/.."

last=$(git tag --list 'v*' --sort=-v:refname | head -1)
last=${last#v}
if [ "${1:-}" != "" ] && [ "${1:-}" != "--dry-run" ]; then
    VERSION="$1"
elif [ -n "$last" ]; then
    IFS=. read -r major minor patch <<<"$last"
    VERSION="$major.$minor.$((patch + 1))"
else
    VERSION=$(awk '/MARKETING_VERSION:/{print $2; exit}' project.yml)
fi

echo "==> 上一版 ${last:-（沒有 tag）}，這次發 $VERSION"
[ "${1:-}" = "--dry-run" ] && exit 0

if [ -n "$(git status --porcelain)" ]; then
    echo "工作目錄有沒 commit 的改動，先 commit 再發版："
    git status --short
    exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION 已經有了"
    exit 1
fi

scripts/release.sh "$VERSION"
scripts/install.sh "$VERSION"
open /Applications/Squelch.app

git tag "v$VERSION"
git push -q origin "v$VERSION"
echo "==> 發版完成：Squelch $VERSION 已裝到 /Applications 並打開，tag v$VERSION 已推上 GitHub"
