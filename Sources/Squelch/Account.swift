import Foundation
import Observation
import WebKit

/// YouTube 帳號。做法照 Kaset：App 內開 Google 登入頁，cookie 存在 Squelch 自己的 WebKit 資料區，
/// 跟瀏覽器分開（瀏覽器開著的 YouTube 分頁會一直輪換 cookie）。
///
/// 帳號只用在兩件事：抓訂閱動態（yt-dlp `--cookies`）、回報播放紀錄（`WatchHistory`）。
/// 解析音軌照舊不帶帳號。yt-dlp 官方提醒帳號搭配 yt-dlp 有被封鎖的風險，所以帶帳號的請求越少越好。
@MainActor @Observable
final class Account {
    /// 固定的資料區 ID：同一份登入狀態跨版本沿用。
    static let storeID = UUID(uuidString: "5C1E7C40-2B1D-4C59-9A0E-5F2D6B8A5E1C")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Dzh-TW%26next%3Dhttps%253A%252F%252Fwww.youtube.com%252F")!

    var isLoggedIn = false

    /// 用到才建立：WebKit 要在 NSApplication 跑起來之後才能初始化（自我測試模式沒有）。
    @ObservationIgnored lazy var dataStore = WKWebsiteDataStore(forIdentifier: Account.storeID)
    @ObservationIgnored let cookieFile: URL

    nonisolated static var defaultCookieFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch/cookies.txt")
    }

    init(cookieFile: URL = Account.defaultCookieFile, checkWebKit: Bool = true) {
        try? FileManager.default.createDirectory(at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.cookieFile = cookieFile
        isLoggedIn = FileManager.default.fileExists(atPath: cookieFile.path)
        if checkWebKit { Task { await refreshState() } }
    }

    func refreshState() async {
        let cookies = await youtubeCookies()
        isLoggedIn = cookies.contains { $0.name == "__Secure-3PAPISID" }
        if isLoggedIn {
            writeCookieFile(cookies)
        } else {
            try? FileManager.default.removeItem(at: cookieFile)
        }
    }

    func logout() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? FileManager.default.removeItem(at: cookieFile)
        isLoggedIn = false
    }

    // MARK: cookie

    private func youtubeCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies().filter { Self.isAccountDomain($0.domain) }
    }

    nonisolated static func isAccountDomain(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return ["youtube.com", "google.com"].contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// 給 yt-dlp 的 Netscape 格式 cookie 檔，權限 0600。
    func writeCookieFile(_ cookies: [HTTPCookie]) {
        let text = Self.netscape(cookies)
        FileManager.default.createFile(atPath: cookieFile.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// yt-dlp 跑完會把輪換過的 cookie 寫回檔案，讀回 WebKit 資料區，兩邊保持一致。
    func importCookieFile() async {
        guard let text = try? String(contentsOf: cookieFile, encoding: .utf8) else { return }
        let store = dataStore.httpCookieStore
        let current = Dictionary(await youtubeCookies().map { ("\($0.domain)|\($0.path)|\($0.name)", $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        for cookie in Self.parseNetscape(text) where Self.isAccountDomain(cookie.domain) {
            if current["\(cookie.domain)|\(cookie.path)|\(cookie.name)"] != cookie.value {
                await store.setCookie(cookie)
            }
        }
    }

    /// 送給 youtube.com 的 Cookie 標頭。
    func cookieHeader(for url: URL) async -> String {
        guard let host = url.host else { return "" }
        return await youtubeCookies()
            .filter { cookie in
                let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == d || host.hasSuffix("." + d)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 回應裡的 Set-Cookie 存回資料區（YouTube 會輪換 session cookie）。
    func store(_ response: URLResponse) async {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              let fields = http.allHeaderFields as? [String: String] else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            await dataStore.httpCookieStore.setCookie(cookie)
        }
    }

    nonisolated static func netscape(_ cookies: [HTTPCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Squelch 匯出，給 yt-dlp 用。"]
        for c in cookies {
            let domain = c.domain
            let sub = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expiry = c.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            lines.append([domain, sub, c.path, c.isSecure ? "TRUE" : "FALSE", expiry, c.name, c.value].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func parseNetscape(_ text: String) -> [HTTPCookie] {
        text.split(separator: "\n").compactMap { raw in
            var line = String(raw)
            if line.hasPrefix("#HttpOnly_") { line = String(line.dropFirst("#HttpOnly_".count)) }
            guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: f[0], .path: f[2], .name: f[5], .value: f[6],
            ]
            if f[3] == "TRUE" { props[.secure] = "TRUE" }
            if let t = Double(f[4]), t > 0 { props[.expires] = Date(timeIntervalSince1970: t) }
            return HTTPCookie(properties: props)
        }
    }

    // MARK: 登入網頁

    /// 內嵌網頁的 passkey 一定失敗（要 Apple 的瀏覽器 entitlement），Google 會卡在「請開藍牙」。
    /// 照 Kaset ADR-0033：在登入頁藏掉 WebAuthn，Google 就改走密碼。
    static let passkeySuppression = """
    (() => {
      try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
      const creds = navigator.credentials;
      if (!creds) return;
      const deny = () => Promise.reject(new DOMException('Passkeys are not available here', 'NotAllowedError'));
      const get = creds.get && creds.get.bind(creds), create = creds.create && creds.create.bind(creds);
      creds.get = (o) => (o && o.publicKey) ? deny() : get(o);
      creds.create = (o) => (o && o.publicKey) ? deny() : create(o);
    })();
    """

    func makeLoginConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController.addUserScript(
            WKUserScript(source: Self.passkeySuppression, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return config
    }
}
