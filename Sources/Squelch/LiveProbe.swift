import Foundation

/// 查頻道現在有沒有在直播：打開 `頻道網址/live`。
///
/// - 正在直播：那一頁就是直播的影片頁，播放器資料 `videoDetails.isLive == true`。
/// - 排程中的直播：也是影片頁，但沒有 `isLive`（`isUpcoming == true`）。
/// - 沒在直播：導到頻道首頁，沒有播放器資料。
///
/// 一個頻道一個網頁請求，不啟動 yt-dlp、不帶帳號（獨立的 ephemeral session，不存 cookie）。
/// 2026/11/11 實測：Lofi Girl（直播中）、Apple Developer（排程中）、Theo（沒在直播）三種都判斷正確。
nonisolated enum LiveProbe {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// 回傳正在直播的那部；沒在直播、查不到都回傳 nil。
    static func check(channelID: String, channelTitle: String) async -> Episode? {
        guard let url = URL(string: channelID + "/live") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-TW,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(html: String(decoding: data, as: UTF8.self), channelID: channelID, channelTitle: channelTitle)
    }

    static func parse(html: String, channelID: String, channelTitle: String) -> Episode? {
        guard let json = WatchHistory.extractJSON(after: "ytInitialPlayerResponse = ", in: html),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let details = obj["videoDetails"] as? [String: Any],
              details["isLive"] as? Bool == true,
              let id = details["videoId"] as? String else { return nil }
        let title = details["title"] as? String ?? String(localized: "直播中")
        return Episode(id: id, title: title, channelID: channelID,
                       channelTitle: (details["author"] as? String) ?? channelTitle,
                       duration: nil, published: Date(), isStream: true, isLive: true)
    }
}
