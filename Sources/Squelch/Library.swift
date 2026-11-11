import Foundation
import Observation

/// 頻道、影片、聽到哪裡、待播清單。全部存在
/// `~/Library/Application Support/Squelch/library.json`。
@MainActor @Observable
final class Library {
    var channels: [Channel] = []
    var episodes: [String: Episode] = [:]
    var progress: [String: Double] = [:]
    var lastPlayed: [String: Date] = [:]
    var finished: Set<String> = []
    var queue: [String] = []
    var subscriptionFeed: [String] = []
    /// 勾選頻道的直播檢查結果。只在按重新整理時更新，平常顯示快取。
    var liveFeed: [String] = []
    var liveChecked: Date?
    var checkingLive = false
    // 搜尋結果和觀看記錄只放在記憶體，不存檔；按播放時才記進 `episodes`。
    var searchQuery = ""
    var searchResults: [Episode] = []
    var searching = false
    var searchError: String?
    var historyFeed: [Episode] = []
    var historyLoading = false
    var historyError: String?
    var lastRefresh: Date?
    var refreshing = false
    var channelErrors: [String: String] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored var account: Account?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var channels: [Channel]
        var episodes: [Episode]
        var progress: [String: Double]
        var lastPlayed: [String: Date]?
        var finished: [String]
        var queue: [String]
        var subscriptionFeed: [String]?
        var liveFeed: [String]?
        var liveChecked: Date?
        var lastRefresh: Date?
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("library.json")
        // 第一次打開沒有任何頻道，由使用者自己加。
        if !load() { save() }
    }

    // MARK: 存檔

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else {
            // 讀不懂就留一份備份，不覆蓋。
            try? FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))"))
            return false
        }
        channels = snap.channels
        episodes = Dictionary(snap.episodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        progress = snap.progress
        lastPlayed = snap.lastPlayed ?? [:]
        finished = Set(snap.finished)
        queue = snap.queue.filter { episodes[$0] != nil }
        subscriptionFeed = (snap.subscriptionFeed ?? []).filter { episodes[$0] != nil }
        liveFeed = (snap.liveFeed ?? []).filter { episodes[$0] != nil }
        liveChecked = snap.liveChecked
        lastRefresh = snap.lastRefresh
        return true
    }

    func save() {
        let snap = Snapshot(channels: channels, episodes: Array(episodes.values), progress: progress,
                            lastPlayed: lastPlayed, finished: Array(finished).sorted(), queue: queue,
                            subscriptionFeed: subscriptionFeed, liveFeed: liveFeed, liveChecked: liveChecked,
                            lastRefresh: lastRefresh)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: 更新

    func startAutoRefresh(every interval: Duration = .seconds(30 * 60)) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // 自動更新完全不碰帳號：只抓 Squelch 自己的頻道。訂閱動態見 `loadSubscriptions`。
        let targets = channels.map { ($0.id, $0.includeStreams) }
        var liveIDs = Set<String>()
        await withTaskGroup(of: (String, Result<ChannelFeed, Error>).self) { group in
            for (id, streams) in targets {
                group.addTask {
                    do {
                        return (id, .success(try await YTDLP.feed(channelID: id, includeStreams: streams)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let feed):
                    apply(feed, to: id)
                    liveIDs.formUnion(feed.episodes.filter(\.liveNow).map(\.id))
                    channelErrors[id] = nil
                case .failure(let error):
                    channelErrors[id] = error.localizedDescription
                }
            }
        }
        channelLive = liveIDs
        applyLiveFlags()
        lastRefresh = Date()
        prune()
        save()
    }

    // MARK: 訂閱動態（要登入，看的時候才抓）

    @ObservationIgnored private var channelLive = Set<String>()
    @ObservationIgnored private var subscriptionLive = Set<String>()
    var subscriptionsFetched: Date?
    var subscriptionsLoading = false

    /// 訂閱 329 個頻道，匿名一個一個抓會超過 YouTube 對不登入的限流，所以用帳號抓 YouTube 的訂閱頁，
    /// 但只在打開「訂閱動態」或按重新整理時抓（距上次超過 10 分鐘才抓，`force` 例外）。背景完全不碰帳號。
    func loadSubscriptions(force: Bool = false) async {
        guard let account, account.isLoggedIn, !subscriptionsLoading else { return }
        if !force, let last = subscriptionsFetched, Date().timeIntervalSince(last) < 10 * 60 { return }
        subscriptionsLoading = true
        defer { subscriptionsLoading = false }
        do {
            let feed = try await YTDLP.subscriptions(cookies: account.cookieFile)
            await account.importCookieFile()
            for var ep in feed {
                if let old = episodes[ep.id], !ep.liveNow { ep.published = old.published ?? ep.published }
                episodes[ep.id] = ep
            }
            subscriptionFeed = feed.map(\.id)
            subscriptionLive = Set(feed.filter(\.liveNow).map(\.id))
            subscriptionsFetched = Date()
            channelErrors[YTDLP.subscriptionsURL] = nil
            applyLiveFlags()
            prune()
            save()
        } catch {
            channelErrors[YTDLP.subscriptionsURL] = error.localizedDescription
        }
    }

    // MARK: 直播檢查（勾選的頻道，每 10 分鐘自動查，不帶帳號、不用 yt-dlp）

    @ObservationIgnored private var liveWatchTask: Task<Void, Never>?
    static let liveCheckInterval: Duration = .seconds(10 * 60)

    /// App 開著時每 10 分鐘查一次勾選的頻道。一個頻道一個網頁請求，只勾 Theo 的話一小時 6 個。
    func startLiveWatch() {
        liveWatchTask?.cancel()
        liveWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkLive()
                try? await Task.sleep(for: Library.liveCheckInterval)
            }
        }
    }

    var liveWatchChannels: [Channel] { channels.filter { $0.watchLive == true } }

    func setWatchLive(_ id: String, _ on: Bool) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].watchLive = on ? true : nil
        if !on {
            liveFeed.removeAll { episodes[$0]?.channelID == id }
            applyLiveFlags()
        }
        save()
    }

    func checkLive() async {
        let targets = liveWatchChannels.map(\.id)
        guard !targets.isEmpty, !checkingLive else { return }
        checkingLive = true
        defer { checkingLive = false }
        var found: [Episode] = []
        let titles = Dictionary(uniqueKeysWithValues: liveWatchChannels.map { ($0.id, $0.title) })
        await withTaskGroup(of: Episode?.self) { group in
            for id in targets {
                let title = titles[id] ?? ""
                group.addTask { await LiveProbe.check(channelID: id, channelTitle: title) }
            }
            for await live in group { if let live { found.append(live) } }
        }
        for ep in found {
            var merged = ep
            if let old = episodes[ep.id] { merged.published = old.published ?? ep.published }
            episodes[ep.id] = merged
        }
        liveFeed = found.map(\.id)
        liveChecked = Date()
        applyLiveFlags()
        save()
    }

    /// 直播中的標記以最近一次抓到的為準，直播結束後不會一直標著。
    private func applyLiveFlags() {
        let live = channelLive.union(subscriptionLive).union(liveFeed)
        for (id, ep) in episodes where ep.liveNow != live.contains(id) {
            episodes[id]?.isLive = live.contains(id) ? true : nil
        }
    }

    private func apply(_ feed: ChannelFeed, to channelID: String) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].title = feed.title
        if let avatar = feed.avatar { channels[index].avatar = avatar }
        for var ep in feed.episodes {
            if let old = episodes[ep.id] {
                // 「2 天前」越久越不準，保留第一次看到時的估計。
                ep.published = old.published ?? ep.published
                ep.isStream = old.isStream || ep.isStream
            }
            episodes[ep.id] = ep
        }
    }

    /// 每個頻道只留最新 80 部；聽到一半、待播、正在聽的不刪。
    private func prune() {
        let keep = Set(queue).union(progress.keys).union(subscriptionFeed).union(liveFeed)
        let grouped = Dictionary(grouping: episodes.values, by: \.channelID)
        for (_, list) in grouped where list.count > 80 {
            for ep in list.sorted(by: Self.newestFirst).dropFirst(80) where !keep.contains(ep.id) {
                episodes[ep.id] = nil
            }
        }
    }

    // MARK: 搜尋、觀看記錄

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchQuery = q
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            let results = try await YTDLP.search(q)
            guard searchQuery == q else { return }
            searchResults = results.map(merged)
        } catch {
            guard searchQuery == q else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
    }

    /// 登入時抓 YouTube 的觀看記錄（手機上看的也在）。只在打開清單或手動重新整理時抓，不跟著自動更新跑。
    func loadHistory() async {
        guard let account, account.isLoggedIn, !historyLoading else { return }
        historyLoading = true
        historyError = nil
        defer { historyLoading = false }
        do {
            let items = try await YTDLP.history(cookies: account.cookieFile)
            await account.importCookieFile()
            historyFeed = items.map(merged)
        } catch {
            historyError = error.localizedDescription
        }
    }

    /// 已經認得的影片用本機資料（有頻道名稱、日期），觀看記錄的項目常常沒有頻道名稱。
    private func merged(_ ep: Episode) -> Episode {
        guard var known = episodes[ep.id] else { return ep }
        known.isLive = ep.isLive ?? known.isLive
        if known.duration == nil { known.duration = ep.duration }
        return known
    }

    // MARK: 頻道

    /// 回傳頻道名稱，給 `squelch://add` 顯示用。
    @discardableResult
    func addChannel(_ input: String) async throws -> String {
        guard let id = ChannelInput.normalize(input) else {
            throw YTDLPError.failed(String(localized: "看不懂這個頻道。可以貼 @handle、頻道網址或 UC 開頭的頻道 ID。"))
        }
        if channels.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            throw YTDLPError.failed(String(localized: "這個頻道已經在清單裡了。"))
        }
        let feed = try await YTDLP.feed(channelID: id, includeStreams: false)
        channels.append(Channel(id: id, title: feed.title, avatar: feed.avatar))
        apply(feed, to: id)
        save()
        return feed.title
    }

    /// 給 `squelch://remove` 用：接受跟加入時一樣的寫法，大小寫不拘。回傳頻道名稱。
    @discardableResult
    func removeChannel(matching input: String) throws -> String {
        guard let id = ChannelInput.normalize(input),
              let channel = channels.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw YTDLPError.failed(String(localized: "清單裡沒有這個頻道。"))
        }
        removeChannel(channel.id)
        return channel.title
    }

    func removeChannel(_ id: String) {
        channels.removeAll { $0.id == id }
        let keep = Set(queue).union(progress.keys)
        for ep in episodes.values where ep.channelID == id && !keep.contains(ep.id) {
            episodes[ep.id] = nil
        }
        channelErrors[id] = nil
        save()
    }

    func setIncludeStreams(_ id: String, _ on: Bool) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].includeStreams = on
        save()
        Task { await refresh() }
    }

    // MARK: 播放紀錄

    func remember(_ ep: Episode) {
        if episodes[ep.id] == nil { episodes[ep.id] = ep }
    }

    func setProgress(_ id: String, _ seconds: Double) {
        if seconds < 5 {
            progress[id] = nil
        } else {
            progress[id] = seconds
            finished.remove(id)
        }
        lastPlayed[id] = Date()
        save()
    }

    func resumePosition(for ep: Episode) -> Double {
        guard !finished.contains(ep.id), let p = progress[ep.id] else { return 0 }
        if let d = ep.duration, p > d - 20 { return 0 }
        return p
    }

    func markFinished(_ id: String) {
        finished.insert(id)
        progress[id] = nil
        queue.removeAll { $0 == id }
        save()
    }

    func toggleFinished(_ id: String) {
        if finished.contains(id) {
            finished.remove(id)
        } else {
            finished.insert(id)
            progress[id] = nil
        }
        save()
    }

    // MARK: 待播清單

    func enqueue(_ id: String) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        save()
    }

    func playNextInQueue(_ id: String) {
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        save()
    }

    func dequeue(_ id: String) {
        queue.removeAll { $0 == id }
        save()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func popQueue(excluding current: String?) -> Episode? {
        queue.removeAll { $0 == current }
        while let first = queue.first {
            queue.removeFirst()
            if let ep = episodes[first] {
                save()
                return ep
            }
        }
        save()
        return nil
    }

    // MARK: 清單

    func list(for item: SidebarItem) -> [Episode] {
        switch item {
        case .latest:
            return episodes.values.filter { ep in channels.contains { $0.id == ep.channelID } }
                .sorted { a, b in a.liveNow != b.liveNow ? a.liveNow : Self.newestFirst(a, b) }
        case .live:
            return liveFeed.compactMap { episodes[$0] }
        case .search:
            return searchResults
        case .history:
            if account?.isLoggedIn == true { return historyFeed }
            return lastPlayed.sorted { $0.value > $1.value }.compactMap { episodes[$0.key] }
        case .subscriptions:
            guard account?.isLoggedIn == true else { return [] }
            return subscriptionFeed.compactMap { episodes[$0] }
                .sorted { a, b in a.liveNow != b.liveNow ? a.liveNow : Self.newestFirst(a, b) }
        case .inProgress:
            return progress.keys.compactMap { episodes[$0] }
                .sorted { (lastPlayed[$0.id] ?? .distantPast) > (lastPlayed[$1.id] ?? .distantPast) }
        case .queue:
            return queue.compactMap { episodes[$0] }
        case .channel(let id):
            return episodes.values.filter { $0.channelID == id }.sorted(by: Self.newestFirst)
        }
    }

    nonisolated static func newestFirst(_ a: Episode, _ b: Episode) -> Bool {
        (a.published ?? .distantPast) > (b.published ?? .distantPast)
    }
}
