import AVFoundation
import Foundation
import SquelchASR

/// 沒有 YouTube 字幕時的備援：本機的 Qwen3-ASR 1.7B（8-bit，約 2.5 GB）。預設關，打開才準備模型。
@MainActor @Observable
final class SpeechModel {
    enum State: Equatable {
        case missing
        case preparing(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .missing

    /// 釘在 Hugging Face 的這個版本，檔案大小也照它對。
    static let repo = "mlx-community/Qwen3-ASR-1.7B-8bit"
    static let revision = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
    static let files: [(name: String, size: Int64)] = [
        ("config.json", 7188), ("generation_config.json", 142), ("chat_template.json", 1161),
        ("preprocessor_config.json", 330), ("tokenizer_config.json", 12487), ("vocab.json", 2_776_833),
        ("merges.txt", 1_671_853), ("model.safetensors.index.json", 78968), ("model.safetensors", 2_463_307_541),
    ]
    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squelch/Models/Qwen3-ASR-1.7B-8bit", isDirectory: true)
    }

    /// Voco 下載過同一個模型的話，從那裡複製（APFS 上是 clone，不多佔空間），不用再下載。
    static var vocoDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jasonchien.Voco/Qwen3Models/mlx-community_Qwen3-ASR-1.7B-8bit", isDirectory: true)
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        if Self.isComplete(Self.directory) { state = .ready }
    }

