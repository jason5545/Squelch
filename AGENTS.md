# Squelch 協作規則

- 改完一定跑 `make selftest`，全部 PASS 才算完成。它會實際連 YouTube：清單、HLS 與下載備援兩條播放路徑（長度、開播、跳轉、2 倍速）、SponsorBlock、存檔。測試頻道是 @AppleDeveloper，不要換成個人訂閱的頻道。
- 看介面用 `Squelch.app/Contents/MacOS/Squelch --snapshot <png>`，不要用 screencapture（會跳螢幕錄影權限）。離屏截圖抓不到側欄的毛玻璃，側欄是黑的屬正常。
- 解析 YouTube 一律交給 yt-dlp，不自己寫 InnerTube。yt-dlp 壞了先 `brew upgrade yt-dlp`。唯一例外是 `WatchHistory`：從影片頁取得播放紀錄的回報網址，yt-dlp 沒有提供帶真實進度的回報。
- 帶帳號的請求只有訂閱動態、觀看記錄和播放紀錄回報；解析音軌（`YTDLP.resolve`）和搜尋（`YTDLP.search`）不准加 `--cookies`。訂閱動態和觀看記錄都只在使用者打開或按重新整理時抓，不跟著自動更新跑（`refreshAvoidsAccount` 測試會檢查）。播放紀錄回報最多每 5 分鐘一次，加上開始、暫停、跳轉、聽完、換集。
- 自我測試不碰 WebKit（沒有 NSApplication 會當掉），帳號相關只測 cookie 檔和解析；已登入時會多測訂閱動態（只讀，不送播放紀錄）。
- 播放格式的取捨和實測數字寫在 README 的「怎麼播的」，改格式前先讀。
- repo 是公開的。個人的頻道清單只存在本機的 `library.json`，不要寫進程式碼、測試或文件。

## 本機部署

- 這台 Mac 只裝 `/Applications/Squelch.app`，而且只裝公證版：平常用 `scripts/ship.sh`（小版號自動加一、發版、安裝、打 tag），要指定版本才分開跑 `scripts/release.sh <版本>`、`scripts/install.sh <版本>`。版本號以 git tag `v*` 為準，v0.5.1 之前的版本沒有 tag。
- 不要把 `make build` 的 Debug 版複製進 `/Applications`。
- 改版本時兩個腳本都帶同一個版本號，`project.yml` 的 `MARKETING_VERSION` 只是預設值。
- AVPlayer 跳轉後偶爾「狀態是播放中但時間不走」（自我測試約每六次一次）。`Player.checkStall` 偵測到 2.5 秒沒前進就用 `Player.nudge` 輕推，自我測試用同一套處理，卡住時印 `stalled after seek`。原因還沒查到，看門狗不要拿掉。
- 直播檢查用 `LiveProbe`（頻道 `/live` 網頁的 `videoDetails.isLive`），不要改回 yt-dlp：一個頻道一個請求、不用開 python。只查勾選的頻道，每 10 分鐘一次。
