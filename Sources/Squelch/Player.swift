import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class Player {
    static let rates: [Float] = [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3]

    var current: Episode?
    var isPlaying = false
    var isLoading = false
    var isBuffering = false
    var position: Double = 0
    var duration: Double = 0
    var errorMessage: String?
    var notice: String?
    var segments: [SkipSegment] = []
    var isLive = false
    /// 0～2。超過 1 的部分是放大：HLS 由 `SegmentPlayer` 在解碼後乘上去，本機檔由 `Boost` 的 tap 做。
    var volume: Float {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            applyVolume()
            if volume > 1 { prepareBoost() }
        }
    }
    /// 拉超過 100%、正在下載本機檔準備放大。
    var boostPending = false
    var isLocalPlayback = false
    /// 現在的播放方式能放大：自己解碼的 HLS，或本機檔。
    var canBoost = false
    /// 關掉就全部交給 AVPlayer（0.6 以前的做法，現在是備援）。自我測試用它來測備援那條路。
    static var useSegments = true
    /// 自我測試用：不出聲，其他照常。
    @ObservationIgnored var silent = false {
        didSet { applyVolume() }
    }
    /// 不是 nil 時由它出聲，AVPlayer 沒有東西在播。
    @ObservationIgnored private(set) var segmentPlayer: SegmentPlayer?
    /// 這一集的 HLS 不是 `SegmentPlayer` 會解的格式，改用 AVPlayer。
    @ObservationIgnored private var segmentsUnsupported = false
    @ObservationIgnored private var volumeBeforeMute: Float = 1
    @ObservationIgnored private var boostTask: Task<Void, Never>?
    var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: "rate")
            segmentPlayer?.rate = rate
            if isPlaying && !isLive && segmentPlayer == nil { avPlayer.rate = rate }
            nowPlaying.update()
        }
    }

    @ObservationIgnored let library: Library
    /// 登入時回報播放紀錄；沒登入時 `WatchHistory` 自己什麼都不做。
    @ObservationIgnored var history: WatchHistory?
    /// 字幕：開播時告訴它這一集的音軌。
    @ObservationIgnored weak var subtitles: Subtitles?
    @ObservationIgnored private var historyStarted = false
    @ObservationIgnored let avPlayer = AVPlayer()
    @ObservationIgnored private(set) var nowPlaying = NowPlaying()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    @ObservationIgnored private var resolved: [String: ResolvedStream] = [:]
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var pendingPause = false
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var skipped: Set<SkipSegment> = []
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var stallTimer: Timer?
    @ObservationIgnored private var lastProgress: Double = -1
    @ObservationIgnored private var stalledSince: Date?
    /// 直播：AVPlayer 的時間是在 YouTube 回放窗口（約 1 小時）裡的位置，一開播就是 3585 秒左右
    /// （2026/11/12 實測，重新開播也一樣）。介面直播不顯示聽了多久；`position` 只給播放紀錄回報用，
    /// 只把播放中、每次不到 2 秒的前進加上去，拉進度或回到直播造成的跳動不算。
    @ObservationIgnored private var liveLastTick: Double?
    /// 直播在回放窗口裡的位置（AVPlayer 的時間），和可以拉的範圍。
    var liveTime: Double = 0
    var liveWindow: ClosedRange<Double>?
    /// 直播正在播的那一刻的實際時間（UNIX 秒）。YouTube 直播的 HLS 有 `EXT-X-PROGRAM-DATE-TIME`，
    /// AVPlayer 的 `currentDate()` 就是它；字幕的語音辨識用同一個時間戳，兩邊才對得上。
    var liveDate: Double = 0
    /// 字幕對時用的時間：一般影片是播放位置，直播是 `liveDate`。
    var subtitleClock: Double { isLive ? liveDate : position }
    /// 窗口至少 2 分鐘才算支援回放；沒有的直播只能聽最新的。
    var canSeekLive: Bool { isLive && (liveWindow.map { $0.upperBound - $0.lowerBound } ?? 0) >= 120 }
    /// 落後最新多少秒。剛開播約 0（AVPlayer 會停在窗口尾端附近）。
    var liveBehind: Double { max(0, (liveWindow?.upperBound ?? liveTime) - liveTime) }
    /// 落後不到 15 秒（YouTube 一段 5 秒，抖一兩段很正常）就算在最新。
    var isAtLiveEdge: Bool { liveBehind < 15 }

    init(library: Library) {
        self.library = library
        let saved = UserDefaults.standard.float(forKey: "rate")
        rate = saved > 0 ? saved : 1
        let savedVolume = UserDefaults.standard.object(forKey: "volume") as? Float
        volume = savedVolume ?? 1
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self, self.segmentPlayer == nil else { return }
                self.tick(seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let id = item.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let id, let currentItem = self.avPlayer.currentItem,
                      ObjectIdentifier(currentItem) == id else { return }
                self.didFinish()
            }
        }
        // KVO、seek 完成的回呼可能在背景執行緒，closure 一律 @Sendable，再切回主執行緒。
        controlObservation = avPlayer.observe(\.timeControlStatus) { @Sendable [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard let self, self.segmentPlayer == nil else { return }
                self.isBuffering = waiting
            }
        }
        nowPlaying.attach(self)
        applyVolume()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor in self?.checkStall() }
        }
    }

    // MARK: 卡住偵測

    /// 跳轉後偶爾會出現「狀態是播放中、速度正常、沒有在等緩衝，但時間不走」（自我測試大約每六次一次，
    /// 2026/11/11 抓到 rate=2 tcs=playing reason=nil，時間停在跳轉的位置）。時間 2.5 秒沒前進就在原位輕推一下。
    private func checkStall() {
        guard isPlaying, !isLoading, !isLive, segmentPlayer == nil, avPlayer.timeControlStatus == .playing else {
            stalledSince = nil
            return
        }
        let t = avPlayer.currentTime().seconds
        if abs(t - lastProgress) > 0.05 {
            lastProgress = t
            stalledSince = nil
            return
        }
        guard let since = stalledSince else {
            stalledSince = Date()
            return
        }
        if Date().timeIntervalSince(since) >= 2.5 {
            stalledSince = nil
            Task { await Self.nudge(avPlayer, rate: rate) }
        }
    }

    /// 在目前位置往後 0.05 秒重新跳一次再開播，讓卡住的播放管線重新起來。
    static func nudge(_ player: AVPlayer, rate: Float) async {
        let t = player.currentTime().seconds
        await player.seek(to: CMTime(seconds: t + 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: rate)
    }

    // MARK: 音量

    private func applyVolume() {
        avPlayer.volume = min(volume, 1)
        avPlayer.isMuted = silent
        Boost.gain = volume
        segmentPlayer?.silent = silent
        segmentPlayer?.volume = volume
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
        }
    }

    func changeVolume(by delta: Float) {
        volume = max(0, min(2, (volume + delta) * 10).rounded() / 10)
    }

    /// 備援：HLS 交給 AVPlayer 播的時候（`SegmentPlayer` 解不了這個格式）沒辦法放大，
    /// 所以背景下載音軌，下載好就從同一個位置切到本機檔。
    private func prepareBoost() {
        guard let ep = current, !canBoost, !isLive, boostTask == nil else { return }
        boostPending = true
        boostTask = Task {
            defer { boostTask = nil; boostPending = false }
            do {
                let cached = YTDLP.cachedStream(for: ep)
                let local = if let cached { cached } else { try await YTDLP.download(videoID: ep.id) }
                guard current?.id == ep.id, !isLocalPlayback else { return }
                resolved[ep.id] = local
                let wasPlaying = isPlaying
                isLoading = true
                start(local, at: position)
                if !wasPlaying { pendingPause = true }
                show(String(localized: "已切換成本機檔，可以放大音量"))
            } catch {
                guard current?.id == ep.id else { return }
                show(String(localized: "沒辦法放大音量：\(error.localizedDescription)"))
            }
        }
    }

    // MARK: 播放

    func play(_ ep: Episode) {
        if current != nil { history?.stop(at: position) }
        saveProgress(force: true)
        historyStarted = false
        boostTask?.cancel()
        boostTask = nil
        boostPending = false
        pendingPause = false
        isLocalPlayback = false
        canBoost = false
        segmentsUnsupported = false
        let token = UUID()
        loadToken = token
        library.remember(ep)
        current = ep
        isLoading = true
        isPlaying = false
        errorMessage = nil
        segments = []
        skipped = []
        retried = false
        isLive = ep.liveNow
        position = isLive ? 0 : library.resumePosition(for: ep)
        liveTime = 0
        liveWindow = nil
        liveDate = 0
        duration = isLive ? 0 : ep.duration ?? 0
        teardownItem()
        nowPlaying.update()
        Task {
            do {
                let stream = try await stream(for: ep.id)
                guard token == loadToken else { return }
                if stream.isLive {
                    isLive = true
                    duration = 0
                    position = 0
                } else if duration == 0, let d = stream.duration {
                    duration = d
                }
                start(stream, at: position)
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
            let categories = isLive ? [] : SponsorBlock.enabledCategories
            let found = await SponsorBlock.segments(videoID: ep.id, categories: categories)
            guard token == loadToken else { return }
            segments = found
        }
    }

    /// 貼上的影片網址：先用 yt-dlp 拿到標題和頻道，再照一般影片播。
    func playURL(_ raw: String) async throws {
        guard let id = ChannelInput.videoID(raw) else {
            throw YTDLPError.failed(String(localized: "看不懂這個影片網址。"))
        }
        if let known = library.episodes[id] {
            play(known)
            return
        }
        let stream = try await YTDLP.resolve(videoID: id)
        resolved[id] = stream
        let ep = Episode(id: id, title: stream.title, channelID: stream.channelID ?? "",
                         channelTitle: stream.channelTitle, duration: stream.duration, published: Date())
        play(ep)
    }

    private func stream(for id: String, fresh: Bool = false) async throws -> ResolvedStream {
        if !fresh, let cached = resolved[id], cached.isFresh { return cached }
        if let ep = library.episodes[id] ?? (current?.id == id ? current : nil), !ep.liveNow,
           let local = YTDLP.cachedStream(for: ep) {
            resolved[id] = local
            return local
        }
        let stream = try await YTDLP.resolve(videoID: id)
        resolved[id] = stream
        return stream
    }

    private func start(_ stream: ResolvedStream, at seconds: Double) {
        teardownItem()
        if let ep = current { subtitles?.attach(ep, stream) }
        liveLastTick = nil
        liveWindow = nil
        isLocalPlayback = stream.isLocal
        if Self.useSegments, !segmentsUnsupported, !stream.isLocal, !stream.isLive, !isLive {
            startSegments(stream, at: seconds)
            return
        }
        canBoost = stream.isLocal
        let asset = Self.makeAsset(stream)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        if stream.isLocal {
            Task {
                guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
                item.audioMix = Boost.makeAudioMix(for: track)
            }
        }
        item.preferredForwardBufferDuration = 120
        pendingSeek = seconds > 1 && !isLive ? seconds : nil
        statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, message) }
        }
        avPlayer.replaceCurrentItem(with: item)
    }

    static func makeAsset(_ stream: ResolvedStream) -> AVURLAsset {
        stream.isLocal
            ? AVURLAsset(url: stream.url)
            : AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
    }

    /// HLS 純音訊：自己抓分段、解碼、放大（見 `SegmentPlayer`）。開播位置直接交給它，不用等就緒再跳。
    private func startSegments(_ stream: ResolvedStream, at seconds: Double) {
        let engine = SegmentPlayer(stream: stream)
        engine.silent = silent
        engine.volume = volume
        engine.rate = rate
        engine.onReady = { [weak self, weak engine] length in
            guard let self, let engine, self.segmentPlayer === engine, self.isLoading else { return }
            self.isLoading = false
            if length > 0 { self.duration = length }
            if let target = self.pendingSeek {
                self.pendingSeek = nil
                engine.seek(to: target)
            }
            self.beginPlayback()
        }
        engine.onTick = { [weak self, weak engine] seconds in
            guard let self, self.segmentPlayer === engine else { return }
            // 有在前進就代表網址是好的，下次失敗可以再重新解析一次。
            if self.isPlaying, seconds > self.position { self.retried = false }
            self.tick(seconds)
        }
        engine.onBuffering = { [weak self, weak engine] waiting in
            guard let self, self.segmentPlayer === engine else { return }
            self.isBuffering = waiting
        }
        engine.onFinished = { [weak self, weak engine] in
            guard let self, self.segmentPlayer === engine else { return }
            self.didFinish()
        }
        engine.onFailed = { [weak self, weak engine] message, unsupported in
            guard let self, self.segmentPlayer === engine else { return }
            if unsupported {
                // 不是 ADTS 分段（例如哪天 YouTube 改格式）：這一集改用 AVPlayer。
                self.segmentsUnsupported = true
                self.start(stream, at: self.position)
            } else {
                self.playbackFailed(message)
            }
        }
        pendingSeek = nil
        canBoost = true
        segmentPlayer = engine
        engine.load(at: seconds)
    }

    private func teardownItem() {
        segmentPlayer?.stop()
        segmentPlayer = nil
        statusObservation = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, _ message: String?) {
        switch status {
        case .readyToPlay:
            guard isLoading else { return }
            isLoading = false
            if !isLive, let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
            if let target = pendingSeek {
                pendingSeek = nil
                avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { @Sendable [weak self] _ in
                    Task { @MainActor in self?.beginPlayback() }
                }
            } else {
                beginPlayback()
            }
        case .failed:
            playbackFailed(message)
        default:
            break
        }
    }

    /// 最常見的原因是網址過期：重新解析一次，從原本的位置接著播。
    private func playbackFailed(_ message: String?) {
        guard let ep = current else { return }
        if !retried {
            retried = true
            let token = loadToken
            let at = position
            isLoading = true
            Task {
                do {
                    let stream = try await stream(for: ep.id, fresh: true)
                    guard token == loadToken else { return }
                    start(stream, at: at)
                } catch {
                    guard token == loadToken else { return }
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            teardownItem()
            isLoading = false
            isPlaying = false
            errorMessage = message ?? String(localized: "播放失敗")
        }
    }

    private func engineSeek(_ seconds: Double) {
        if let segmentPlayer {
            segmentPlayer.seek(to: seconds)
        } else {
            avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func enginePlay() {
        if let segmentPlayer {
            segmentPlayer.rate = rate
            segmentPlayer.play()
        } else {
            avPlayer.playImmediately(atRate: isLive ? 1 : rate)
        }
    }

    private func beginPlayback() {
        if pendingPause {
            // 暫停中切到本機檔：位置到了就停著，不要自己開始播。
            pendingPause = false
            isPlaying = false
            nowPlaying.update()
            return
        }
        enginePlay()
        isPlaying = true
        if volume > 1 { prepareBoost() }
        if let ep = current, !historyStarted {
            historyStarted = true
            history?.start(videoID: ep.id, at: position)
        } else {
            history?.resumed(at: position)
        }
        nowPlaying.update()
        prefetchNext()
    }

    /// 先把待播清單下一集的網址解好，換集時省掉 yt-dlp 的 2 秒多。
    func prefetchNext() {
        let next = library.queue.first { $0 != current?.id }
        prefetch(next.map { [$0] } ?? [])
    }

    func prefetch(_ ids: [String]) {
        for id in ids where !(resolved[id]?.isFresh ?? false) {
            Task {
                if let stream = try? await YTDLP.resolve(videoID: id) { resolved[id] = stream }
            }
        }
    }

    func toggle() {
        guard let ep = current else { return }
        if isPlaying {
            pause()
        } else if avPlayer.currentItem == nil && segmentPlayer == nil {
            play(ep)
        } else if isLive && !canSeekLive {
            // 不能回放的直播：暫停再播一律接最新的。
            goLive()
        } else {
            // 暫停太久，停的地方已經滑出回放窗口：從窗口裡最舊的地方接。
            if isLive, let window = currentLiveWindow(), avPlayer.currentTime().seconds < window.lowerBound + 5 {
                avPlayer.seek(to: CMTime(seconds: window.lowerBound + 10, preferredTimescale: 600))
            }
            enginePlay()
            isPlaying = true
            history?.resumed(at: position)
            nowPlaying.update()
        }
    }

    func resume() {
        if !isPlaying { toggle() }
    }

    func pause() {
        guard isPlaying else { return }
        avPlayer.pause()
        segmentPlayer?.pause()
        isPlaying = false
        history?.paused(at: position)
        saveProgress(force: true)
        nowPlaying.update()
    }

    func skip(_ delta: Double) {
        if isLive {
            seekLive(to: liveTime + delta)
        } else {
            seek(to: position + delta)
        }
    }

    // MARK: 直播

    private func currentLiveWindow() -> ClosedRange<Double>? {
        guard let range = avPlayer.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let start = range.start.seconds, end = range.end.seconds
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return start...end
    }

    /// 在回放窗口裡跳轉（AVPlayer 的時間）。窗口不夠長的直播不能拉。
    func seekLive(to seconds: Double) {
        guard isLive, !isLoading, segmentPlayer == nil else { return }
        liveWindow = currentLiveWindow() ?? liveWindow
        guard canSeekLive, let window = liveWindow else { return }
        let target = min(max(seconds, window.lowerBound + 5), window.upperBound)
        liveTime = target
        liveLastTick = nil
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        nowPlaying.update()
    }

    /// 跳回最新的地方；暫停中也順便開始播。
    func goLive() {
        guard isLive, !isLoading, segmentPlayer == nil else { return }
        liveWindow = currentLiveWindow() ?? liveWindow
        if let end = liveWindow?.upperBound {
            liveTime = end
            liveLastTick = nil
            avPlayer.seek(to: CMTime(seconds: end, preferredTimescale: 600))
        }
        if !isPlaying {
            enginePlay()
            isPlaying = true
            history?.resumed(at: position)
        }
        nowPlaying.update()
    }

    func seek(to seconds: Double) {
        guard current != nil, !isLive else { return }
        let upper = duration > 0 ? duration - 1 : seconds
        let target = max(0, min(seconds, upper))
        if isPlaying { history?.seeked(from: position, to: target) }
        position = target
        if isLoading {
            pendingSeek = target
        } else {
            engineSeek(target)
        }
        // 往回拉到跳過片段之前，再經過時要重新跳。
        skipped = skipped.filter { $0.start < target }
        saveProgress(force: true)
        nowPlaying.update()
    }

    func playNext() {
        if let next = library.popQueue(excluding: current?.id) { play(next) }
    }

    func cycleRate(_ step: Int) {
        let index = Self.rates.firstIndex(where: { $0 >= rate - 0.01 }) ?? 0
        rate = Self.rates[max(0, min(Self.rates.count - 1, index + step))]
    }

    // MARK: 進度

    private func tick(_ seconds: Double) {
        guard current != nil, !isLoading, seconds.isFinite else { return }
        if isLive {
            if isPlaying, let last = liveLastTick, seconds > last, seconds - last < 2 { position += seconds - last }
            liveLastTick = seconds
            liveTime = seconds
            liveWindow = currentLiveWindow()
            liveDate = avPlayer.currentItem?.currentDate()?.timeIntervalSince1970 ?? 0
            history?.tick(at: seconds, playing: isPlaying)
            return
        }
        position = seconds
        history?.tick(at: seconds, playing: isPlaying)
        if isPlaying, !isLive, let seg = segments.first(where: { seconds >= $0.start && seconds < $0.end - 0.5 && !skipped.contains($0) }) {
            skipped.insert(seg)
            history?.seeked(from: seconds, to: seg.end)
            engineSeek(seg.end)
            position = seg.end
            show(String(localized: "已跳過\(seg.label) \(Format.time(seg.end - seg.start))"))
            nowPlaying.update()
        }
        saveProgress(force: false)
    }

    func saveProgress(force: Bool) {
        guard let ep = current, !isLoading, !isLive else { return }
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        if duration > 0, position >= duration - 15 { return }
        library.setProgress(ep.id, position)
    }

    private func didFinish() {
        guard let ep = current else { return }
        history?.stop(at: duration)
        library.markFinished(ep.id)
        isPlaying = false
        position = duration
        nowPlaying.update()
        playNext()
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }
}
