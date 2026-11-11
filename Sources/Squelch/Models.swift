import Foundation

/// 訂閱的 YouTube 頻道。`id` 是正規化後的頻道網址，例如 `https://www.youtube.com/@AppleDeveloper`。
nonisolated struct Channel: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var avatar: URL?
    var includeStreams: Bool = false
    /// 按重新整理時要不要檢查這個頻道有沒有在直播。舊資料沒有這個欄位，所以是 Optional。
    var watchLive: Bool?
}

/// 一部影片，Squelch 只播它的音軌。
nonisolated struct Episode: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var channelID: String
    var channelTitle: String
    var duration: Double?
    /// yt-dlp 從「2 天前」換算的大約時間，只拿來排序。
    var published: Date?
    var isStream: Bool = false
    /// 正在直播。舊的 library.json 沒有這個欄位，所以是 Optional。
    var isLive: Bool?

    var liveNow: Bool { isLive == true }
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
}

nonisolated struct ChannelFeed: Sendable {
    var title: String
    var avatar: URL?
    var episodes: [Episode]
}

/// 要交給 AVPlayer 的音軌：HLS 網址（會過期，通常 6 小時），或備援時下載到快取的本機檔。
nonisolated struct ResolvedStream: Sendable {
    var url: URL
    var isLocal: Bool
    var headers: [String: String]
    var duration: Double?
    var title: String
    var channelTitle: String
    var channelID: String?
    var expires: Date
    var isLive = false

    var isFresh: Bool {
        isLocal ? FileManager.default.fileExists(atPath: url.path) : expires.timeIntervalSinceNow > 15 * 60
    }
}

nonisolated enum SidebarItem: Hashable, Sendable {
    case latest
    case live
    case search
    case history
    case subscriptions
    case inProgress
    case queue
    case channel(String)
}

nonisolated enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func rate(_ r: Float) -> String {
        let text = String(format: "%.2f", r)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return text + "×"
    }
}

nonisolated enum ChannelInput {
    /// 把使用者貼的東西轉成頻道網址：`@handle`、`handle`、`UC…` 頻道 ID、或任何頻道頁面網址。
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("youtube.com/") || s.hasPrefix("http") {
            if !s.hasPrefix("http") { s = "https://" + s }
            guard let c = URLComponents(string: s), let host = c.host, host.hasSuffix("youtube.com") else { return nil }
            let parts = c.path.split(separator: "/").map(String.init)
            guard let first = parts.first else { return nil }
            if first.hasPrefix("@") { return "https://www.youtube.com/\(first)" }
            if ["channel", "c", "user"].contains(first), parts.count >= 2 {
                return "https://www.youtube.com/\(first)/\(parts[1])"
            }
            return nil
        }
        if s.hasPrefix("UC"), s.count == 24, !s.contains(" ") { return "https://www.youtube.com/channel/\(s)" }
        if !s.hasPrefix("@") { s = "@" + s }
        guard !s.contains(" "), !s.contains("/"), s.count > 1 else { return nil }
        return "https://www.youtube.com/\(s)"
    }

    enum URLCommand: Equatable {
        case add(String)
        case remove(String)
    }

    /// 解析 `squelch://add?channel=@handle`、`squelch://remove?channel=@handle`，頻道原樣交給 `normalize`。
    /// 也接受 `url=`、`subscribe`／`unsubscribe`、`squelch://add/@handle`。看不懂就回傳 nil。
    static func command(from url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "squelch", let host = url.host?.lowercased(),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let fromQuery = c.queryItems?.first { ["channel", "url"].contains($0.name) }?.value
        let fromPath = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let raw = fromQuery ?? (fromPath.isEmpty ? nil : fromPath), normalize(raw) != nil else { return nil }
        switch host {
        case "add", "subscribe": return .add(raw)
        case "remove", "unsubscribe": return .remove(raw)
        default: return nil
        }
    }

    /// 從影片網址或 11 碼 ID 取出影片 ID。
    static func videoID(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let idPattern = #"^[A-Za-z0-9_-]{11}$"#
        if s.range(of: idPattern, options: .regularExpression) != nil { return s }
        guard let c = URLComponents(string: s.hasPrefix("http") ? s : "https://" + s), let host = c.host else { return nil }
        var candidate: String?
        if host.hasSuffix("youtu.be") {
            candidate = c.path.split(separator: "/").first.map(String.init)
        } else if host.hasSuffix("youtube.com") {
            if let v = c.queryItems?.first(where: { $0.name == "v" })?.value {
                candidate = v
            } else {
                let parts = c.path.split(separator: "/").map(String.init)
                if parts.count >= 2, ["live", "shorts", "embed", "v"].contains(parts[0]) { candidate = parts[1] }
            }
        }
        guard let id = candidate, id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        return id
    }
}
