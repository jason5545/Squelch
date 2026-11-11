#!/bin/bash
# 把程式碼裡的介面字串收進 Resources/Localizable.xcstrings，列出還沒翻譯的。先跑過 make build。
#   scripts/sync-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DATA=build/xcode/Build/Intermediates.noindex/Squelch.build/Debug/Squelch.build/Objects-normal/arm64
ls "$DATA"/*.stringsdata >/dev/null 2>&1 || { echo "找不到 .stringsdata，先跑 make build"; exit 1; }
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$DATA"/*.stringsdata
python3 - <<'PY'
import json, sys
d = json.load(open('Resources/Localizable.xcstrings'))
need = ['en', 'ja', 'zh-Hans', 'zh-Hant']
bad = []
for k, v in d['strings'].items():
    if v.get('shouldTranslate', True) is False:
        continue
    if v.get('extractionState') == 'stale':
        bad.append(f'（程式碼裡已經沒有）{k}')
        continue
    locs = v.get('localizations', {})
    miss = [l for l in need if l not in locs]
    if miss:
        bad.append(f'缺 {",".join(miss)}：{k}')
if bad:
    print('\n'.join(bad))
    sys.exit(1)
print(f'{len(d["strings"])} 個字串，四種語言都齊了')
PY
