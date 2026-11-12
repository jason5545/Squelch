import AVFoundation
import CoreMedia
import Foundation

/// HLS 純音訊的自己解碼播放。
///
/// AVPlayer 播 HLS 時沒辦法在音訊路徑上加增益（`MTAudioProcessingTap` 不會被呼叫），音量最大就是 100%。
/// 但 YouTube 的 HLS 純音訊（itag 234／233）分段其實是「ID3 標籤 + ADTS AAC」，每段約 5 秒、80 KB，
/// 系統內建的解碼器直接認得（2026/11/11 實測兩個頻道）。所以這裡自己抓分段、解成 PCM、放大，
/// 再交給 `AVSampleBufferAudioRenderer`：變速照樣由系統做（跟 AVPlayer 同一個 time-domain 演算法），
/// 拉過 100% 不用下載整個音軌，也不用切換播放來源。
///
/// 只處理「有結尾的播放清單 + ADTS 分段」。其他格式（直播、fMP4、加密）回報 `unsupported`，由 `Player` 退回 AVPlayer。

nonisolated enum SegmentError: LocalizedError {
    /// 不是這裡會解的格式。呼叫端退回 AVPlayer。
    case unsupported(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unsupported(let why): why
        case .http(let code): String(localized: "音軌讀取失敗（HTTP \(code)）")
        }
    }

    /// 網址過期或被拒絕：重試沒用，要重新解析網址。其他狀態碼（429、5xx）等一下再試。
    var isFatal: Bool {
        switch self {
        case .unsupported: true
        case .http(let code): code == 403 || code == 404 || code == 410
        }
    }
}

nonisolated struct SegmentPlaylist: Sendable {
    struct Segment: Sendable {
        let url: URL
        let start: Double
        let duration: Double
    }

    let segments: [Segment]

    var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }

    /// 分段的起點用 `#EXTINF` 累加。跟分段裡 ID3 的時間戳比過（2026/11/11，48 分鐘的影片取 5 段），最多差 22 毫秒。
    static func parse(_ text: String, baseURL: URL) throws -> SegmentPlaylist {
        guard text.hasPrefix("#EXTM3U") else { throw SegmentError.unsupported("not an HLS playlist") }
        for tag in ["#EXT-X-STREAM-INF", "#EXT-X-MAP", "#EXT-X-KEY", "#EXT-X-BYTERANGE"] where text.contains(tag) {
            throw SegmentError.unsupported("playlist uses \(tag)")
        }
        guard text.contains("#EXT-X-ENDLIST") else { throw SegmentError.unsupported("playlist has no end (live)") }
        var segments: [Segment] = []
        var start = 0.0
        var pending: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pending,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                segments.append(Segment(url: url, start: start, duration: duration))
                start += duration
                pending = nil
            }
        }
        guard !segments.isEmpty else { throw SegmentError.unsupported("playlist has no segments") }
        return SegmentPlaylist(segments: segments)
    }

    /// 包含這個時間的分段（起點不晚於它的最後一段）。
    func index(at seconds: Double) -> Int {
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].start <= seconds { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// ADTS：每個 AAC frame 前面有 7 或 9 個位元組的標頭，寫著取樣率、聲道數和這個 frame 的長度。
nonisolated enum ADTS {
    struct Format: Equatable, Sendable {
        var sampleRate: Double
        var channels: Int
    }

    struct Parsed {
        var format: Format
        /// 每個 AAC frame（不含標頭）在資料裡的位置。
        var packets: [Range<Int>]
    }

    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// 開頭的 ID3 標籤跳過。不是 ADTS、或格式中途改變就回 nil。
    static func parse(_ data: Data) -> Parsed? {
        data.withUnsafeBytes { raw -> Parsed? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 10 <= bytes.count, bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 {
                let size = (Int(bytes[i + 6]) << 21) | (Int(bytes[i + 7]) << 14) | (Int(bytes[i + 8]) << 7) | Int(bytes[i + 9])
                i += 10 + size
            }
            var format: Format?
            var packets: [Range<Int>] = []
            while i + 7 <= bytes.count {
                guard bytes[i] == 0xFF, bytes[i + 1] & 0xF6 == 0xF0 else { return nil }
                let header = bytes[i + 1] & 1 == 1 ? 7 : 9
                let rateIndex = Int(bytes[i + 2] >> 2) & 0xF
                let channels = (Int(bytes[i + 2] & 1) << 2) | Int(bytes[i + 3] >> 6)
                let length = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5]) >> 5)
                // 一個 ADTS frame 裡放不只一個 AAC frame 的寫法很少見，不處理。
                guard rateIndex < sampleRates.count, length > header, bytes[i + 6] & 0x03 == 0 else { return nil }
                if i + length > bytes.count { break }   // 結尾被截斷
                let found = Format(sampleRate: sampleRates[rateIndex], channels: channels)
                if format == nil { format = found } else if format != found { return nil }
                packets.append((i + header)..<(i + length))
                i += length
            }
            guard let format, !packets.isEmpty, (1...2).contains(format.channels) else { return nil }
            return Parsed(format: format, packets: packets)
        }
    }
}