    static func isComplete(_ dir: URL) -> Bool {
        files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path)[.size] as? NSNumber)?.int64Value
            return size == file.size
        }
    }

    func prepare() {
        guard state != .ready, task == nil else { return }
        state = .preparing(0)
        task = Task {
            do {
                try await install()
                state = .ready
            } catch is CancellationError {
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        task?.cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
    }

    private func install() async throws {
        let fm = FileManager.default
        let dir = Self.directory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var done: Int64 = 0
        for file in Self.files {
            let target = dir.appendingPathComponent(file.name)
            if (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value == file.size {
                done += file.size
                continue
            }
            try? fm.removeItem(at: target)
            let local = Self.vocoDirectory.appendingPathComponent(file.name)
            if (try? fm.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value == file.size {
                try fm.copyItem(at: local, to: target)
            } else {
                let base = done
                try await download(file.name, to: target) { [weak self] received in
                    self?.state = .preparing(Double(base + received) / Double(Self.totalSize))
                }
            }
            done += file.size
            state = .preparing(Double(done) / Double(Self.totalSize))
            try Task.checkCancellation()
        }
        guard Self.isComplete(dir) else { throw SubtitleError.codex(String(localized: "模型檔案大小不對")) }
    }

    private func download(_ name: String, to target: URL, progress: @escaping @MainActor (Int64) -> Void) async throws {
        let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(name)")!
        let observer = DownloadProgress { received in Task { @MainActor in progress(received) } }
        let (file, response) = try await URLSession.shared.download(from: url, delegate: observer)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw SubtitleError.http(http.statusCode)
        }
        try FileManager.default.moveItem(at: file, to: target)
    }
}

nonisolated private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// 自己抓音軌、解碼、轉成 16 kHz 單聲道，切段後交給 Qwen3-ASR。跟播放分開跑，可以跑在播放位置前面。
/// HLS 分段跟 `SegmentPlayer` 是同一份播放清單（每段約 5 秒、80 KB），本機檔用 `AVAssetReader` 讀。
actor SpeechTranscriber {
    private let recognizer = SpeechRecognizer()

    func load(_ directory: URL) async throws {
        try await recognizer.load(modelDirectory: directory)
    }

    func unload() async {
        await recognizer.unload()
    }

    /// 從 `start` 秒開始往後辨識。`horizon()` 回傳現在可以做到哪裡（播放位置往後幾分鐘），超過就等。
    /// 每辨識完一段呼叫 `emit`（這段的字幕，和已經處理到哪裡）。
    func run(_ stream: ResolvedStream, from start: Double,
             horizon: @escaping @Sendable () async -> Double,
             emit: @escaping @Sendable (Cue?, Double) async -> Void) async throws {
        let audio: AudioChunks
        if stream.isLive {
            audio = try await LiveHLSChunks(stream: stream, from: start)
        } else if stream.isLocal {
            audio = try FileChunks(url: stream.url, from: start)
        } else {
            audio = try await HLSChunks(stream: stream, from: start)
        }
        // 直播可能從別的地方開始（要的時間不在窗口裡），時間軸以音訊實際的起點為準。
        let segmenter = PCMSegmenter(startSample: Int64((audio.startTime * PCMSegment.sampleRate).rounded()))
        var position = audio.startTime
        while let (samples, end) = try await audio.next() {
            try Task.checkCancellation()
            for segment in segmenter.append(samples) {
                try await recognize(segment, emit: emit)
            }
            position = end
            await emit(nil, position)
            while await horizon() < position {
                try await Task.sleep(for: .seconds(1))
            }
        }
        for segment in segmenter.finish() {
            try await recognize(segment, emit: emit)
        }
        await emit(nil, .infinity)
    }

    private func recognize(_ segment: PCMSegment, emit: @Sendable (Cue?, Double) async -> Void) async throws {
        let result = try await recognizer.transcribe(segment.samples)
        guard !result.text.isEmpty else { return }
        let cue = Cue(start: segment.startSeconds, end: segment.endSeconds, text: result.text,
                      language: Self.code(result.language))
        await emit(cue, segment.endSeconds)
    }

    /// Qwen3-ASR 回報的語言名稱 → 語言代碼。認不得的留 nil（照樣送翻譯）。
    static func code(_ name: String?) -> String? {
        switch name?.lowercased() {
        case "english": "en"
        case "japanese": "ja"
        case "chinese": "zh"
        case "cantonese": "yue"
        case "korean": "ko"
        default: nil
        }
    }
}

/// 一塊一塊吐出 16 kHz 單聲道取樣，附上這塊結尾的影片時間。
nonisolated protocol AudioChunks {
    /// 第一個取樣的時間（影片時間，直播是 UNIX 秒）。
    var startTime: Double { get }
    func next() async throws -> ([Float], Double)?
}

/// 交錯的 Float PCM → 16 kHz 單聲道。先自己把聲道平均（AVAudioConverter 的降聲道不一定是混音），再換取樣率。
nonisolated final class MonoResampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat

    init?(sampleRate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMSegment.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
    }

    func convert(_ interleaved: [Float], channels: Int) -> [Float] {
        let frames = interleaved.count / max(1, channels)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)),
              let mono = buffer.floatChannelData?[0] else { return [] }
        if channels == 1 {
            interleaved.withUnsafeBufferPointer { mono.update(from: $0.baseAddress!, count: frames) }
        } else {
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let capacity = AVAudioFrameCount(Double(frames) * output.sampleRate / input.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }
}

/// HLS：照順序抓分段（ID3 + ADTS AAC），解碼後轉 16 kHz。
nonisolated final class HLSChunks: AudioChunks, @unchecked Sendable {
    private let stream: ResolvedStream
    private let playlist: SegmentPlaylist
    private let session: URLSession
    private var index: Int
    private var decoder: SegmentDecoder?
    private var resampler: MonoResampler?
    /// 第一段要從 `start` 之前的部分丟掉。
    private var skipUntil: Double
    let startTime: Double

    init(stream: ResolvedStream, from start: Double) async throws {
        self.stream = stream
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: Self.request(stream.url, stream.headers))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw SubtitleError.http(http.statusCode) }
        playlist = try SegmentPlaylist.parse(String(decoding: data, as: UTF8.self), baseURL: stream.url)
        index = playlist.index(at: start)
        skipUntil = start
        startTime = start
    }

    private static func request(_ url: URL, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    func next() async throws -> ([Float], Double)? {
        guard index < playlist.segments.count else { return nil }
        let segment = playlist.segments[index]
        index += 1
        var delay = 1.0
        var data = Data()
        while true {
            do {
                let (body, response) = try await session.data(for: Self.request(segment.url, stream.headers))
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw SubtitleError.http(http.statusCode) }
                data = body
                break
            } catch let error as SubtitleError {
                throw error
            } catch {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
        }
        let end = segment.start + segment.duration
        guard let parsed = ADTS.parse(data) else { return ([], end) }
        if decoder == nil || decoder?.format != parsed.format {
            decoder = SegmentDecoder(format: parsed.format)
            resampler = MonoResampler(sampleRate: parsed.format.sampleRate)
        }
        guard let decoder, let resampler else { return ([], end) }
        var mono = resampler.convert(decoder.decode(data, packets: parsed.packets), channels: parsed.format.channels)
        if skipUntil > segment.start {
            let drop = min(mono.count, Int((skipUntil - segment.start) * PCMSegment.sampleRate))
            mono.removeFirst(drop)
            skipUntil = 0
        }
        return (mono, end)
    }
}

/// 本機檔（下載備援的 m4a）：`AVAssetReader` 直接輸出 16 kHz 單聲道。
nonisolated final class FileChunks: AudioChunks, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var position: Double
    let startTime: Double

    init(url: URL, from start: Double) throws {
        let asset = AVURLAsset(url: url)
        reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw SubtitleError.codex("no audio track") }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: PCMSegment.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), duration: .positiveInfinity)
        position = start
        startTime = start
        guard reader.startReading() else { throw reader.error ?? SubtitleError.codex("AVAssetReader") }
    }

    func next() async throws -> ([Float], Double)? {
        var samples: [Float] = []
        // 一次大約 5 秒，跟 HLS 一段差不多。
        while samples.count < 80_000, let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        guard !samples.isEmpty else { return nil }
        position += Double(samples.count) / PCMSegment.sampleRate
        return (samples, position)
    }
}

