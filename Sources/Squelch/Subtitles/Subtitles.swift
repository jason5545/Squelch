import Foundation
import Observation

/// 字幕：有 YouTube 字幕（人工或自動）就拿來翻，沒有才用本機語音辨識。預設全部關著。
/// 直播沒有字幕可抓：模型已經在這台 Mac 上就直接聽寫，不然要使用者按一下才下載模型。直播的時間軸是實際時間（UNIX 秒）。
///
/// 翻譯和辨識都跑在播放位置前面：翻譯先翻接下來 5 分鐘內的句子，一次最多兩批；辨識最多做到播放位置後 3 分鐘。
/// 用不到就釋放：關掉字幕時 codex app-server 和語音模型都停掉；開著的時候，這一集用不到語音辨識（有字幕）
/// 或暫停超過 5 分鐘就卸載模型（約 2.3 GB），再播時自動載回來（約 3 秒）；10 分鐘沒有翻譯就停掉 codex app-server，
/// 下一批翻譯時自動再開。
/// 翻成哪種語言預設跟著介面語言（正體中文、简体中文、English、日本語），設定裡可以改。
/// 結果存在 `~/Library/Caches/Squelch/subtitles/<影片 ID>.<目標語言>.json`，重聽不用再翻。
@MainActor @Observable
final class Subtitles {
    enum Status: Equatable {
        case idle
        case loading
        /// 字幕來源。`language` 是 YouTube 的語言代碼。
        case captions(language: String, auto: Bool)
        case speech
        case unavailable(String)
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                reattach()
            } else {
                stopAll()
                // 不用字幕就不要讓 codex app-server 和 2.5 GB 的模型一直留著。
                stopCodex()
                unloadSpeech()
            }
        }
    }
    /// 沒有字幕時用本機語音辨識。打開時才準備模型（可能要下載 2.5 GB）。
    var speechFallback: Bool {
        didSet {
            UserDefaults.standard.set(speechFallback, forKey: Self.speechKey)
            if speechFallback {
                model.prepare()
                if enabled, case .unavailable = status { reattach() }
            } else {
                stopSpeech()
                unloadSpeech()
            }
        }
    }

    /// 翻成哪種語言。空字串是跟著介面語言。
    var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: Self.languageKey)
            // 換語言：已經翻好的不能用，重新來過（各語言的快取分開存）。
            if enabled { reattach() }
        }
    }
    var target: SubtitleTarget { SubtitleTarget(rawValue: language) ?? .system }

    private(set) var cues: [Cue] = []
    private(set) var status: Status = .idle
    /// 最近一次翻譯失敗的原因。成功一次就清掉。
    private(set) var translationError: String?
    /// 這一集的字幕要翻（原文不是中文）。
    private(set) var needsTranslation = false
    /// 沒有字幕、本機語音辨識也沒開：字幕列提供一顆按鈕打開它。
    private(set) var offerSpeech = false
    let model = SpeechModel()

    static let enabledKey = "subtitles"
    static let speechKey = "subtitlesSpeech"
    static let languageKey = "subtitlesLanguage"
    /// 換了解析方式就加一，舊的快取不用。
    static let cacheVersion = 2

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored private var episode: Episode?
    @ObservationIgnored private var stream: ResolvedStream?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var translateTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private let translator = CodexTranslator()
    @ObservationIgnored private let speech = SpeechTranscriber()
    /// 正在翻的句子（用開始時間當鍵）。
    @ObservationIgnored private var inFlight: Set<Double> = []
    @ObservationIgnored private var batches = 0
    @ObservationIgnored private var retryAfter = Date.distantPast
    // 閒置釋放（見最上面的說明）。
    /// 檢查模式會縮短，正式使用不改。
    static var speechIdle: TimeInterval = 5 * 60
    static var codexIdle: TimeInterval = 10 * 60
    @ObservationIgnored private var speechLoaded = false
    /// 卸載、載入語音模型排成一條，不會載入到一半又被前一個卸載蓋掉。
    @ObservationIgnored private var speechOp: Task<Void, Never>?
    /// 暫停太久被停掉的語音辨識，再播時接回來。
    @ObservationIgnored private var speechSuspended = false
    @ObservationIgnored private var lastPlaying = Date()
    @ObservationIgnored private var codexRunning = false
    @ObservationIgnored private var lastTranslation = Date.distantPast
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        speechFallback = UserDefaults.standard.bool(forKey: Self.speechKey)
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
    }

    /// 截圖用：直接給字幕，不讀也不寫設定。
    init(preview: [Cue], enabled: Bool) {
        self.enabled = enabled
        speechFallback = false
        language = SubtitleTarget.zhHant.rawValue
        cues = preview
        status = .captions(language: "en", auto: false)
        needsTranslation = true
    }

    // MARK: 跟 Player 接

    /// 開始播一個音軌（開播、跳轉後重新解析網址也會呼叫）。
    func attach(_ ep: Episode, _ stream: ResolvedStream) {
        let same = episode?.id == ep.id
        episode = ep
        self.stream = stream
        guard enabled else { return }
        if same, status != .idle, status != .loading { return }
        if !same { reset() }
        load()
    }

    private func reattach() {
        guard let ep = player?.current ?? episode, let stream else { return }
        episode = nil
        attach(ep, stream)
    }

    private func reset() {
        stopAll()
        cues = []
        needsTranslation = false
        translationError = nil
        retryAfter = .distantPast
        speechSuspended = false
        heard = []
    }

    private func stopAll() {
        loadTask?.cancel()
        loadTask = nil
        translateTask?.cancel()
        translateTask = nil
        stopSpeech()
        inFlight = []
        batches = 0
        if !enabled { status = .idle }
    }

    private func stopSpeech() {
        speechTask?.cancel()
        speechTask = nil
    }

    // MARK: 顯示

    /// 這個時間要顯示的那句。句子結束後再留 1 秒，或留到下一句開始。
    func cue(at time: Double) -> Cue? {
        var low = 0, high = cues.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let cue = cues[found]
        let nextStart = found + 1 < cues.count ? cues[found + 1].start : .infinity
        return time <= min(cue.end + 1, nextStart) ? cue : nil
    }

    // MARK: 載入

    private func load() {
        guard let ep = episode, let stream else { return }
        status = .loading
        offerSpeech = false
        let target = target
        loadTask = Task {
            if let cached = Self.readCache(ep.id, target) {
                cues = cached.cues
                needsTranslation = cached.needsTranslation
                status = cached.status
                if cached.status == .speech {
                    heard = cached.heardRanges
                    startSpeech()
                }
                startTranslating()
                return
            }
            do {
                var sources = stream.captions
                if sources == nil, stream.isLocal { sources = try await YTDLP.captions(videoID: ep.id) }
                guard !Task.isCancelled, episode?.id == ep.id else { return }
                if let sources, let track = Captions.choose(sources, target: target) {
                    let found = try await Captions.fetch(track, target: target, headers: stream.headers)
                    guard !Task.isCancelled, episode?.id == ep.id else { return }
                    if !found.isEmpty {
                        cues = found
                        needsTranslation = track.handling == .translate
                        status = .captions(language: track.language, auto: track.isAuto)
                        unloadSpeech()   // 有字幕就用不到語音模型
                        save()
                        startTranslating()
                        return
                    }
                }
                noCaptions()
            } catch {
                guard !Task.isCancelled, episode?.id == ep.id else { return }
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    /// 沒有字幕。直播只要模型已經在這台 Mac 上就直接聽寫；其他情況要使用者打開「本機語音辨識」（可能要下載模型）。
    /// 這一集可以用本機語音辨識：開關打開，或是直播而且模型已經在這台 Mac 上（不用下載）。
    private var speechAllowed: Bool {
        let live = stream?.isLive == true || episode?.liveNow == true
        return speechFallback || (live && model.state == .ready)
    }

    private func noCaptions() {
        let live = stream?.isLive == true || episode?.liveNow == true
        guard speechAllowed else {
            status = .unavailable(live ? String(localized: "這場直播沒有字幕") : String(localized: "這部沒有字幕"))
            offerSpeech = true
            return
        }
        status = .speech
        needsTranslation = true
        startSpeech()
        startTranslating()
    }

    // MARK: 翻譯

    private func startTranslating() {
        guard translateTask == nil else { return }
        translateTask = Task {
            while !Task.isCancelled {
                scheduleBatch()
                releaseIdle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func scheduleBatch() {
        guard needsTranslation, batches < 2, Date() >= retryAfter, let ep = episode else { return }
        let position = player?.current?.id == ep.id ? player?.subtitleClock ?? 0 : 0
        let pending = cues.indices.filter { i in
            cues[i].translation == nil && !inFlight.contains(cues[i].start)
                && cues[i].end >= position - 5 && cues[i].start <= position + 300
        }
        guard let first = pending.first else { return }
        // 一開始先翻一小批，字幕早點出來；已經翻到前面了就一次翻多一點。
        let readyAhead = cues.last { $0.translation != nil && $0.start >= position }.map { $0.start - position } ?? 0
        let size = readyAhead < 20 ? 6 : 16
        let picked = Array(pending.prefix(size))
        // 正在辨識、後面還沒出來的句子先等一下，湊不到一批又離播放位置還遠就先不送。
        if status == .speech, picked.count < size, cues[first].start > position + 30 { return }
        let items = picked.enumerated().map { CodexTranslator.Item(id: $0.offset + 1, text: cues[$0.element].text) }
        let starts = picked.map { cues[$0].start }
        let before = cues[max(0, first - 4)..<first].map { ($0.text, $0.translation) }
        let lastIndex = picked.last!
        let after = cues[(lastIndex + 1)..<min(cues.count, lastIndex + 3)].map(\.text)
        let batch = CodexTranslator.Batch(target: target, title: ep.title, channel: ep.channelTitle, items: items,
                                          before: Array(before), after: Array(after))
        starts.forEach { inFlight.insert($0) }
        batches += 1
        codexRunning = true
        lastTranslation = Date()
        Task {
            defer {
                lastTranslation = Date()
                batches -= 1
                starts.forEach { inFlight.remove($0) }
            }
            do {
                let result = try await translator.translate(batch)
                guard episode?.id == ep.id, target == batch.target else { return }
                for (n, start) in starts.enumerated() {
                    if let i = cues.firstIndex(where: { $0.start == start }) { cues[i].translation = result[n + 1] }
                }
                translationError = nil
                save()
            } catch is CancellationError {
            } catch {
                guard episode?.id == ep.id else { return }
                translationError = error.localizedDescription
                // codex 不在：不要一直重試。其他錯誤等 15 秒。
                if case SubtitleError.codexMissing = error {
                    retryAfter = .distantFuture
                } else {
                    retryAfter = Date().addingTimeInterval(15)
                }
            }
        }
    }

    // MARK: 閒置釋放

    /// 每秒跟著翻譯排程跑一次。
    private func releaseIdle() {
        let playing = player?.isPlaying == true && player?.current?.id == episode?.id
        if playing { lastPlaying = Date() }
        // 語音辨識：暫停超過 5 分鐘就停掉、卸載模型；再播時接回來。
        if speechTask != nil, !playing, Date().timeIntervalSince(lastPlaying) > Self.speechIdle {
            stopSpeech()
            speechSuspended = true
            unloadSpeech()
        } else if speechSuspended, playing, status == .speech {
            speechSuspended = false
            startSpeech()
        } else if speechTask == nil, !speechSuspended {
            unloadSpeech()   // 這一集用不到（有字幕、或辨識結束了）
        }
        // Codex：10 分鐘沒有翻譯就停掉，下一批會自己再開。
        if codexRunning, batches == 0, Date().timeIntervalSince(lastTranslation) > Self.codexIdle {
            stopCodex()
        }
    }

    /// 檢查模式用：語音模型、codex app-server 現在有沒有載著。
    func resourceState() async -> (speech: Bool, codex: Bool) {
        await speechOp?.value
        return (await speech.isLoaded, await translator.isRunning)
    }

    private func unloadSpeech() {
        guard speechLoaded else { return }
        speechLoaded = false
        let previous = speechOp
        speechOp = Task {
            await previous?.value
            await speech.unload()
        }
    }

    private func stopCodex() {
        codexRunning = false
        Task { await translator.stop() }
    }

    // MARK: 語音辨識

    private func startSpeech() {
        guard speechAllowed, speechTask == nil, let ep = episode, let stream else { return }
        speechTask = Task {
            // 模型還沒好就先準備（打開設定時已經開始了），好了才接著做。
            model.prepare()
            while model.state != .ready {
                if case .failed = model.state { return }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            do {
                await speechOp?.value
                try await speech.load(SpeechModel.directory)
                speechLoaded = true
            } catch {
                status = .unavailable(error.localizedDescription)
                return
            }
            let live = stream.isLive
            let end = live ? .infinity : (stream.duration ?? .infinity) - 1
            // 直播要等 AVPlayer 開始播、有實際時間了才知道從哪裡開始。
            while live, (player?.subtitleClock ?? 0) < 1e9 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            while !Task.isCancelled, episode?.id == ep.id {
                // 從播放位置開始；播放位置在做過的範圍裡，就從那段的結尾接著做。
                let position = player?.subtitleClock ?? 0
                var from = position
                if let range = heard.first(where: { position >= $0.lowerBound - 2 && position <= $0.upperBound + 5 }) {
                    from = range.upperBound
                }
                if from >= end {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                runStart = from
                mark(from...from)
                let player = player
                let state = RunState()
                let run = Task {
                    defer { state.done = true }
                    try await speech.run(stream, from: from, horizon: { @MainActor in
                        (player?.subtitleClock ?? 0) + 180
                    }, emit: { @MainActor [weak self] cue, reached in
                        self?.speechEmitted(cue, reached: reached, episodeID: ep.id, state: state)
                    })
                }
                // 跳到這次範圍外面、或碰到另一段做過的，就停掉重找起點。
                while !state.done {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled || state.overlapped {
                        run.cancel()
                        break
                    }
                    let now = player?.subtitleClock ?? 0
                    if let range = heard.first(where: { $0.contains(runStart) }),
                       now < range.lowerBound - 2 || now > range.upperBound + 30 {
                        run.cancel()
                        break
                    }
                }
                if case .failure(let error) = await run.result, !(error is CancellationError) {
                    status = .unavailable(error.localizedDescription)
                    return
                }
            }
        }
    }

    @MainActor private final class RunState {
        var done = false
        var overlapped = false
    }

    /// 辨識過的範圍（影片時間），不重疊、由早到晚。
    @ObservationIgnored private var heard: [ClosedRange<Double>] = []
    @ObservationIgnored private var runStart = 0.0

    private func mark(_ range: ClosedRange<Double>) {
        var merged = range
        var rest: [ClosedRange<Double>] = []
        for r in heard {
            if r.upperBound + 0.5 >= merged.lowerBound && r.lowerBound - 0.5 <= merged.upperBound {
                merged = min(r.lowerBound, merged.lowerBound)...max(r.upperBound, merged.upperBound)
            } else {
                rest.append(r)
            }
        }
        heard = (rest + [merged]).sorted { $0.lowerBound < $1.lowerBound }
    }

    private func speechEmitted(_ cue: Cue?, reached: Double, episodeID: String, state: RunState) {
        guard episode?.id == episodeID, !state.overlapped,
              let range = heard.first(where: { $0.contains(runStart) }) else { return }
        // 做到下一段做過的範圍：那裡的字幕已經有了，接起來就停。
        if let next = heard.first(where: { $0.lowerBound > range.upperBound + 0.5 }), reached >= next.lowerBound {
            state.overlapped = true
            mark(range.lowerBound...next.lowerBound)
            save()
            return
        }
        mark(range.lowerBound...max(range.upperBound, reached))
        if var cue {
            // 偵測到的語言就是目標語言：直接顯示；中文對中文：正簡轉換。其他留給翻譯。
            if let language = cue.language {
                switch target.handling(for: language, isAuto: true) {
                case .direct: cue.translation = cue.text
                case .convert: cue.translation = target.convert(cue.text)
                case .translate: break
                }
            }
            let index = cues.firstIndex { $0.start > cue.start } ?? cues.count
            cues.insert(cue, at: index)
        }
        // 直播只留最近 2 小時，24 小時的直播也不會越存越大。
        if stream?.isLive == true, let clock = player?.subtitleClock, clock > 1e9, let first = cues.first, first.start < clock - 7200 {
            cues.removeAll { $0.start < clock - 7200 }
            heard = heard.filter { $0.upperBound >= clock - 7200 }
        }
        save()
    }

    // MARK: 快取

    nonisolated private struct CacheFile: Codable, Sendable {
        var version: Int
        var language: String?
        var auto: Bool?
        var speech: Bool
        var needsTranslation: Bool
        var cues: [Cue]
        var heard: [[Double]]?

        var status: Status {
            speech ? .speech : .captions(language: language ?? "", auto: auto ?? false)
        }
        var heardRanges: [ClosedRange<Double>] {
            (heard ?? []).compactMap { $0.count == 2 && $0[1] >= $0[0] ? $0[0]...$0[1] : nil }
        }
    }

    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch/subtitles", isDirectory: true)
    }

    nonisolated static func cacheFile(_ id: String, _ target: SubtitleTarget) -> URL {
        cacheDirectory.appendingPathComponent("\(id).\(target.rawValue).json")
    }

    private static func readCache(_ id: String, _ target: SubtitleTarget) -> CacheFile? {
        let url = cacheFile(id, target)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion, !file.cues.isEmpty || file.speech else { return nil }
        return file
    }

    /// 寫檔延後 2 秒，翻譯一批批回來時不用每批都寫。
    private func save() {
        guard let ep = episode else { return }
        var file = CacheFile(version: Self.cacheVersion, language: nil, auto: nil, speech: status == .speech,
                             needsTranslation: needsTranslation, cues: cues,
                             heard: heard.map { [$0.lowerBound, min($0.upperBound, 1e12)] })
        if case .captions(let language, let auto) = status {
            file.language = language
            file.auto = auto
        }
        let url = Self.cacheFile(ep.id, target)
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(file) else { return }
            let dir = Self.cacheDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
