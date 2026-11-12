# Squelch

<img src="branding/preview.png" width="128" alt="Squelch 圖示">

把 YouTube 頻道當 podcast 聽的 macOS App。只抓音軌，不解碼影片，不用登入。

名字取自無線電的靜噪（squelch）：把雜訊切掉，只留人聲。

## 功能

- 訂閱頻道（`@handle`、頻道網址、`UC…` 頻道 ID），每 30 分鐘自動抓新影片
- 用網址訂閱：`open 'squelch://add?channel=@handle'`（`channel=` 也可以放頻道網址或 `UC…` ID）。App 開著就直接加，沒開會先打開，不會把視窗叫到前面；已經訂閱的不會重複加。移除用 `squelch://remove?channel=@handle`。給捷徑、腳本或 AI 工具用
- 「最新」「聽到一半」「待播清單」三個清單，待播清單可以拖拉排序
- 介面是深色的，主色是圖示的琥珀色。每一頁上方有大標題和封面色的漸層（頻道頁取頭像的顏色），清單像曲目表：編號、長度一欄，滑鼠移上去出現「加到待播清單」和「⋯」，正在播的那一列編號換成跳動的長條，點正在播的那一列是暫停／繼續。「最新」上方另有「正在直播」「繼續聽」兩排卡片
- 視窗底部是播放列：播放鍵、倒退 15／快轉 30 秒、下一集、進度條（綠色是 SponsorBlock 會跳過的片段）、倍速、音量。點左邊的封面或最右邊的按鈕開關右側的「正在播放」面板：模糊封面當背景，大封面（暫停時縮小）、一排倍速、音量放大的說明、接下來要播的
- 播放速度 1×–3×（語音用 time-domain 變速，不會變調）
- 音量 0–200%（⌘↑ ⌘↓，喇叭圖示點了靜音）。超過 100% 是放大，拉過去就生效，加柔性限幅不爆音
- 記住每部影片聽到哪裡，下次從那裡接著聽
- SponsorBlock 自動跳過贊助片段（設定裡可再開自我宣傳、訂閱提醒）
- 控制中心的「正在播放」、媒體鍵、耳機按鍵
- 關掉視窗照樣在背景播，選單列有控制
- 搜尋 YouTube（工具列，按 Enter 才查），右鍵可以把結果的頻道加進來
- 觀看記錄：登入時是 YouTube 的觀看記錄（手機上看的也在），沒登入是 Squelch 自己的播放記錄
- 貼影片網址直接播（直播回放、沒訂閱的頻道）
- 正在直播的會標「直播中」排在最上面，可以直接聽。「直播中」清單檢查你勾選的頻道（設定或頻道右鍵），每 10 分鐘自動查一次：打開頻道的 `/live` 網頁看播放器資料的 `isLive`，一個頻道一個請求，不用 yt-dlp、不帶帳號（頻道 RSS 在 2026/11 已經 404）。`/live` 只給頻道主要的那一場，同時開好幾場只會抓到一場
- 桌面迷你模式（⌘⇧M，或播放列的子母畫面按鈕）：浮在其他視窗上面的小播放器，拖背景移動。上排是封面、標題、字幕開關、倍速，下排是倒退／播放／快轉／下一集和進度條；字幕開著時下面多一塊字幕。點封面回到完整視窗，左上角的關閉鈕滑鼠移進來才出現
- 字幕（選用，預設關）：播放列上方顯示翻好的字幕，下面小字是原文。翻成哪種語言預設跟著介面語言（正體中文、简体中文、English、日本語），設定裡可以改。有 YouTube 字幕就用（人工上傳的優先，其次是自動字幕），交給本機的 Codex 翻譯；已經是那種語言的不翻，中文正簡之間只轉字。沒有字幕的影片可以再打開「本機語音辨識」，用 Qwen3-ASR 在這台 Mac 上辨識；直播一定沒有字幕，模型下載過就自動聽寫。見「字幕」
- 介面有正體中文、English、日本語、简体中文，跟著系統語言；其他語言顯示英文
- 登入 YouTube（選用）：多一個「訂閱動態」，播放紀錄和進度會回報給 YouTube，網頁版和手機可以接著看