/// 直播的 HLS：播放清單是 1 小時的滑動窗口，開頭有一個 `EXT-X-PROGRAM-DATE-TIME`，之後每段 5 秒。
/// 時間一律用實際時間（UNIX 秒）：開頭的時間加上前面各段的長度。追到最新的那段就每 2 秒重抓一次播放清單等下一段。
/// 要的那段已經滑出窗口（落後超過 1 小時）就結束，讓呼叫端從播放位置重新開始，時間軸才不會斷掉還接著算。
nonisolated final class LiveHLSChunks: AudioChunks, @unchecked Sendable {
    struct Segment {
        let sequence: Int
        let url: URL
        let start: Double
        let duration: Double
    }

    private let stream: ResolvedStream
    private let session: URLSession
    private var segments: [Segment] = []
    private var nextSequence: Int
    private var decoder: SegmentDecoder?
    private var resampler: MonoResampler?
    private var skipUntil: Double
    private(set) var startTime: Double

    init(stream: ResolvedStream, from start: Double) async throws {
        self.stream = stream
        startTime = start
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        skipUntil = start
        nextSequence = 0
        try await reload()
        guard let last = segments.last else { throw SubtitleError.codex("live playlist has no segments") }
        // 從包含 `start` 的那段開始；不在窗口裡（還沒對上時間、或太舊）就從最新往前 3 段開始。
        if let found = segments.last(where: { $0.start <= start }), start < last.start + last.duration {
            nextSequence = found.sequence
        } else {
            let fallback = segments[max(0, segments.count - 3)]
            nextSequence = fallback.sequence
            skipUntil = fallback.start
            startTime = fallback.start
        }
    }

    static func parse(_ text: String, baseURL: URL) -> [Segment] {
        var segments: [Segment] = []
        var sequence = 0
        var clock: Double?
        var pending: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                clock = Self.date(String(line.dropFirst(25)))?.timeIntervalSince1970
            } else if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pending, let start = clock,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                segments.append(Segment(sequence: sequence, url: url, start: start, duration: duration))
                sequence += 1
                clock = start + duration
                pending = nil
            }
        }
        return segments
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func reload() async throws {
        var request = URLRequest(url: stream.url)
        for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw SubtitleError.http(http.statusCode) }
        segments = Self.parse(String(decoding: data, as: UTF8.self), baseURL: stream.url)
    }

    func next() async throws -> ([Float], Double)? {
        var waited = 0
        while true {
            try Task.checkCancellation()
            if let first = segments.first, nextSequence < first.sequence { return nil }   // 滑出窗口了
            if let segment = segments.first(where: { $0.sequence == nextSequence }) {
                nextSequence += 1
                return try await decode(segment)
            }
            // 追到最新了：等下一段出來。等太久（直播結束或斷線）就結束。
            waited += 1
            if waited > 60 { return nil }
            try await Task.sleep(for: .seconds(2))
            try? await reload()
        }
    }

    private func decode(_ segment: Segment) async throws -> ([Float], Double) {
        var request = URLRequest(url: segment.url)
        for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
        let end = segment.start + segment.duration
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let parsed = ADTS.parse(data) else {
            // 抓不到這一段：補一段靜音，時間軸照樣往前。
            return ([Float](repeating: 0, count: Int(segment.duration * PCMSegment.sampleRate)), end)
        }
        if decoder == nil || decoder?.format != parsed.format {
            decoder = SegmentDecoder(format: parsed.format)
            resampler = MonoResampler(sampleRate: parsed.format.sampleRate)
        }
        guard let decoder, let resampler else { return ([], end) }
        var mono = resampler.convert(decoder.decode(data, packets: parsed.packets), channels: parsed.format.channels)
        // 解出來的長度跟 EXTINF 不一定剛好一樣：補齊或截掉，時間軸才不會越跑越偏。
        let expected = Int(segment.duration * PCMSegment.sampleRate)
        if mono.count < expected { mono += [Float](repeating: 0, count: expected - mono.count) }
        if mono.count > expected { mono.removeLast(mono.count - expected) }
        if skipUntil > segment.start {
            mono.removeFirst(min(mono.count, Int((skipUntil - segment.start) * PCMSegment.sampleRate)))
            skipUntil = 0
        }
        return (mono, end)
    }
}
