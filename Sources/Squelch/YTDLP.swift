import Foundation
import Synchronization

nonisolated enum YTDLPError: LocalizedError {
    case notFound
    case failed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notFound: "找不到 yt-dlp。請先 `brew install yt-dlp`，或在設定裡指定路徑。"
        case .failed(let message): message
        case .badOutput: "yt-dlp 的輸出看不懂。"
        }
    }
}

/// 呼叫 yt-dlp 的地方都在這裡。Squelch 不自己解析 YouTube。
nonisolated enum YTDLP {
    static let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
    static let customPathKey = "ytdlpPath"

    static func binaryPath() -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: customPathKey), !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
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
                var env = ProcessInfo.processInfo.environment
                // 從 Finder 開的 App 拿不到 shell 的 PATH；yt-dlp 需要找到 deno 和 ffmpeg。
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + (env["PATH"].map { ":" + $0 } ?? "")
                process.environment = env
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
                    let message = lines.last(where: { $0.contains("ERROR") }) ?? lines.last ?? "yt-dlp 結束代碼 \(process.terminationStatus)"
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
    /// 備援：下載 m4a 到快取。yt-dlp 會用 ffmpeg 修正容器；
    /// YouTube 原始的 DASH m4a 會讓 AVFoundation 把長度算成兩倍（2026/11/11 實測 1011 秒變 2023 秒）。
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
            "-f", downloadFormat, "-J", "--no-simulate", "--no-playlist", "--no-part",
            "--socket-timeout", "15", "-o", dir.path + "/%(id)s.%(ext)s",
            "https://www.youtube.com/watch?v=\(videoID)",
        ])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (obj["requested_downloads"] as? [[String: Any]])?.first?["filepath"] as? String else {
            throw YTDLPError.badOutput
        }
        var stream = try metadata(obj)
        stream.url = URL(fileURLWithPath: path)
        stream.isLocal = true
        stream.expires = .distantFuture
        return stream
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
                              isLive: (obj["is_live"] as? Bool) ?? false)
    }

    static func version() async -> String? {
        guard let data = try? await run(["--version"]) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated final class DataBox: @unchecked Sendable {
    var data = Data()
}
