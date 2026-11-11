import CryptoKit
import Foundation
import Synchronization

/// App 內建的 yt-dlp 會停在發版時那一版，YouTube 一改版就抓不到。
/// 每天到 GitHub 查一次官方最新版，比使用中的新就下載 onedir 版（核對 SHA-256）到
/// `~/Library/Application Support/Squelch/yt-dlp/`，不動 App 本體（簽章不會壞）。
/// 下載的檔案沒有隔離屬性，官方本身是 ad-hoc 簽章，直接就能執行。
nonisolated enum YTDLPUpdate {
    static let lastCheckKey = "ytdlpUpdateCheckedAt"
    /// 自我測試關掉，免得測試途中自己換掉 yt-dlp。
    static let automatic = Atomic<Bool>(true)
    private static let busy = Mutex<Bool>(false)

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch/yt-dlp", isDirectory: true)
    }

    enum Outcome: Sendable, Equatable {
        case upToDate(String)
        case updated(String)
    }

    /// yt-dlp 的版本是 `2026.10.26` 或 `2026.10.26.1`，逐段比數字。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// App 啟動時呼叫：距上次檢查超過一天才查。
    static func checkIfDue() {
        schedule(minimumInterval: 86400)
    }

    /// yt-dlp 失敗時呼叫：距上次檢查超過一小時才查。
    static func checkSoon() {
        schedule(minimumInterval: 3600)
    }

    private static func schedule(minimumInterval: TimeInterval) {
        guard automatic.load(ordering: .relaxed) else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > minimumInterval else { return }
        Task.detached(priority: .utility) { _ = try? await check() }
    }

    /// 查最新版；比使用中的新就裝。自訂路徑時不裝（使用者自己管）。
    @discardableResult
    static func check() async throws -> Outcome {
        guard busy.withLock({ was in defer { was = true }; return !was }) else {
            return .upToDate(YTDLP.binary()?.version ?? "")
        }
        defer { busy.withLock { $0 = false } }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        let latest = try await latestVersion()
        let current = YTDLP.binary()
        if let current, current.source == .custom || !isNewer(latest, than: current.version ?? "") {
            return .upToDate(current.version ?? latest)
        }
        try await install(version: latest, into: directory)
        return .updated(latest)
    }

    /// GitHub 的最新正式版（不帶帳號，一次請求）。
    static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, tag.first?.isNumber == true else {
            throw YTDLPError.failed(String(localized: "查不到 yt-dlp 的最新版本。"))
        }
        return tag
    }

    /// 下載官方 `yt-dlp_macos.zip`，核對 `SHA2-256SUMS`，解壓後實際跑一次 `--version`，都對了才換上去。
    static func install(version: String, into target: URL) async throws {
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/"
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(target.lastPathComponent + ".new", isDirectory: true)
        try? fm.removeItem(at: stage)
        defer { try? fm.removeItem(at: stage) }

        let (sums, sumsResponse) = try await retrying { try await URLSession.shared.data(from: URL(string: base + "SHA2-256SUMS")!) }
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .first(where: { $0.hasSuffix(" yt-dlp_macos.zip") })?.split(separator: " ").first.map(String.init) else {
            throw YTDLPError.failed(String(localized: "yt-dlp 新版的雜湊值抓不到。"))
        }
        let (zip, zipResponse) = try await retrying { try await URLSession.shared.download(from: URL(string: base + "yt-dlp_macos.zip")!) }
        defer { try? fm.removeItem(at: zip) }
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw YTDLPError.failed(String(localized: "yt-dlp 新版下載失敗。"))
        }
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            throw YTDLPError.failed(String(localized: "yt-dlp 新版的雜湊值不符，沒有換上去。"))
        }

        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, stage.path])
        let exe = stage.appendingPathComponent("yt-dlp_macos").path
        let reported = try runTool(exe, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == version else {
            throw YTDLPError.failed(String(localized: "yt-dlp 新版跑不起來（回報版本 \(reported)）。"))
        }
        try Data((version + "\n").utf8).write(to: stage.appendingPathComponent("VERSION"))

        // 先把舊的移開再放新的；正在跑的 yt-dlp 已經把需要的檔案開著，不受影響。
        let old = parent.appendingPathComponent(target.lastPathComponent + ".old", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
        try fm.moveItem(at: stage, to: target)
        try? fm.removeItem(at: old)
    }

    /// 54 MB 的下載偶爾會被斷線（2026/11/11 自我測試遇過「網路連線中斷」），網路錯誤最多試三次。
    private static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        for attempt in 1... {
            do {
                return try await body()
            } catch let error as URLError where attempt < 3 && error.code != .cancelled {
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
        fatalError()
    }

    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw YTDLPError.failed("\(URL(fileURLWithPath: path).lastPathComponent) exit \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
