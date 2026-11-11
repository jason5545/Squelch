# Squelch

<img src="branding/preview.png" width="128" alt="Squelch 圖示">

把 YouTube 頻道當 podcast 聽的 macOS App。只抓音軌，不解碼影片，不用登入。

名字取自無線電的靜噪（squelch）：把雜訊切掉，只留人聲。

## 功能

- 訂閱頻道（`@handle`、頻道網址、`UC…` 頻道 ID），每 30 分鐘自動抓新影片
- 「最新」「聽到一半」「待播清單」三個清單，待播清單可以拖拉排序
- 播放速度 1×–3×（語音用 time-domain 變速，不會變調）
- 記住每部影片聽到哪裡，下次從那裡接著聽
- SponsorBlock 自動跳過贊助片段（設定裡可再開自我宣傳、訂閱提醒）
- 控制中心的「正在播放」、媒體鍵、耳機按鍵
- 關掉視窗照樣在背景播，選單列有控制
- 貼影片網址直接播（直播回放、沒訂閱的頻道）
- 正在直播的會標「直播中」排在最上面，可以直接聽
- 登入 YouTube（選用）：多一個「訂閱動態」，播放紀錄和進度會回報給 YouTube，網頁版和手機可以接著看

## 需求

- macOS 26
- `brew install yt-dlp deno`（yt-dlp 解 YouTube 需要 JS 執行環境）

## 建置

```sh
make build      # xcodegen + xcodebuild，產物在 build/xcode/Build/Products/Debug/Squelch.app
make run        # 建置後打開
make selftest   # 不開視窗，實際連 YouTube 跑核心流程
scripts/release.sh 0.1.0   # Developer ID 簽章＋公證，產出 build/dist/Squelch-0.1.0.zip
scripts/install.sh 0.1.0   # 裝到 /Applications/Squelch.app
```

## 怎麼播的

1. `yt-dlp --flat-playlist -J <頻道>/videos` 抓清單（約 0.6 秒）。
2. 按下播放時 `yt-dlp -f 234/233 -j` 解出 HLS 純音訊的網址（約 2 秒），直接交給 AVPlayer：約 1 秒就緒，跳轉不用等。
3. 沒有 HLS 的影片，改用 yt-dlp 把 m4a 下載到 `~/Library/Caches/Squelch/audio/` 再播（16 分鐘的影片約 2 秒）。快取一週沒用就刪。

為什麼不直接串流 m4a 直連網址（2026/11/11 實測）：

- googlevideo 對開放式 Range（`bytes=0-`）限速，6 秒只給約 200 KB；要自己切成有上限的 Range。
- 直連網址解出來後要等幾秒才能用（yt-dlp 的 `available_at`），太早請求回 403。
- 原始的 DASH m4a 是分段式 MP4：AVPlayer 要把整個檔案讀完才開播（45 分鐘的影片 12 秒），而且會把長度算成兩倍（1011 秒變 2023 秒），續播位置和 SponsorBlock 的時間點都會錯。yt-dlp 下載時會用 ffmpeg 修正容器，修正後就正常。
- 有些頻道的直播回放不在 `/streams` 分頁，所以頻道預設不抓直播分頁（右鍵可開），直播回放用「播放影片網址」。

## 登入

做法參考 [Kaset](https://github.com/sozercan/kaset)：App 內開 Google 登入頁，cookie 存在 Squelch 自己的 WebKit 資料區，跟瀏覽器分開。登入頁會藏掉 passkey（內嵌網頁的 passkey 一定失敗，見 Kaset ADR-0033），Google 會改走密碼。

帳號只用在兩件事：

- 訂閱動態：`yt-dlp --cookies` 抓 `youtube.com/feed/subscriptions`，每 30 分鐘一次。yt-dlp 跑完會把輪換過的 cookie 寫回檔案，Squelch 再讀回 WebKit。
- 播放紀錄：從登入狀態的影片頁取得 `playbackTracking` 的兩個回報網址，開始播時送 `videostatsPlaybackUrl`（進觀看記錄），播放中每 20 秒和暫停、跳轉時送 `videostatsWatchtimeUrl`（帶真正的位置）。參數照 yt-dlp 的 `_mark_watched`，但不會一律標成看完。

解析音軌不帶帳號。yt-dlp 官方提醒：帳號搭配 yt-dlp 有被封鎖（暫時或永久）的風險，所以帶帳號的請求越少越好。

## 資料

- `~/Library/Application Support/Squelch/library.json`：頻道、影片、進度、待播清單。第一次打開沒有任何頻道，從右上角的 + 加入。
- `~/Library/Application Support/Squelch/cookies.txt`：登入後給 yt-dlp 的 cookie（權限 0600），登出就刪。