/// ADTS AAC → 交錯的 Float32 PCM。分段要照順序餵：解碼器的狀態跨分段連續，分段邊界才不會有斷點。
/// 跳轉後換一個新的。
nonisolated final class SegmentDecoder {
    let format: ADTS.Format
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    init?(format: ADTS.Format) {
        var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         channels: AVAudioChannelCount(format.channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.format = format
        self.input = input
        self.output = output
        self.converter = converter
    }

    var streamDescription: AudioStreamBasicDescription { output.streamDescription.pointee }

    func decode(_ data: Data, packets: [Range<Int>]) -> [Float] {
        guard let largest = packets.map(\.count).max(), largest > 0 else { return [] }
        let buffer = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(packets.count), maximumPacketSize: largest)
        guard let descriptions = buffer.packetDescriptions else { return [] }
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (n, range) in packets.enumerated() {
                (buffer.data + offset).copyMemory(from: base + range.lowerBound, byteCount: range.count)
                descriptions[n] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                               mDataByteSize: UInt32(range.count))
                offset += range.count
            }
        }
        buffer.byteLength = UInt32(offset)
        buffer.packetCount = AVAudioPacketCount(packets.count)
        return run(buffer, expecting: packets.count * 1024)
    }

    /// 最後一段解完後呼叫，把解碼器裡剩下的吐出來。之後這個解碼器不能再用。
    func finish() -> [Float] {
        run(nil, expecting: 4096)
    }

    private func run(_ source: AVAudioCompressedBuffer?, expecting frames: Int) -> [Float] {
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16384) else { return [] }
        var result: [Float] = []
        result.reserveCapacity((frames + 2048) * format.channels)
        var pending = source
        let atEnd = source == nil
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let buffer = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                // 這一段餵完了，下一段還會來：不要回 endOfStream，解碼器的狀態要留著。
                inputStatus.pointee = atEnd ? .endOfStream : .noDataNow
                return nil
            }
            let count = Int(out.frameLength) * format.channels
            if count > 0, let samples = out.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }
            if status != .haveData || count == 0 || error != nil { break }
        }
        return result
    }
}

final class SegmentPlayer {
    struct Stats {
        /// 從頭開始送音訊的次數（開播、跳轉）。
        var restarts = 0
        /// 改增益時，把還沒播的音訊換成新增益的次數。
        var rebakes = 0
        /// 上面那件事沒成功、改成整個重送的次數。
        var rebakeFallbacks = 0
        var underruns = 0
        var segmentsFetched = 0
    }

