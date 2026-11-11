import Foundation

/// 登入時把播放紀錄回報給 YouTube，讓網頁版、手機的「觀看記錄」和紅色進度條跟著 Squelch 走。
///
/// 網頁播放器自己會送兩種回報（Kaset ADR-0023 查過）：
/// - `videostatsPlaybackUrl`：開始播，影片進觀看記錄。
/// - `videostatsWatchtimeUrl`：播了哪一段（`st`～`et`）、現在在哪（`cmt`），YouTube 用來記進度。
/// 網址從登入狀態的影片頁 `ytInitialPlayerResponse.playbackTracking` 取得，參數照 yt-dlp `_mark_watched`，
/// 但 `cmt`／`et` 帶真正聽到的位置，不像 yt-dlp 一律標成看完。
@MainActor
final class WatchHistory {
    private let account: Account
    private var session: Session?
    private static let pingInterval: TimeInterval = 20

    private final class Session {
        let videoID: String
        let cpn = WatchHistory.makeCPN()
        var watchtimeURL: URL?
        var segmentStart: Double
        var lastPing = Date()
        var ready = false
        init(videoID: String, at position: Double) {
            self.videoID = videoID
            segmentStart = position
        }
    }

    init(account: Account) {
        self.account = account
    }

    func start(videoID: String, at position: Double) {
        stop(at: nil)
        guard account.isLoggedIn else { return }
        let session = Session(videoID: videoID, at: position)
        self.session = session
        Task {
            guard let tracking = await fetchTracking(videoID: videoID), self.session === session else { return }
            session.watchtimeURL = tracking.watchtime
            session.ready = true
            await send(tracking.playback, session: session, position: session.segmentStart, extra: [:])
        }
    }

    /// 播放中每 0.5 秒呼叫一次；每 20 秒回報一段。
    func tick(at position: Double, playing: Bool) {
        guard let session, session.ready, playing,
              Date().timeIntervalSince(session.lastPing) >= Self.pingInterval else { return }
        reportSegment(session, to: position, state: "playing")
    }

    func paused(at position: Double) {
        guard let session, session.ready else { return }
        reportSegment(session, to: position, state: "paused")
    }

    func resumed(at position: Double) {
        session?.segmentStart = position
        session?.lastPing = Date()
    }

    func seeked(from old: Double, to new: Double) {
        guard let session else { return }
        if session.ready { reportSegment(session, to: old, state: "playing") }
        session.segmentStart = new
    }

    func stop(at position: Double?) {
        if let session, session.ready, let position { reportSegment(session, to: position, state: "paused") }
        session = nil
    }

    private func reportSegment(_ session: Session, to position: Double, state: String) {
        guard let url = session.watchtimeURL else { return }
        let start = session.segmentStart
        session.segmentStart = position
        session.lastPing = Date()
        guard position > start else { return }
        Task {
            await send(url, session: session, position: position, extra: [
                "st": Self.seconds(start), "et": Self.seconds(position), "state": state,
            ])
        }
    }

    private func send(_ base: URL, session: Session, position: Double, extra: [String: String]) async {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        var params: [String: String] = ["ver": "2", "cpn": session.cpn, "cmt": Self.seconds(position), "el": "detailpage"]
        params.merge(extra) { _, new in new }
        var items = (components.queryItems ?? []).filter { params[$0.name] == nil }
        items += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue(Account.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(await account.cookieHeader(for: url), forHTTPHeaderField: "Cookie")
        if let (_, response) = try? await URLSession.shared.data(for: request) {
            await account.store(response)
        }
    }

    // MARK: 取得回報網址

    struct Tracking: Sendable {
        var playback: URL
        var watchtime: URL
    }

    private func fetchTracking(videoID: String) async -> Tracking? {
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=zh-TW")!
        var request = URLRequest(url: url)
        request.setValue(Account.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-TW,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(await account.cookieHeader(for: url), forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        await account.store(response)
        return Self.parseTracking(html: String(decoding: data, as: UTF8.self))
    }

    nonisolated static func parseTracking(html: String) -> Tracking? {
        guard let json = extractJSON(after: "ytInitialPlayerResponse = ", in: html),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let tracking = obj["playbackTracking"] as? [String: Any],
              let playback = (tracking["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String,
              let watchtime = (tracking["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String,
              let p = URL(string: playback), let w = URL(string: watchtime) else { return nil }
        return Tracking(playback: p, watchtime: w)
    }

    /// 從 HTML 裡切出 `marker` 後面那個完整的 JSON 物件（括號配對，略過字串內容）。
    nonisolated static func extractJSON(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let chars = text[range.upperBound...].utf8
        guard chars.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = chars.startIndex
        while index != chars.endIndex {
            let c = chars[index]
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(text[range.upperBound...index]) }
            }
            index = chars.index(after: index)
        }
        return nil
    }

    nonisolated static func seconds(_ value: Double) -> String { String(format: "%.3f", max(0, value)) }

    nonisolated static func makeCPN() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<64)] })
    }
}