## 跟現成的比

Squelch 的基本功能，別的工具大多已經有了。只需要免登入訂閱、只聽聲音、跳過業配的話，FreeTube 就夠了。以下是 2026/11/12 查過的：

- [FreeTube](https://github.com/FreeTubeApp/FreeTube)：免帳號訂閱、SponsorBlock、純音訊模式（設定的「預設媒體格式」，README 沒寫）、記住進度都有。用 shaka-player 加 `<video>` 播，純音訊模式是 `manifest.disableVideo`；直播只有 iOS 那份 HLS 有獨立音訊，拿不到就不能只聽聲音。音量最高 100%（`changeVolume` 上限 100，沒有增益節點），字幕可以選 YouTube 自動翻譯的軌。Electron，Windows、Linux 也能用。
- [Yattee](https://github.com/yattee/yattee)：Swift 原生，有 macOS 版，有 SponsorBlock、待播清單、背景播放。以看影片為主；第 2 版還在測試，搭配自己架的 Yattee Server。
- [Kaset](https://github.com/sozercan/kaset)：原生的 YouTube Music 和 YouTube 客戶端，要登入 Google，用 WebView 播影片。Squelch 的登入做法參考它（見「登入」）。
- [Podsync](https://github.com/mxpv/podsync)、[PigeonPod](https://github.com/aizhimou/pigeon-pod)：把頻道轉成 podcast RSS，用一般的 podcast App 聽。要自己架伺服器，先下載成音檔再聽。Pocket Casts 官方不支援 YouTube 頻道。
- 沉浸式翻譯這類瀏覽器擴充功能：在 YouTube 網頁上用 AI 翻字幕。Squelch 不在瀏覽器裡播，用不到。

Squelch 多做的是這三件：

1. 音量放大到 200%（見「音量放大」）。YouTube 講話影片比 Spotify 小聲約 7 dB，瀏覽器的 `<video>` 和 AVPlayer 都只到 100%。
2. 只抓音軌的原生 macOS App，自己解碼 HLS 純音訊分段。FreeTube 直播走的也是 itag 233／234 的純音訊 HLS（它把分段副檔名從 `.ts` 改成 `.aac`），但交給 `<video>` 播。
3. 字幕翻譯和本機聽寫在同一個播放器裡（見「字幕」），直播也能聽寫。

## 下載

[GitHub Releases](https://github.com/jason5545/Squelch/releases/latest) 有 Developer ID 簽章、Apple 公證過的版本，解壓縮後拖進「應用程式」就能開。介紹頁：<https://squelch.hiroki.im/>

## 需求

- macOS 26（Apple Silicon）

不用另外裝任何東西：yt-dlp 和它解 YouTube 需要的 JS 執行環境 deno 都包在 App 裡（見「內建的 yt-dlp」）。

## 建置

```sh
make build      # xcodegen + xcodebuild，產物在 build/xcode/Build/Products/Debug/Squelch.app（第一次會下載 yt-dlp 和 deno）
make run        # 建置後打開
make selftest   # 不開視窗，實際連 YouTube 跑核心流程
scripts/release.sh 0.1.0   # Developer ID 簽章＋公證，產出 build/dist/Squelch-0.1.0.zip
scripts/install.sh 0.1.0   # 裝到 /Applications/Squelch.app
scripts/ship.sh            # 一鍵：小版號加一、發公證版、安裝、打 git tag、發 GitHub Release（T3 的「發版並安裝」按鈕）
```

## 怎麼播的

1. `yt-dlp --flat-playlist -J <頻道>/videos` 抓清單（約 0.6 秒）。
2. 按下播放時 `yt-dlp -f 234/233 -j` 解出 HLS 純音訊的網址（約 2 秒）。
3. Squelch 自己播這個 HLS（`SegmentPlayer`）：抓播放清單和分段、解碼成 PCM、放大，再交給 `AVSampleBufferAudioRenderer`。約 1 秒就緒；先抓好後面 2 分鐘，在這個範圍裡跳轉約 0.5 秒。變速由系統做，跟 AVPlayer 同一個 time-domain 演算法。
4. 直播交給 AVPlayer 播同一個 HLS 網址。
5. 沒有 HLS 的影片，改用 yt-dlp 把 m4a 下載到 `~/Library/Caches/Squelch/audio/`，用 AVFoundation 重新封裝（不轉碼，見下面「分段式 MP4」那條）後交給 AVPlayer 播（16 分鐘的影片約 2 秒）。快取一週沒用就刪。

為什麼 HLS 不直接交給 AVPlayer：AVPlayer 播 HLS 時沒辦法在音訊路徑上加增益，音量最大就是 100%（見「音量放大」）。YouTube 的 HLS 純音訊分段其實很單純（2026/11/11 實測兩個頻道）：

- 播放清單是一般的 `#EXTINF` 加網址，分段不是 MPEG-TS，是「ID3 標籤 + ADTS AAC」，每段約 5 秒、80 KB，系統內建的 AAC 解碼器直接認得，不需要 ffmpeg。
- 分段照順序連續解碼，邊界沒有斷點：6 段 31 秒的音訊跟 ffmpeg 解同一段對照，位移 0、差異 RMS 0.00002。解碼 31 秒花 21 毫秒。
- 分段的起點用 `#EXTINF` 累加，跟分段裡 ID3 的時間戳最多差 22 毫秒。
- 格式不是這樣（哪天 YouTube 改成 fMP4、播放清單沒有結尾）就退回 AVPlayer 播 HLS，那一集的放大改走下面的下載備援。

為什麼不直接串流 m4a 直連網址（2026/11/11 實測）：

- googlevideo 對開放式 Range（`bytes=0-`）限速，6 秒只給約 200 KB；要自己切成有上限的 Range。
- 直連網址解出來後要等幾秒才能用（yt-dlp 的 `available_at`），太早請求回 403。
- 原始的 DASH m4a 是分段式 MP4：AVPlayer 要把整個檔案讀完才開播（45 分鐘的影片 12 秒），而且會把長度算成兩倍（1011 秒變 2023 秒），續播位置和 SponsorBlock 的時間點都會錯。以前靠 yt-dlp 叫 ffmpeg 修正容器；現在 App 不帶 ffmpeg，下載時加 `--fixup never`，再用 `AVAssetExportSession` 的 passthrough 重新封裝成一般的 m4a：同一個 1011 秒的檔案花 0.04 秒，修正後長度 1011.58 秒（ffprobe 1011.62 秒）。
- 有些頻道的直播回放不在 `/streams` 分頁，所以頻道預設不抓直播分頁（右鍵可開），直播回放用「播放影片網址」。

## 音量放大

YouTube 講話影片比 Spotify 小聲：實測兩部 Theo 影片 -20.6、-21.2 LUFS，Spotify 標準是 -14 LUFS，差約 7 dB。

AVPlayer 的音量最大 100%，要更大聲只能在音訊路徑上加增益（`MTAudioProcessingTap`）。但 HLS 串流不經過這條路（實測處理函式被呼叫 0 次）。0.6 以前的做法是拉過 100% 時把整個音軌下載下來、切到本機檔再放大：48 分鐘的影片要等 13 秒，中間還要換一次播放來源。現在改成自己解碼（見「怎麼播的」），PCM 在手上，直接乘：

- 100% 以下用 renderer 的音量，立刻生效。超過 100% 的部分在送進 renderer 之前乘上去。
- 送進去的音訊改不了，所以改增益時把排隊中、還沒播的換掉（`flush(fromSourceTime:)`），播放不中斷。renderer 內部已經取走約 1～1.5 秒（實測：替換點排在 1 秒後會失敗、1.5 秒後成功，1～3 倍速都一樣），所以往上調大約 1.6 秒（影片時間，2 倍速就是 0.8 秒）後才聽得到；往下調時，舊增益的音訊還在播的這段時間先把 renderer 的音量按比例壓低，立刻生效。
- 增益之後加柔性限幅：0.85 以下原樣，以上用 tanh 壓到不超過 1.0。原始峰值已經到 -2～-3 dBFS，不限幅一放大就爆音。實測一部 Theo 影片放大到 200% 時，只有 0.015% 的取樣會碰到限幅區。
- YouTube 自己的「穩定音量」音軌（itag `140-drc` 這類）幫不上忙：HLS 沒有這種音軌，只有 DASH 有，而且實測只大 1.9 dB（-18.7 對 -20.6 LUFS）。
- 快取裡有的影片、沒有 HLS 的影片播的是本機檔，用 `MTAudioProcessingTap` 放大，也是立刻生效。
- 直播由 AVPlayer 播，最大就是 100%。
- 備援：HLS 的格式 `SegmentPlayer` 解不了、退回 AVPlayer 的時候，照舊的做法背景下載音軌、從同一個位置切到本機檔。

## 內建的 yt-dlp

- `scripts/vendor-tools.sh` 下載官方發行檔並核對 SHA-256：yt-dlp 的 onedir 版 `yt-dlp_macos.zip`（PyInstaller 打包，內含 Python 和解 YouTube 用的 yt-dlp-ejs），以及 deno。版本寫在腳本裡。
- 只留 arm64，yt-dlp 約 44 MB、deno 約 77 MB；App 從約 5 MB 變成 126 MB，發版的 zip 從 2.3 MB 變成約 64 MB。
- 建置時 `scripts/embed-tools.sh` 把 deno 放 `Contents/Helpers`、yt-dlp 整包放 `Contents/Resources/yt-dlp`（裡面混著 `cacert.pem`、`.js` 這類資料檔，放在 Helpers 會被 codesign 當成沒簽章的程式），每個 Mach-O 用 hardened runtime 簽章。發版時 `xcodebuild -exportArchive` 會把裡面 106 個 Mach-O 全部重簽成 Developer ID，再一起公證。
- yt-dlp 從 PATH 找 JS 執行環境，Squelch 給它的 PATH 只有 `Contents/Helpers` 和系統目錄，有沒有裝 Homebrew 結果都一樣。
- 不帶 ffmpeg：只有下載備援用得到，改用 AVFoundation 重新封裝（見「怎麼播的」）。
- 自動更新：YouTube 一改版，舊的 yt-dlp 就抓不到。Squelch 每天到 GitHub 查一次 yt-dlp 的最新版（yt-dlp 失敗時最多每小時查一次），比使用中的新就下載 `yt-dlp_macos.zip`、核對 `SHA2-256SUMS`、實際跑一次 `--version`，都對了才放到 `~/Library/Application Support/Squelch/yt-dlp/`。App 本體不動，簽章不會壞；內建的和下載的兩份，用版本較新的那份。設定裡可以手動檢查，也可以指定自己的 yt-dlp。

## 字幕

播放列右邊的對話框按鈕開關，設定裡也有。預設關。

1. 挑字幕軌：開播時 `yt-dlp -j` 本來就會列出字幕（`subtitles`、`automatic_captions`），不用多一次請求，先整份存起來，要顯示時再依目標語言挑。順序是目標語言的人工字幕（直接顯示）→ 原文的人工字幕 → 原文的自動字幕（`<語言>-orig`）。YouTube 自動翻譯的軌（`automatic_captions` 裡的 `zh-Hant`、`ja` 那些）不用。本機快取檔播放時沒有這份資料，另外跑一次 `yt-dlp -j --skip-download`。
   - 目標語言：設定的「翻成」，預設跟著介面語言（`Bundle.main.preferredLocalizations`，Squelch 的四種之一）。原文已經是目標語言就直接顯示；中文對中文（例如簡體字幕、目標是正體）只用系統的 `Hans-Hant` 轉字，不送翻譯；其他交給 Codex。換語言會重新來過，各語言的快取分開存。
2. 抓字幕：json3 格式，整份一次抓下來（網址約 6 小時過期）。自動字幕是逐字滾動的，每個字有自己的時間，在停頓超過 0.8 秒、句尾、超過 7 秒或太長的地方斷成一句。五小時的直播回放約 4,200 句，0.8 秒抓完（2026/11/12 實測）。
3. 翻譯：本機的 `codex app-server --stdio`（JSON-RPC），用你自己的 Codex 登入，不需要 API key。模型固定 GPT-6 Luna、推理 xhigh、快速模式（`serviceTier: priority`，Codex 的回應會確認）。每一批開一個 ephemeral thread，前面 4 句和後面 2 句當參考一起送，回傳用 JSON schema 限定格式。thread 的工作目錄是空的暫存資料夾、沙盒唯讀、不准連網。分兩條通道：播放位置往後 20 秒內還沒翻的句子（剛打開、剛跳轉、直播）走快速通道，推理等級用 low、一次最多 6 句，約 5～6 秒出譯文，先標成草稿；20 秒以後的走 xhigh，一批 6～16 句，同時最多兩批，只翻播放位置往後 5 分鐘內的。xhigh 翻到前面、有空檔時，還沒播到的草稿再用 xhigh 重翻蓋掉。`codex app-server` 冷啟動只要 0.1 秒、`thread/start` 0.1 秒，慢的是每批的推理（xhigh 3 句 9.3 秒、low 3 句 5.2 秒，2026/11/12 實測），所以不用預先暖機。實測（2026/11/12）：開播後約 9 秒出現第一句中文（含 3 秒解析網址；改成兩條通道之前是 12～15 秒）；跳到 10:00 後約 6 秒有中文（之前 14～21 秒）；播到 0:35 時已經翻到 2:10。還沒翻好的那幾句先用灰字顯示原文。
4. 中文對中文：不送翻譯，用系統的 `Hans-Hant` 轉字（只轉字、不轉用詞，「軟件」不會變「軟體」）。
5. 快取：`~/Library/Caches/Squelch/subtitles/<影片 ID>.<目標語言>.json`，翻好的句子都在裡面，重聽不用再翻。
   - 用不到就釋放：關掉字幕時 codex app-server 和語音模型立刻停掉。字幕開著時，這一集用不到語音辨識（有字幕）就卸載模型；暫停超過 5 分鐘也卸載，再播時自動載回來（約 3 秒）。10 分鐘沒有翻譯就停掉 codex app-server，下一批翻譯時自動再開。實測（2026/11/12）：模型載著時 App 佔約 2.6 GB，其中顯示卡記憶體 2.3 GB；codex app-server 約 170～270 MB。
6. 直播：yt-dlp 給的直播資料沒有字幕（2026/11/12 查 Sky News 的直播，`subtitles` 和 `automatic_captions` 都是空的），一律用本機語音辨識。模型已經在這台 Mac 上就自動開始，「本機語音辨識」開關關著也一樣；不在的話字幕列有一顆按鈕，按了才下載。見下面「直播的時間軸」。

### 本機語音辨識（沒有字幕時）

設定裡另外打開，預設關。打開才準備模型：[mlx-community/Qwen3-ASR-1.7B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)（約 2.5 GB，版本釘死在 `a8379a2`，下載後核對檔案大小），放在 `~/Library/Application Support/Squelch/Models/`。同一台 Mac 的 Voco 已經下載過同一個模型的話，直接複製過來（APFS 上是 clone，不多佔空間）。

- 不跟播放共用音訊：自己照同一份 HLS 播放清單抓分段（每段約 5 秒、80 KB）、解碼、轉成 16 kHz 單聲道；下載備援的本機檔用 `AVAssetReader`。所以可以跑在播放前面（最多 3 分鐘），也不受倍速影響。
- 切段跟 AISubtitle 一樣：優先在安靜的地方切，最長 5.6 秒，要硬切時在最後 1.5 秒裡找最安靜的位置。
- 辨識結果照樣交給 Codex 翻；偵測到的語言就是目標語言就直接顯示，中文對中文只轉字。
- 直播的時間軸：直播交給 AVPlayer 播，字幕這邊另外照同一個 HLS 網址抓。YouTube 直播的播放清單是 1 小時的滑動窗口，開頭有一個 `EXT-X-PROGRAM-DATE-TIME`，之後每段 5 秒（分段一樣是 ID3 + ADTS）。每段的實際時間 = 開頭的時間 + 前面各段的長度；播放端用 AVPlayer 的 `currentDate()`，兩邊都是實際時間（UNIX 秒），所以對得上。辨識從正在播的地方開始，追到最新的那段就每 2 秒重抓播放清單。AVPlayer 播直播落後最新約 20 秒，這段差距就是辨識和翻譯的提前量。只留最近 2 小時的字幕。實測（2026/11/12，Sky News）：開始播後 3 秒出現第一句原文、15 秒出現中文；接下來 60 秒裡 59 秒畫面上有翻好的字幕，最新的一句比播放位置早 10 秒。
- 實測（2026/11/12，這台開發用的 Mac）：載入模型 3.2 秒，40 秒的聲音 5.5 秒辨識完。
- 語音辨識的程式碼在 `Packages/SquelchASR`（MLX，獨立成 Swift 5 模式的本機套件），改寫自 [soniqo/speech-swift](https://github.com/soniqo/speech-swift)（Apache-2.0，授權見該資料夾的 `NOTICE`）。App 因此變大，Debug 建置從約 126 MB 變成 177 MB（多的主要是 MLX）。

檢查字幕（會花 Codex 額度，所以不在自我測試裡）：

```sh
Squelch.app/Contents/MacOS/Squelch --subtitle-check <影片 ID>              # 挑軌、抓字幕、翻一批（加 --target en／ja／zh-Hans／zh-Hant 指定目標語言）
Squelch.app/Contents/MacOS/Squelch --subtitle-check <影片 ID> --speech 40  # 改用本機語音辨識前 40 秒
Squelch.app/Contents/MacOS/Squelch --subtitle-flow <影片 ID>               # 不出聲地播，跑整個流程：翻譯排程、跳轉、快取（直播的 ID 就測直播的語音辨識）
```

## 登入

做法參考 [Kaset](https://github.com/sozercan/kaset)：App 內開 Google 登入頁，cookie 存在 Squelch 自己的 WebKit 資料區，跟瀏覽器分開。登入頁會藏掉 passkey（內嵌網頁的 passkey 一定失敗，見 Kaset ADR-0033），Google 會改走密碼。

帳號只用在三件事：

- 訂閱動態：`yt-dlp --cookies` 抓 `youtube.com/feed/subscriptions`，只在打開「訂閱動態」或按重新整理時抓，距上次超過 10 分鐘才抓。yt-dlp 跑完會把輪換過的 cookie 寫回檔案，Squelch 再讀回 WebKit。
  （不改成匿名一個一個抓頻道：訂閱幾百個頻道時，每輪幾百個請求，會超過 YouTube 對不登入的限流，連音軌和搜尋都會卡住。頻道 RSS 在 2026/11 已經回 404。）
- 觀看記錄：`yt-dlp --cookies` 抓 `youtube.com/feed/history`，只在打開清單或按重新整理時抓。
- 播放紀錄：從登入狀態的影片頁取得 `playbackTracking` 的兩個回報網址，開始播時送 `videostatsPlaybackUrl`（進觀看記錄）；暫停、跳轉、聽完、換集時，以及播放中每 5 分鐘，送 `videostatsWatchtimeUrl`（帶真正的位置）。45 分鐘的影片大約 10 次回報。參數照 yt-dlp 的 `_mark_watched`，但不會一律標成看完。

每 30 分鐘的自動更新完全不碰帳號（自我測試會檢查）；平常使用時帶帳號的請求只有播放紀錄回報，每部影片約 10 次，其他都是你打開或按了才抓。解析音軌和搜尋不帶帳號。yt-dlp 官方提醒：帳號搭配 yt-dlp 有被封鎖（暫時或永久）的風險，所以帶帳號的請求越少越好。

## 資料

- `~/Library/Application Support/Squelch/library.json`：頻道、影片、進度、待播清單。第一次打開沒有任何頻道，從右上角的 + 加入。
- `~/Library/Application Support/Squelch/cookies.txt`：登入後給 yt-dlp 的 cookie（權限 0600），登出就刪。
- `~/Library/Application Support/Squelch/yt-dlp/`：自動更新下載的 yt-dlp，刪掉就回到內建的那份。
- `~/Library/Application Support/Squelch/Models/`：本機語音辨識的模型（約 2.5 GB），設定裡可以刪。
- `~/Library/Caches/Squelch/subtitles/`：抓下來和翻好的字幕。
