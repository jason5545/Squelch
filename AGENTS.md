# Squelch 協作規則

- 改完一定跑 `make selftest`，全部 PASS 才算完成。它會實際連 YouTube：清單、三條播放路徑（自己解碼的 HLS、AVPlayer 的 HLS、下載備援：長度、開播、跳轉、倍速）、音量放大、SponsorBlock、存檔。測試頻道是 @AppleDeveloper，不要換成個人訂閱的頻道。自我測試全程不出聲（`silent`），新加的播放測試也要這樣。
- 看介面用 `Squelch.app/Contents/MacOS/Squelch --snapshot <png>`，不要用 screencapture（會跳螢幕錄影權限）。離屏截圖抓不到側欄和右側「正在播放」面板（inspector）的毛玻璃，這兩欄是黑的屬正常；要看面板加 `--panel`，只畫面板。其他頁面：`--channel`（第一個頻道）、`--queue`、`--search`、`--subscriptions`；`--width 900` 看窄視窗。工具列（搜尋框、按鈕）在視窗框上，離屏截圖畫不出來；截圖會在終端機印出每個搜尋框在工具列還是側欄、x 和寬度，改到搜尋框時看這幾行（應該只有側欄一個）。離屏截圖也畫不出 `.blur` 這類圖層濾鏡，面板背景因此用縮到 6×6 的封面平滑放大（`ArtworkPalette.ambient`），不靠模糊。
- 配色、取封面色、細進度條、播放鈕這些共用元件在 `Theme.swift`。主視窗固定深色（`preferredColorScheme(.dark)`），顏色寫死成深色用的；要支援淺色模式得一起改。
- 解析 YouTube 一律交給 yt-dlp，不自己寫 InnerTube。yt-dlp 和 deno 包在 App 裡，不靠 Homebrew：版本和 SHA-256 寫在 `scripts/vendor-tools.sh`，建置時 `scripts/embed-tools.sh` 放進 App 並簽章（deno 在 `Contents/Helpers`，yt-dlp 整包在 `Contents/Resources/yt-dlp`，放 Helpers 會簽不過）。yt-dlp 壞了先在設定按「檢查更新」，要換內建的版本就改 `vendor-tools.sh` 的版本和雜湊。自我測試會關掉 Homebrew（`YTDLP.allowHomebrew`），確認用的是內建或自動更新的那份。
- App 不帶 ffmpeg。下載備援一定加 `--fixup never`，再用 `YTDLP.remux`（AVFoundation passthrough）修正分段式 MP4 的長度，不要改回依賴 ffmpeg。唯一例外是 `WatchHistory`：從影片頁取得播放紀錄的回報網址，yt-dlp 沒有提供帶真實進度的回報。
- 帶帳號的請求只有訂閱動態、觀看記錄和播放紀錄回報；解析音軌（`YTDLP.resolve`）和搜尋（`YTDLP.search`）不准加 `--cookies`。訂閱動態和觀看記錄都只在使用者打開或按重新整理時抓，不跟著自動更新跑（`refreshAvoidsAccount` 測試會檢查）。播放紀錄回報最多每 5 分鐘一次，加上開始、暫停、跳轉、聽完、換集。
- 自我測試不碰 WebKit（沒有 NSApplication 會當掉），帳號相關只測 cookie 檔和解析；已登入時會多測訂閱動態（只讀，不送播放紀錄）。
- 播放格式的取捨和實測數字寫在 README 的「怎麼播的」和「音量放大」，改格式前先讀。
- 一般影片的 HLS 由 `SegmentPlayer` 自己解碼（為了能放大超過 100%），直播和本機檔才交給 AVPlayer。`Player` 裡兩邊都要顧：碰播放、暫停、跳轉、速度、音量的地方，先看 `segmentPlayer` 是不是 nil。`SegmentPlayer` 解不了的格式會回報 `unsupported`，那一集退回 AVPlayer，這條備援不要拿掉（`Player.useSegments = false` 可以強迫走備援，自我測試在用）。
- `SegmentPlayer` 不看 renderer 的 `isReadyForMoreMediaData`（它排滿約 1 秒就說不用再給，3 倍速時不夠撐），也不要把 `delaysRateChangeUntilHasSufficientMediaData` 關掉（起播的聲音會被吃掉）。原因和實測數字在該檔的註解。
- 介面字串的原文是正體中文，翻譯在 `Resources/Localizable.xcstrings`（英、日、簡；正體中文那欄就是原文）。SwiftUI 的 `Text`、`Button`、`Label` 這類直接吃字串字面值的會自動翻譯；其他回傳 `String` 的（錯誤訊息、狀態列、`navigationTitle`、`show(...)`）一律包 `String(localized:)`。加了或改了字串，`make build` 之後跑 `scripts/sync-strings.sh` 把新字串收進目錄，再補英日簡翻譯和正體中文欄；它會列出還沒翻的字串，清單是空的才算完成。開發地區是英文：系統語言不是這四種時顯示英文。
- repo 是公開的。個人的頻道清單只存在本機的 `library.json`，不要寫進程式碼、測試或文件。

## 介紹頁

- https://squelch.hiroki.im/ 的原始檔在 `~/GitHub/hiroki.im/squelch/`：文字（正體中文、英、日、簡）全在 `src/build.py`，改完跑 `python3 src/build.py` 再 `wrangler deploy`。功能或使用方式有變時一起改。版本號和下載按鈕自動跟最新的 GitHub Release，發版不用動它。

## 本機部署

- 這台 Mac 只裝 `/Applications/Squelch.app`，而且只裝公證版：平常用 `scripts/ship.sh`（小版號自動加一、發版、安裝、打 tag、發 GitHub Release），要指定版本才分開跑 `scripts/release.sh <版本>`、`scripts/install.sh <版本>`。版本號以 git tag `v*` 為準，v0.5.1 之前的版本沒有 tag。
- 不要把 `make build` 的 Debug 版複製進 `/Applications`。
- 改版本時兩個腳本都帶同一個版本號，`project.yml` 的 `MARKETING_VERSION` 只是預設值。
- AVPlayer 跳轉後偶爾「狀態是播放中但時間不走」（自我測試約每六次一次）。`Player.checkStall` 偵測到 2.5 秒沒前進就用 `Player.nudge` 輕推，自我測試用同一套處理，卡住時印 `stalled after seek`。原因還沒查到，看門狗不要拿掉。
- 直播檢查用 `LiveProbe`（頻道 `/live` 網頁的 `videoDetails.isLive`），不要改回 yt-dlp：一個頻道一個請求、不用開 python。只查勾選的頻道，每 10 分鐘一次。
