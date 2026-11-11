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
    var lastRefresh: Date?
    var refreshing = false
    var channelErrors: [String: String] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var channels: [Channel]
        var episodes: [Episode]
        var progress: [String: Double]
        var lastPlayed: [String: Date]?
        var finished: [String]
        var queue: [String]
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
        lastRefresh = snap.lastRefresh
        return true
    }

    func save() {
        let snap = Snapshot(channels: channels, episodes: Array(episodes.values), progress: progress,
                            lastPlayed: lastPlayed, finished: Array(finished).sorted(), queue: queue,
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
        let targets = channels.map { ($0.id, $0.includeStreams) }
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
                    channelErrors[id] = nil
                case .failure(let error):
                    channelErrors[id] = error.localizedDescription
                }
            }
        }
        lastRefresh = Date()
        prune()
        save()
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
        let keep = Set(queue).union(progress.keys)
        let grouped = Dictionary(grouping: episodes.values, by: \.channelID)
        for (_, list) in grouped where list.count > 80 {
            for ep in list.sorted(by: Self.newestFirst).dropFirst(80) where !keep.contains(ep.id) {
                episodes[ep.id] = nil
            }
        }
    }

    // MARK: 頻道

    func addChannel(_ input: String) async throws {
        guard let id = ChannelInput.normalize(input) else {
            throw YTDLPError.failed("看不懂這個頻道。可以貼 @handle、頻道網址或 UC 開頭的頻道 ID。")
        }
        if channels.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            throw YTDLPError.failed("這個頻道已經在清單裡了。")
        }
        let feed = try await YTDLP.feed(channelID: id, includeStreams: false)
        channels.append(Channel(id: id, title: feed.title, avatar: feed.avatar))
        apply(feed, to: id)
        save()
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
                .sorted(by: Self.newestFirst)
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
