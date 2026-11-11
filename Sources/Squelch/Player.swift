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
    /// 0～2。超過 1 的部分由 `Boost` 放大，只對本機檔有效。
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
    @ObservationIgnored private var volumeBeforeMute: Float = 1
    @ObservationIgnored private var boostTask: Task<Void, Never>?
    var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: "rate")
            if isPlaying && !isLive { avPlayer.rate = rate }
            nowPlaying.update()
        }
    }

    @ObservationIgnored let library: Library
    /// 登入時回報播放紀錄；沒登入時 `WatchHistory` 自己什麼都不做。
    @ObservationIgnored var history: WatchHistory?
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

    init(library: Library) {
        self.library = library
        let saved = UserDefaults.standard.float(forKey: "rate")
        rate = saved > 0 ? saved : 1
        let savedVolume = UserDefaults.standard.object(forKey: "volume") as? Float
        volume = savedVolume ?? 1
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
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
            Task { @MainActor in self?.isBuffering = waiting }
        }
        nowPlaying.attach(self)
        applyVolume()
    }

    // MARK: 音量

    private func applyVolume() {
        avPlayer.volume = min(volume, 1)
        Boost.gain = volume
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

    /// 放大只能用在本機檔。正在播 HLS 時，背景下載音軌，下載好就從同一個位置切過去。
    private func prepareBoost() {
        guard let ep = current, !isLocalPlayback, !isLive, boostTask == nil else { return }
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
                show("已切換成本機檔，可以放大音量")
            } catch {
                guard current?.id == ep.id else { return }
                show("沒辦法放大音量：\(error.localizedDescription)")
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
            throw YTDLPError.failed("看不懂這個影片網址。")
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
        let asset = Self.makeAsset(stream)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        isLocalPlayback = stream.isLocal
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

    private func teardownItem() {
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
            // 最常見的原因是網址過期：重新解析一次，從原本的位置接著播。
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
                isLoading = false
                isPlaying = false
                errorMessage = message ?? "播放失敗"
            }
        default:
            break
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
        avPlayer.playImmediately(atRate: isLive ? 1 : rate)
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
        } else if avPlayer.currentItem == nil {
            play(ep)
        } else {
            avPlayer.playImmediately(atRate: isLive ? 1 : rate)
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
        isPlaying = false
        history?.paused(at: position)
        saveProgress(force: true)
        nowPlaying.update()
    }

    func skip(_ delta: Double) {
        seek(to: position + delta)
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
            avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
        position = seconds
        history?.tick(at: seconds, playing: isPlaying)
        if isPlaying, !isLive, let seg = segments.first(where: { seconds >= $0.start && seconds < $0.end - 0.5 && !skipped.contains($0) }) {
            skipped.insert(seg)
            history?.seeked(from: seconds, to: seg.end)
            avPlayer.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            position = seg.end
            show("已跳過\(seg.label) \(Format.time(seg.end - seg.start))")
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
