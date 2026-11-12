import AVFoundation
import Foundation
import Synchronization

nonisolated enum YTDLPError: LocalizedError {
    case notFound
    case failed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "找不到 yt-dlp。App 裡內建的那份不見了，請重新下載 Squelch，或在設定裡指定路徑。")
        case .failed(let message): message
        case .badOutput: String(localized: "yt-dlp 的輸出看不懂。")
        }
    }
}

/// 呼叫 yt-dlp 的地方都在這裡。Squelch 不自己解析 YouTube。
nonisolated enum YTDLP {
    static let homebrewCandidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    static let customPathKey = "ytdlpPath"
    /// 自我測試關掉，證明不靠 Homebrew 也能跑。
    static let allowHomebrew = Atomic<Bool>(true)

    enum Source: Sendable { case custom, updated, bundled, homebrew }

    struct Binary: Sendable {
        var path: String
        var source: Source
        /// 內建和自動更新的那份旁邊有 VERSION 檔；自訂和 Homebrew 的要跑 `--version` 才知道。
        var version: String?
    }

    /// App 內建的 yt-dlp（scripts/vendor-tools.sh 放進 Contents/Resources/yt-dlp）。
    static var bundledDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("yt-dlp", isDirectory: true) }
    /// 內建的 deno 在 Contents/Helpers；yt-dlp 從 PATH 找 JS 執行環境。
    static var helpersDirectory: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }

    /// 順序：自訂路徑 → 內建和自動更新的兩份裡版本較新的 → Homebrew（只在內建的不見時才會用到）。
    static func binary() -> Binary? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: customPathKey), !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? Binary(path: custom, source: .custom) : nil
        }
        let bundled = bundledDirectory.flatMap { installed(in: $0, source: .bundled) }
        let updated = installed(in: YTDLPUpdate.directory, source: .updated)
        switch (bundled, updated) {
        case let (b?, u?): return YTDLPUpdate.isNewer(u.version ?? "", than: b.version ?? "") ? u : b
        case let (b?, nil): return b
        case let (nil, u?): return u
        case (nil, nil): break
        }
        guard allowHomebrew.load(ordering: .relaxed) else { return nil }
        return homebrewCandidates.first { fm.isExecutableFile(atPath: $0) }.map { Binary(path: $0, source: .homebrew) }
    }

    static func binaryPath() -> String? { binary()?.path }

    /// 官方 onedir 版：`yt-dlp_macos` 加 `_internal/`，旁邊的 VERSION 是我們寫的。
    static func installed(in directory: URL, source: Source) -> Binary? {
        let exe = directory.appendingPathComponent("yt-dlp_macos").path
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let version = (try? String(contentsOf: directory.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Binary(path: exe, source: source, version: version)
    }

    /// yt-dlp 從 PATH 找 JS 執行環境：只放內建的 deno，不吃 shell 的 PATH，Homebrew 有沒有裝都一樣。
    /// 不需要 ffmpeg：下載備援用 --fixup never，容器由 AVFoundation 重新封裝（見 downloadOnce）。
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = helpersDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// 執行 yt-dlp 並回傳 stdout。stdout 和 stderr 同時讀，避免輸出太大把管線塞住。
    /// 帶帳號的 yt-dlp 呼叫次數。自我測試用來確認自動更新不碰帳號。
    static let accountCalls = Atomic<Int>(0)

    static func run(_ arguments: [String], cookies: URL? = nil) async throws -> Data {
        if cookies != nil { accountCalls.add(1, ordering: .relaxed) }
        let arguments = cookies.map { ["--cookies", $0.path] + arguments } ?? arguments
        guard let path = binaryPath() else { throw YTDLPError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment()
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let text = String(decoding: errBox.data, as: UTF8.self)
                    let lines = text.split(separator: "\n").map(String.init)
                    let message = lines.last(where: { $0.contains("ERROR") }) ?? lines.last ?? String(localized: "yt-dlp 結束代碼 \(process.terminationStatus)")
                    // YouTube 改版時舊的 yt-dlp 會一直失敗；不等每天的例行檢查，最多每小時查一次新版。
                    YTDLPUpdate.checkSoon()
                    continuation.resume(throwing: YTDLPError.failed(message))
                }
            }
        }
    }

    // MARK: 頻道清單

    static func feed(channelID: String, includeStreams: Bool, limit: Int = 30) async throws -> ChannelFeed {
        async let videos = tab(channelID: channelID, path: "videos", limit: limit, isStream: false)
        if includeStreams {
            async let streams = try? tab(channelID: channelID, path: "streams", limit: 10, isStream: true)
            var feed = try await videos
            if let s = await streams { feed.episodes += s.episodes }
            return feed
        }
        return try await videos
    }

    static func tab(channelID: String, path: String, limit: Int, isStream: Bool) async throws -> ChannelFeed {
        let data = try await run([
            "--flat-playlist", "-J", "-I", "1:\(limit)",
            "--extractor-args", "youtubetab:approximate_date",
            "--socket-timeout", "15",
            "\(channelID)/\(path)",
        ])
        return try parseTab(data, channelID: channelID, isStream: isStream)
    }

    /// `mixed`：訂閱動態、搜尋、觀看記錄這種混了很多頻道的清單，頻道資訊要從每一筆拿。
    static func parseTab(_ data: Data, channelID: String, isStream: Bool, mixed: Bool = false) throws -> ChannelFeed {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YTDLPError.badOutput }
        let title = (obj["channel"] as? String) ?? (obj["uploader"] as? String) ?? channelID
        let thumbs = obj["thumbnails"] as? [[String: Any]] ?? []
        let avatarString = thumbs.first(where: { ($0["id"] as? String) == "avatar_uncropped" })?["url"] as? String
            ?? thumbs.first(where: { ($0["width"] as? Int) == ($0["height"] as? Int) && $0["width"] != nil })?["url"] as? String
        var episodes: [Episode] = []
        for entry in obj["entries"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, let name = entry["title"] as? String else { continue }
            let live = entry["live_status"] as? String
            if live == "is_upcoming" { continue }
            let isLive = live == "is_live"
            let duration = (entry["duration"] as? NSNumber)?.doubleValue
            if isStream && duration == nil && !isLive { continue }
            // 估計時間只到「幾天前」，同一天的會撞在一起；減掉在清單裡的位置秒數，保留頻道頁的先後順序。
            let position = Double(episodes.count)
            let published = (entry["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue - position) }
            var epChannelID = channelID, epChannelTitle = title
            if mixed {
                epChannelID = ""   // 少數項目（例如首播）yt-dlp 不給頻道 ID，只有名稱。
                if let handle = entry["uploader_id"] as? String, handle.hasPrefix("@") {
                    epChannelID = "https://www.youtube.com/\(handle)"
                } else if let cid = entry["channel_id"] as? String {
                    epChannelID = "https://www.youtube.com/channel/\(cid)"
                }
                epChannelTitle = (entry["channel"] as? String) ?? (entry["uploader"] as? String) ?? ""
            }
            episodes.append(Episode(id: id, title: name, channelID: epChannelID, channelTitle: epChannelTitle,
                                    duration: duration, published: isLive ? Date() : published, isStream: isStream || isLive,
                                    isLive: isLive ? true : nil))
        }
        return ChannelFeed(title: title, avatar: avatarString.flatMap(URL.init(string:)), episodes: episodes)
    }

    // MARK: 訂閱動態（要登入）

    static let subscriptionsURL = "https://www.youtube.com/feed/subscriptions"

    static func subscriptions(cookies: URL, limit: Int = 60) async throws -> [Episode] {
        let data = try await run([
            "--flat-playlist", "-J", "-I", "1:\(limit)",
            "--extractor-args", "youtubetab:approximate_date",
            "--socket-timeout", "15", subscriptionsURL,
        ], cookies: cookies)
        return try parseTab(data, channelID: subscriptionsURL, isStream: false, mixed: true).episodes
    }

    // MARK: 搜尋（不帶帳號）、觀看記錄（要登入）

    static func search(_ query: String, limit: Int = 30) async throws -> [Episode] {
        let data = try await run(["--flat-playlist", "-J", "--socket-timeout", "15", "ytsearch\(limit):\(query)"])
        return try parseTab(data, channelID: "", isStream: false, mixed: true).episodes
    }

    static let historyURL = "https://www.youtube.com/feed/history"

    static func history(cookies: URL, limit: Int = 60) async throws -> [Episode] {
        let data = try await run(["--flat-playlist", "-J", "-I", "1:\(limit)", "--socket-timeout", "15", historyURL],
                                 cookies: cookies)
        return try parseTab(data, channelID: historyURL, isStream: false, mixed: true).episodes
    }

    // MARK: 音軌

    /// HLS 純音訊（234 高、233 低）：AVPlayer 原生支援，1 秒就緒、跳轉不用等。
    static let hlsFormat = "234/233"
    /// 備援：下載 m4a 到快取。YouTube 原始的 DASH m4a 會讓 AVFoundation 把長度算成兩倍
    /// （2026/11/11 實測 1011 秒變 2023 秒），以前靠 yt-dlp 叫 ffmpeg 修正容器；
    /// 現在 App 不帶 ffmpeg，改用 AVAssetExportSession passthrough 重新封裝（同一個檔案 0.04 秒，長度 1011.58 秒）。
    static let downloadFormat = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch/audio", isDirectory: true)
    }

    static func resolve(videoID: String) async throws -> ResolvedStream {
        do {
            let data = try await run([
                "-f", hlsFormat, "-j", "--no-playlist", "--socket-timeout", "15",
                "https://www.youtube.com/watch?v=\(videoID)",
            ])
            return try parseResolved(data)
        } catch YTDLPError.failed(let message) where message.contains("format is not available") {
            return try await download(videoID: videoID)
        }
    }

    /// YouTube 偶爾對下載回 403，yt-dlp 不會自己重試（2026/11/11 自我測試遇過，重跑就好），所以重試一次。
    static func download(videoID: String) async throws -> ResolvedStream {
        do {
            return try await downloadOnce(videoID: videoID)
        } catch YTDLPError.failed(let message) where message.contains("403") {
            try await Task.sleep(for: .seconds(2))
            return try await downloadOnce(videoID: videoID)
        }
    }

    private static func downloadOnce(videoID: String) async throws -> ResolvedStream {
        let dir = cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try await run([
            "-f", downloadFormat, "-J", "--no-simulate", "--no-playlist", "--no-part", "--fixup", "never",
            "--socket-timeout", "15", "-o", dir.path + "/%(id)s.raw.%(ext)s",
            "https://www.youtube.com/watch?v=\(videoID)",
        ])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (obj["requested_downloads"] as? [[String: Any]])?.first?["filepath"] as? String else {
            throw YTDLPError.badOutput
        }
        let raw = URL(fileURLWithPath: path)
        let file = dir.appendingPathComponent("\(videoID).m4a")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await remux(raw, to: file)
        var stream = try metadata(obj)
        stream.url = file
        stream.isLocal = true
        stream.expires = .distantFuture
        return stream
    }

    /// 不轉碼，只把 DASH 分段式 MP4 重新封裝成一般的 m4a，AVFoundation 才算得出正確長度。
    static func remux(_ source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw YTDLPError.failed(String(localized: "無法重新封裝下載的音軌。"))
        }
        try await export.export(to: destination, as: .m4a)
    }

    /// 快取裡已經有的音軌（之前下載過）。有的話直接播本機檔：開播更快，也能放大音量。
    static func cachedStream(for ep: Episode) -> ResolvedStream? {
        let file = cacheDirectory.appendingPathComponent("\(ep.id).m4a")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return ResolvedStream(url: file, isLocal: true, headers: [:], duration: ep.duration, title: ep.title,
                              channelTitle: ep.channelTitle, channelID: ep.channelID, expires: .distantFuture)
    }

    /// 刪掉一週沒碰的快取檔。
    static func pruneCache(olderThan age: TimeInterval = 7 * 86400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentAccessDateKey]) else { return }
        for file in files {
            let used = (try? file.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            if Date().timeIntervalSince(used) > age { try? fm.removeItem(at: file) }
        }
    }

    static func parseResolved(_ data: Data) throws -> ResolvedStream {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YTDLPError.badOutput }
        return try metadata(obj)
    }

    private static func metadata(_ obj: [String: Any]) throws -> ResolvedStream {
        guard let urlString = obj["url"] as? String ?? (obj["requested_downloads"] as? [[String: Any]])?.first?["url"] as? String,
              let url = URL(string: urlString) else { throw YTDLPError.badOutput }
        // HLS 網址是 `/expire/…/`，直連網址是 `?expire=…`。
        var expires = Date().addingTimeInterval(5 * 3600)
        if let match = urlString.firstMatch(of: /expire[=\/](\d{9,})/), let t = Double(match.1) {
            expires = Date(timeIntervalSince1970: t)
        }
        var channelID: String?
        if let handle = obj["uploader_id"] as? String, handle.hasPrefix("@") {
            channelID = "https://www.youtube.com/\(handle)"
        } else if let cid = obj["channel_id"] as? String {
            channelID = "https://www.youtube.com/channel/\(cid)"
        }
        return ResolvedStream(url: url, isLocal: false, headers: obj["http_headers"] as? [String: String] ?? [:],
                              duration: (obj["duration"] as? NSNumber)?.doubleValue,
                              title: obj["title"] as? String ?? "",
                              channelTitle: obj["channel"] as? String ?? obj["uploader"] as? String ?? "",
                              channelID: channelID, expires: expires,
                              isLive: (obj["is_live"] as? Bool) ?? false,
                              captions: Captions.sources(obj))
    }

    /// 只查字幕：本機快取檔播放時用。不帶帳號，跟 `resolve` 一樣。
    static func captions(videoID: String) async throws -> CaptionSources? {
        let data = try await run([
            "-j", "--skip-download", "--no-playlist", "--ignore-no-formats-error", "--socket-timeout", "15",
            "https://www.youtube.com/watch?v=\(videoID)",
        ])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YTDLPError.badOutput }
        return Captions.sources(obj)
    }

    static func version() async -> String? {
        guard let data = try? await run(["--version"]) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated final class DataBox: @unchecked Sendable {
    var data = Data()
}
