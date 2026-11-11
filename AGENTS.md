# Squelch 協作規則

- 改完一定跑 `make selftest`，全部 PASS 才算完成。它會實際連 YouTube：清單、HLS 與下載備援兩條播放路徑（長度、開播、跳轉、2 倍速）、SponsorBlock、存檔。測試頻道是 @AppleDeveloper，不要換成個人訂閱的頻道。
- 看介面用 `Squelch.app/Contents/MacOS/Squelch --snapshot <png>`，不要用 screencapture（會跳螢幕錄影權限）。離屏截圖抓不到側欄的毛玻璃，側欄是黑的屬正常。
- 解析 YouTube 一律交給 yt-dlp，不自己寫 InnerTube。yt-dlp 壞了先 `brew upgrade yt-dlp`。唯一例外是 `WatchHistory`：從影片頁取得播放紀錄的回報網址，yt-dlp 沒有提供帶真實進度的回報。
- 帶帳號的請求只有訂閱動態和播放紀錄，解析音軌（`YTDLP.resolve`）不准加 `--cookies`。
- 自我測試不碰 WebKit（沒有 NSApplication 會當掉），帳號相關只測 cookie 檔和解析；已登入時會多測訂閱動態（只讀，不送播放紀錄）。
- 播放格式的取捨和實測數字寫在 README 的「怎麼播的」，改格式前先讀。
- repo 是公開的。個人的頻道清單只存在本機的 `library.json`，不要寫進程式碼、測試或文件。

## 本機部署

- 這台 Mac 只裝 `/Applications/Squelch.app`，而且只裝公證版：`scripts/release.sh <版本>` 產出 zip，再 `scripts/install.sh <版本>` 安裝。
- 不要把 `make build` 的 Debug 版複製進 `/Applications`。
- 改版本時兩個腳本都帶同一個版本號，`project.yml` 的 `MARKETING_VERSION` 只是預設值。
