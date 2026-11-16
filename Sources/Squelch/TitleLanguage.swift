import Foundation

/// 「自動翻譯（標題與音軌）」設定，預設關：標題和音軌都用影片原本的語言。
///
/// - 標題：yt-dlp 抓清單固定用英文介面（`hl=en`），有翻譯的影片會拿到英文標題（2026/11/16 老范的中文影片，
///   清單上是 “What’s Really in the Chinese-Market iOS 27.3?…”）。改 yt-dlp 的 `youtube:lang` 也不行：
///   「3 天前」變成別的語言，`approximate_date` 就解析不出日期（實測 ja、zh-TW 的 timestamp 都是 NA）。
///   所以清單照舊用英文抓，原文標題另外問 oEmbed（一部影片一個小請求，不帶帳號、不開 yt-dlp），存在 `Episode.originalTitle`。
///   YouTube 的 RSS（feeds/videos.xml）2026/11 已經 404。
/// - 音軌：關的時候挑原文音軌（yt-dlp 依 language_preference 排，原文最高）；開的時候先挑介面語言的配音，沒有才用原文。
nonisolated enum TitleLanguage {
    static let key = "autoTranslate"

    static var autoTranslate: Bool { UserDefaults.standard.bool(forKey: key) }

    /// 照設定挑要顯示的標題。
    static func shown(_ ep: Episode, translate: Bool = autoTranslate) -> String {
        let listed = ep.listedTitle ?? ep.title
        return translate ? listed : (ep.originalTitle ?? listed)
    }

    /// 剛從 yt-dlp 清單拿到的影片：記下清單標題，接上之前查過的原文標題，再照設定決定顯示哪個。
    static func adopt(_ ep: Episode, known: Episode?) -> Episode {
        var ep = ep
        ep.listedTitle = ep.title
        ep.originalTitle = ep.originalTitle ?? known?.originalTitle
        ep.title = shown(ep)
        return ep
    }

    /// 音軌要對的語言前綴（yt-dlp 的 `language` 欄位，例如 `en-US`、`zh-Hant`、`ja`）。
    static var dubLanguage: String {
        switch SubtitleTarget.system {
        case .zhHant, .zhHans: "zh"
        case .en: "en"
        case .ja: "ja"
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    enum Lookup: Sendable {
        case found(String)
        /// 影片不存在、私人、不能嵌入：不用再問。
        case missing
        /// 網路錯誤或被限流：下次再試。
        case retry
        case throttled
    }

    /// oEmbed 回的是影片原本的標題，不管 Accept-Language 是什麼（2026/11/16 實測）。
    static func original(videoID: String) async -> Lookup {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                                 URLQueryItem(name: "format", value: "json")]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .retry }
        switch status {
        case 200:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = obj["title"] as? String, !title.isEmpty else { return .missing }
            return .found(title)
        case 429: return .throttled
        case 400, 401, 403, 404: return .missing
        default: return .retry
        }
    }

    /// 一次查一批，同時最多 4 個；被限流就停，剩下的下次再查。
    static func originals(for ids: [String]) async -> (found: [String: String], missing: Set<String>) {
        var found: [String: String] = [:]
        var missing = Set<String>()
        var throttled = false
        var pending = ids[...]
        await withTaskGroup(of: (String, Lookup).self) { group in
            func next() {
                guard !throttled, let id = pending.popFirst() else { return }
                group.addTask { (id, await original(videoID: id)) }
            }
            for _ in 0..<4 { next() }
            for await (id, result) in group {
                switch result {
                case .found(let title): found[id] = title
                case .missing: missing.insert(id)
                case .throttled: throttled = true
                case .retry: break
                }
                next()
            }
        }
        return (found, missing)
    }
}