    /// 第一段音訊解出來了，參數是整部的長度。
    var onReady: ((Double) -> Void)?
    /// 播放中每半秒一次。
    var onTick: ((Double) -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    /// `unsupported`：格式不是這裡會解的，換 AVPlayer 播。否則是網址過期之類，要重新解析。
    var onFailed: ((_ message: String, _ unsupported: Bool) -> Void)?

    private(set) var stats = Stats()

    /// 0～2。1 以下交給 renderer 的音量（立刻生效）；超過 1 的部分在送進 renderer 之前乘上去，再過柔性限幅。
    ///
    /// 送進去的音訊改不了，所以改增益時要把排隊中、還沒播的換掉。renderer 內部已經取走約 1～1.5 秒
    /// （2026/11/11 實測：替換點排在 1 秒後會失敗、1.5 秒後成功，1～3 倍速都一樣），所以：
    /// - 往上調：新的增益大約 1.6 秒（影片時間）後才聽得到，2 倍速就是 0.8 秒。
    /// - 往下調：舊增益的音訊還在播的這段時間，先把 renderer 的音量按比例壓低，聽起來立刻生效。
    var volume: Float = 1 { didSet { applyVolume() } }
    /// 自我測試用：不出聲，其他照常。
    var silent = false { didSet { refreshVolume() } }
    var rate: Float = 1 {
        didSet { if !holding { synchronizer.rate = rate } }
    }
    /// 新送進 renderer 的音訊用的增益（1 以上）。
    private(set) var gain: Float = 1

    /// 送進 renderer、還沒播的音訊至少要有這麼多（實際時間，秒）。
    private static let lookahead = 10.0
    /// 分段先抓到多遠（實際時間，秒）。
    private static let fetchAhead = 120.0
    private static let maxFetches = 4
    private static let cacheLimit = 96 * 1024 * 1024
    /// 改增益時，離現在多遠之後的音訊才換掉：影片時間 1.6 秒，再加實際時間 0.15 秒（處理的延遲）。太近 renderer 會拒絕。
    private static let rebakeMargin = 1.6
    private static let rebakeSlack = 0.15

    private struct Chunk {
        var pts: Int64          // 第一個取樣在整部影片裡的位置（取樣數）
        var samples: [Float]    // 交錯、還沒放大
        var frames: Int
        var end: Int64 { pts + Int64(frames) }
    }

    private let stream: ResolvedStream
    private let session: URLSession
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var flushObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    private var playlist: SegmentPlaylist?
    private var cache: [Int: Data] = [:]
    private var cacheBytes = 0
    private var fetching: Set<Int> = []

    private var decoder: SegmentDecoder?
    private var formatDescription: CMAudioFormatDescription?
    private var sampleRate = 44100.0
    private var channels = 2
    /// 這次開始的位置（秒）。解碼器建好之前，時間以它為準。
    private var anchor = 0.0
    private var nextSegment = 0
    private var chunks: [Chunk] = []
    private var decodedEnd: Int64 = 0
    private var enqueuedEnd: Int64 = 0
    private var trimBefore: Int64 = 0
    private var fadeIn = false
    /// 解碼器建好、時間軸定下來了。
    private var primed = false
    private var reachedEnd = false
    private var finished = false
    private var readyReported = false
    private var failed = false
    private var stopped = false

    private var wantsPlay = false
    /// 時間停著：暫停、緩衝中、還沒開始。
    private var holding = true
    private var buffering = false
    /// 送進 renderer 的最後一塊用的增益。跟 `gain` 不同時，下一塊的開頭用 20 毫秒漸變過去。
    private var tailGain: Float = 1
    /// 排隊中的音訊從哪個取樣開始用哪個增益，由早到晚。第一筆是正在播的。
    private var gainMarks: [(from: Int64, gain: Float)] = []
    private var boundaryObservers: [Any] = []
    private var flushPending = false
    private var rebakeAgain = false
    private var rebakeTask: Task<Void, Never>?
    /// 每次整個重送就加一，讓還在路上的 flush 回呼失效。
    private var epoch = 0

    private var pumpTask: Task<Void, Never>?
    private var pumping = false
    private var repump = false
    private var events: [() -> Void] = []
    private var pumpCount = 0

    init(stream: ResolvedStream) {
        self.stream = stream
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = Self.maxFetches
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        renderer.audioTimePitchAlgorithm = .timeDomain
        // `delaysRateChangeUntilHasSufficientMediaData` 留預設的 true：關掉的話起播快 0.4 秒（2026/11/11 實測），
        // 但那是時間先走、聲音還沒出來，開頭會被吃掉。
        synchronizer.addRenderer(renderer)
        // 換輸出裝置之類的情況，renderer 會自己把排好的音訊清掉，要從現在的位置重送。
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.resync()
                self.pump()
            }
        }
    }

    // MARK: 對外

    var currentTime: Double {
        let t = synchronizer.currentTime().seconds
        return t.isFinite ? max(0, t) : anchor
    }

    var isBuffering: Bool { buffering }

    /// 正在播的那段音訊用的增益。
    var playingGain: Float { gainMarks.first?.gain ?? gain }

    /// 現在實際聽到的音量倍率（不管 `silent`）：正在播的增益 × renderer 的音量。
    var effectiveVolume: Float { playingGain * rendererVolume }

    private var rendererVolume: Float {
        let base = min(max(volume, 0), 1)
        // 正在播的是用比較大的舊增益算的：新的還沒輪到之前，用 renderer 的音量補回來。
        let playing = playingGain
        return playing > 1.0001 ? base * min(1, gain / playing) : base
    }

    /// 診斷用：自我測試失敗時印出來。
    var debugState: String {
        let now = currentSample
        return "t=\(String(format: "%.2f", currentTime)) syncRate=\(synchronizer.rate) rate=\(rate) holding=\(holding) wantsPlay=\(wantsPlay) "
            + "primed=\(primed) queued=\(String(format: "%.2f", Double(enqueuedEnd - now) / sampleRate))s "
            + "decoded=\(String(format: "%.2f", Double(decodedEnd - now) / sampleRate))s chunks=\(chunks.count) next=\(nextSegment) "
            + "cached=\(cache.count) fetching=\(fetching.sorted()) ready=\(renderer.isReadyForMoreMediaData) status=\(renderer.status.rawValue) "
            + "flushPending=\(flushPending) reachedEnd=\(reachedEnd) finished=\(finished) failed=\(failed) stats=\(stats)"
    }

    func load(at seconds: Double) {
        anchor = max(0, seconds)
        synchronizer.setRate(0, time: CMTime(seconds: anchor, preferredTimescale: 44100))
        let request = request(for: stream.url)
        let session = session
        let base = stream.url
        Task { [weak self] in
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw SegmentError.http(http.statusCode)
                }
                let list = try SegmentPlaylist.parse(String(decoding: data, as: UTF8.self), baseURL: base)
                guard let self, !self.stopped else { return }
                self.playlist = list
                self.restart(at: self.anchor)
                self.startPumping()
            } catch SegmentError.unsupported(let why) {
                self?.fail(why, unsupported: true)
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func play() {
        guard !stopped, !failed, !finished else { return }
        wantsPlay = true
        if activity == nil {
            // 背景時計時器不要被 App Nap 拖慢；不擋系統閒置睡眠（有聲音在播時系統本來就不會睡）。
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing audio")
        }
        pump()
    }

    func pause() {
        wantsPlay = false
        hold()
        setBuffering(false)
        endActivity()
    }

    func seek(to seconds: Double) {
        guard !stopped, !failed else { return }
        restart(at: seconds)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pumpTask?.cancel()
        rebakeTask?.cancel()
        clearGainMarks()
        synchronizer.rate = 0
        renderer.flush()
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        flushObserver = nil
        endActivity()
        session.invalidateAndCancel()
        events.removeAll()
        chunks.removeAll()
        cache.removeAll()
    }

    // MARK: 時間

    private func time(_ sample: Int64) -> CMTime {
        CMTime(value: sample, timescale: CMTimeScale(sampleRate))
    }

    private var currentSample: Int64 {
        Int64((currentTime * sampleRate).rounded())
    }

    private func hold() {
        if !holding { synchronizer.rate = 0 }
        holding = true
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: 回呼

    /// 回呼裡可能再呼叫 `seek`、`play`，所以狀態都整理完才叫。
    private func emit(_ event: @escaping () -> Void) {
        if pumping { events.append(event) } else { event() }
    }

    private func setBuffering(_ value: Bool) {
        guard buffering != value else { return }
        buffering = value
        emit { [weak self] in self?.onBuffering?(value) }
    }

    private func fail(_ message: String, unsupported: Bool = false) {
        guard !failed, !stopped else { return }
        failed = true
        wantsPlay = false
        hold()
        endActivity()
        emit { [weak self] in self?.onFailed?(message, unsupported) }
    }

    // MARK: 從某個位置重新開始

    private func restart(at seconds: Double) {
        guard let playlist else {
            anchor = max(0, seconds)
            return
        }
        anchor = max(0, min(seconds, playlist.duration))
        stats.restarts += 1
        epoch += 1
        flushPending = false
        rebakeAgain = false
        renderer.flush()
        synchronizer.setRate(0, time: CMTime(seconds: anchor, preferredTimescale: 44100))
        holding = true
        chunks.removeAll(keepingCapacity: true)
        decoder = nil
        primed = false
        reachedEnd = false
        finished = false
        nextSegment = playlist.index(at: anchor)
        clearGainMarks()
        pump()
    }

    /// renderer 把排好的音訊清掉了，或換增益沒成功：從現在的位置重送。手上還有這段的 PCM 就不用重新解碼。
    private func resync() {
        let now = currentSample
        guard primed, let first = chunks.first, first.pts <= now, decodedEnd > now else {
            restart(at: currentTime)
            return
        }
        epoch += 1
        flushPending = false
        rebakeAgain = false
        renderer.flush()
        synchronizer.setRate(0, time: time(now))
        holding = true
        enqueuedEnd = now
        clearGainMarks()
    }

    // MARK: 主迴圈

    private func startPumping() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                self.pump()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func pump() {
        if pumping {
            repump = true
            return
        }
        pumping = true
        repeat {
            repump = false
            pumpOnce()
        } while repump
        pumping = false
        let pending = events
        events.removeAll()
        for event in pending where !stopped { event() }
    }

    private func pumpOnce() {
        guard !stopped, !failed, let playlist else { return }
        if primed {
            // 播過的丟掉，留半秒：換增益沒成功時要從現在的位置重送。
            let keepFrom = currentSample - Int64(sampleRate / 2)
            chunks.removeAll { $0.end <= keepFrom }
        }
        let ahead = Int64(Double(max(1, rate)) * Self.lookahead * sampleRate)
        while !reachedEnd, !failed, !primed || decodedEnd - currentSample < ahead, let data = cache[nextSegment] {
            decodeNext(data, playlist)
        }
        guard !failed else { return }
        refreshVolume()
        enqueuePending()
        scheduleFetches(playlist)
        updateTransport()
        pumpCount += 1
        if !holding, pumpCount % 5 == 0 {
            let now = currentTime
            emit { [weak self] in self?.onTick?(now) }
        }
    }

    private func decodeNext(_ data: Data, _ playlist: SegmentPlaylist) {
        guard let parsed = ADTS.parse(data) else {
            fail("segment \(nextSegment) is not ADTS AAC", unsupported: true)
            return
        }
        if decoder == nil {
            guard let created = SegmentDecoder(format: parsed.format) else {
                fail("no decoder for \(parsed.format)", unsupported: true)
                return
            }
            if formatDescription == nil || sampleRate != parsed.format.sampleRate || channels != parsed.format.channels {
                var asbd = created.streamDescription
                var description: CMAudioFormatDescription?
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                               formatDescriptionOut: &description)
                formatDescription = description
            }
            decoder = created
            sampleRate = parsed.format.sampleRate
            channels = parsed.format.channels
            decodedEnd = Int64((playlist.segments[nextSegment].start * sampleRate).rounded())
            trimBefore = max(decodedEnd, Int64((anchor * sampleRate).rounded()))
            enqueuedEnd = trimBefore
            fadeIn = true
            primed = true
        } else if decoder?.format != parsed.format {
            fail("audio format changed mid-stream", unsupported: true)
            return
        }
        guard let decoder else { return }
        var pcm = decoder.decode(data, packets: parsed.packets)
        nextSegment += 1
        if nextSegment >= playlist.segments.count {
            pcm += decoder.finish()
            reachedEnd = true
        }
        append(pcm)
        if !readyReported {
            readyReported = true
            let duration = playlist.duration
            emit { [weak self] in self?.onReady?(duration) }
        }
    }

    /// 解出來的 PCM 切成四分之一秒一塊。起點之前的丟掉，起點的前 5 毫秒做淡入，免得從波形中間開始有爆音。
    private func append(_ pcm: [Float]) {
        let total = pcm.count / channels
        var offset = 0
        if decodedEnd < trimBefore {
            offset = min(total, Int(trimBefore - decodedEnd))
            decodedEnd += Int64(offset)
        }
        let chunkFrames = max(1024, Int(sampleRate / 4))
        while offset < total {
            let frames = min(chunkFrames, total - offset)
            var samples = Array(pcm[(offset * channels)..<((offset + frames) * channels)])
            if fadeIn {
                fadeIn = false
                let ramp = min(frames, Int(sampleRate * 0.005))
                for f in 0..<ramp {
                    let g = Float(f) / Float(ramp)
                    for c in 0..<channels { samples[f * channels + c] *= g }
                }
            }
            chunks.append(Chunk(pts: decodedEnd, samples: samples, frames: frames))
            decodedEnd += Int64(frames)
            offset += frames
        }
    }

    private func enqueuePending() {
        guard primed, !flushPending, let formatDescription else { return }
        // 不看 `isReadyForMoreMediaData`：renderer 大約排滿 1 秒就說不用再給（2026/11/11 實測），
        // 3 倍速時只夠撐 0.3 秒，主執行緒稍微忙一下就會斷。要排多少由 `lookahead` 決定，解碼那邊已經照它設了上限。
        for chunk in chunks where chunk.end > enqueuedEnd {
            let skip = Int(max(0, enqueuedEnd - chunk.pts))
            let frames = chunk.frames - skip
            var samples = skip == 0 ? chunk.samples : Array(chunk.samples[(skip * channels)...])
            applyGain(&samples, frames: frames, pts: chunk.pts + Int64(skip))
            guard let buffer = Self.makeBuffer(samples, frames: frames, pts: time(chunk.pts + Int64(skip)),
                                               format: formatDescription) else {
                fail("cannot build audio buffer")
                return
            }
            renderer.enqueue(buffer)
            enqueuedEnd = chunk.end
        }
    }

    private func applyGain(_ samples: inout [Float], frames: Int, pts: Int64) {
        let from = tailGain, to = gain
        tailGain = to
        if gainMarks.isEmpty {
            gainMarks = [(pts, to)]
            refreshVolume()
        } else if abs(from - to) > 0.0005 {
            gainMarks.append((pts, to))
            // 播到這裡的那一刻要把 renderer 的音量調回來，等主迴圈（0.1 秒一次）會慢半拍。
            let token = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: time(pts))], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.refreshVolume() }
            }
            boundaryObservers.append(token)
        }
        guard from > 1.0001 || to > 1.0001 else { return }
        let ramp = abs(from - to) > 0.0005 ? min(frames, Int(sampleRate * 0.02)) : 0
        let channels = channels
        samples.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for f in 0..<ramp {
                let g = from + (to - from) * Float(f) / Float(ramp)
                for c in 0..<channels { p[f * channels + c] = Boost.shape(p[f * channels + c] * g) }
            }
            let done = ramp * channels
            Boost.process(base + done, count: p.count - done, gain: to)
        }
    }

    private static func makeBuffer(_ samples: [Float], frames: Int, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil,
                                                                   sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    /// 開始走、進緩衝、播完，都在這裡決定。
    private func updateTransport() {
        guard primed else {
            if wantsPlay { setBuffering(true) }
            return
        }
        let now = currentSample
        let queued = Double(enqueuedEnd - now) / sampleRate
        let drained = reachedEnd && enqueuedEnd >= decodedEnd
        if drained, queued <= 0.05 {
            if !finished {
                finished = true
                wantsPlay = false
                hold()
                setBuffering(false)
                endActivity()
                emit { [weak self] in self?.onFinished?() }
            }
            return
        }
        guard wantsPlay else { return }
        let speed = Double(max(1, rate))
        if holding {
            if !flushPending, queued >= 0.5 * speed || drained {
                synchronizer.rate = rate
                holding = false
                setBuffering(false)
            } else {
                setBuffering(true)
            }
        } else if queued < 0.1 * speed, !drained {
            // 音訊快用完了（網路慢）：停在這裡等，不要讓時間空轉過去。
            stats.underruns += 1
            if queued <= 0 {
                synchronizer.setRate(0, time: time(enqueuedEnd))
            } else {
                synchronizer.rate = 0
            }
            holding = true
            setBuffering(true)
        }
    }

    // MARK: 增益

    private func clearGainMarks() {
        for token in boundaryObservers { synchronizer.removeTimeObserver(token) }
        boundaryObservers.removeAll()
        gainMarks.removeAll()
        tailGain = gain
    }

    /// 播過的增益標記丟掉，再照正在播的增益設 renderer 的音量。
    private func refreshVolume() {
        if gainMarks.count > 1 {
            let now = currentSample
            while gainMarks.count > 1, gainMarks[1].from <= now { gainMarks.removeFirst() }
            if gainMarks.count == 1 {
                for token in boundaryObservers { synchronizer.removeTimeObserver(token) }
                boundaryObservers.removeAll()
            }
        }
        renderer.volume = silent ? 0 : rendererVolume
    }

    private func applyVolume() {
        let wanted = max(volume, 1)
        guard abs(wanted - gain) > 0.0005 else {
            refreshVolume()
            return
        }
        gain = wanted
        refreshVolume()
        // 拖滑桿時值會連續變，稍微等一下再換。
        rebakeTask?.cancel()
        rebakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.rebake()
        }
    }

    /// 已經送進 renderer、還沒播的音訊是用舊增益算的。把替換點之後的清掉，用新增益重送，播放不中斷。
    /// 清不掉（離現在太近）就整個重送，會斷大約半秒。
    private func rebake() {
        guard primed, !stopped, !failed else { return }
        if flushPending {
            rebakeAgain = true
            return
        }
        let now = currentSample
        if holding {
            guard queuedGainDiffers(after: now) else { return }
            renderer.flush()
            enqueuedEnd = max(now, chunks.first?.pts ?? now)
            clearGainMarks()
            pump()
            return
        }
        // 替換點對齊到某一塊的開頭：每一塊是一個 sample buffer，從 buffer 中間切會不會留下前半塊，文件沒寫。
        let earliest = now + Int64((Self.rebakeMargin + Double(max(1, rate)) * Self.rebakeSlack) * sampleRate)
        guard let target = chunks.first(where: { $0.pts >= earliest })?.pts, target < enqueuedEnd,
              queuedGainDiffers(after: target) else {
            return   // 那之後還沒送（之後送的自然用新增益），或排隊中的已經是新增益
        }
        flushPending = true
        stats.rebakes += 1
        let epoch = epoch
        renderer.flush(fromSourceTime: time(target)) { @Sendable [weak self] succeeded in
            Task { @MainActor in self?.rebakeFlushed(succeeded, target: target, epoch: epoch) }
        }
    }

    /// 排隊中、`sample` 之後還會播到的音訊，有沒有哪一段不是現在要的增益。
    /// 不能只看最後送進去的那一塊：改完音量到這裡之間可能剛好又送了一塊新的。
    private func queuedGainDiffers(after sample: Int64) -> Bool {
        for (index, mark) in gainMarks.enumerated() {
            let end = index + 1 < gainMarks.count ? gainMarks[index + 1].from : enqueuedEnd
            if end > sample, abs(mark.gain - gain) > 0.0005 { return true }
        }
        return false
    }

    private func rebakeFlushed(_ succeeded: Bool, target: Int64, epoch: Int) {
        guard epoch == self.epoch, !stopped else { return }
        flushPending = false
        if succeeded {
            enqueuedEnd = target
            gainMarks.removeAll { $0.from >= target }
            tailGain = gainMarks.last?.gain ?? gain
        } else {
            stats.rebakeFallbacks += 1
            resync()
        }
        if rebakeAgain {
            rebakeAgain = false
            rebake()
        }
        pump()
    }

    // MARK: 抓分段

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    private func isWanted(_ index: Int, _ playlist: SegmentPlaylist) -> Bool {
        index >= nextSegment - 1 && playlist.segments[index].start < currentTime + Double(max(1, rate)) * Self.fetchAhead + 60
    }

    private func scheduleFetches(_ playlist: SegmentPlaylist) {
        let horizon = currentTime + Double(max(1, rate)) * Self.fetchAhead
        var index = nextSegment
        while index < playlist.segments.count, fetching.count < Self.maxFetches,
              index == nextSegment || playlist.segments[index].start < horizon {
            if cache[index] == nil, !fetching.contains(index) { fetch(index, playlist) }
            index += 1
        }
    }

    private func fetch(_ index: Int, _ playlist: SegmentPlaylist) {
        fetching.insert(index)
        let request = request(for: playlist.segments[index].url)
        let session = session
        Task { [weak self] in
            var delay = 0.5
            while true {
                do {
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw SegmentError.http(http.statusCode)
                    }
                    guard let self, !self.stopped else { return }
                    self.fetching.remove(index)
                    self.store(index, data)
                    self.pump()
                    return
                } catch {
                    guard let self, !self.stopped else { return }
                    if let known = error as? SegmentError, known.isFatal {
                        // 網址過期：其他分段也一樣抓不到，交給 Player 重新解析網址、從目前的位置接著播。
                        self.fetching.remove(index)
                        self.fail(known.localizedDescription)
                        return
                    }
                    // 斷線、逾時、429、5xx：等一下再試，這段時間播放會停在緩衝。跳到別的地方去了就放掉。
                    guard self.isWanted(index, playlist) else {
                        self.fetching.remove(index)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
        }
    }

    private func store(_ index: Int, _ data: Data) {
        stats.segmentsFetched += 1
        cacheBytes += data.count - (cache[index]?.count ?? 0)
        cache[index] = data
        // 太多就丟掉離目前位置最遠的。
        while cacheBytes > Self.cacheLimit, cache.count > 8,
              let farthest = cache.keys.max(by: { abs($0 - nextSegment) < abs($1 - nextSegment) }),
              let removed = cache.removeValue(forKey: farthest) {
            cacheBytes -= removed.count
        }
    }
}
