import Foundation

/// 切好、要送去辨識的一段聲音。時間以這條音訊開頭為 0（16 kHz 取樣數）。
public struct PCMSegment: Sendable {
    public let startSample: Int64
    public let endSample: Int64
    public let samples: [Float]

    public static let sampleRate = 16_000.0

    public var startSeconds: Double { Double(startSample) / Self.sampleRate }
    public var endSeconds: Double { Double(endSample) / Self.sampleRate }
}

/// 把連續的 16 kHz 單聲道取樣切成適合辨識的段落：優先在真的安靜的地方切，
/// 太長要硬切時，在最後 1.5 秒裡找最安靜的位置，避免一個字被切成兩半。
/// 參數和演算法跟 AISubtitle（qwen3-asr-stdin）一樣。
public final class PCMSegmenter {
    public struct Config: Sendable {
        public var minSegmentSeconds = 1.6
        public var maxSegmentSeconds = 5.6
        public var silenceSeconds = 0.35
        public var silenceRMS: Float = 0.012
        public var minSpeechRMS: Float = 0.004
        public var hardCutSearchSeconds = 1.5
        public var hardCutWindowSeconds = 0.08

        public init() {}
    }

    private let sampleRate = 16_000
    private let config: Config
    private var samples: [Float] = []
    private var bufferStartSample: Int64

    /// `startSample`：第一個取樣在整條音訊裡的位置，切出來的段落時間都從這裡算。
    public init(config: Config = Config(), startSample: Int64 = 0) {
        self.config = config
        self.bufferStartSample = startSample
    }

    /// 已經收進來、還沒切出去的取樣到哪裡為止。
    public var endSample: Int64 { bufferStartSample + Int64(samples.count) }

    public func append(_ newSamples: [Float]) -> [PCMSegment] {
        samples.append(contentsOf: newSamples)
        return consumeReadySegments(force: false)
    }

    public func finish() -> [PCMSegment] {
        consumeReadySegments(force: true)
    }

    private func consumeReadySegments(force: Bool) -> [PCMSegment] {
        var ready: [PCMSegment] = []
        let minSamples = Int(config.minSegmentSeconds * Double(sampleRate))
        let maxSamples = Int(config.maxSegmentSeconds * Double(sampleRate))
        let silenceSamples = Int(config.silenceSeconds * Double(sampleRate))

        while !samples.isEmpty {
            if samples.count >= maxSamples {
                let cut = quietHardCutSampleCount(minSamples: minSamples, maxSamples: maxSamples)
                if let segment = popSegment(sampleCount: cut) {
                    ready.append(segment)
                }
                continue
            }

            if samples.count >= minSamples,
               silenceSamples > 0,
               trailingRMS(sampleCount: min(silenceSamples, samples.count)) <= config.silenceRMS {
                let cut = max(0, samples.count - silenceSamples)
                if cut > 0, let segment = popSegment(sampleCount: cut) {
                    ready.append(segment)
                }
                discardSamples(sampleCount: min(silenceSamples, samples.count))
                continue
            }

            if force, let segment = popSegment(sampleCount: samples.count) {
                ready.append(segment)
            }
            break
        }
        return ready
    }

    private func quietHardCutSampleCount(minSamples: Int, maxSamples: Int) -> Int {
        let searchSamples = max(1, Int(config.hardCutSearchSeconds * Double(sampleRate)))
        let windowSamples = max(1, Int(config.hardCutWindowSeconds * Double(sampleRate)))
        let earliestCut = max(minSamples, maxSamples - searchSamples)
        let strideSamples = max(1, windowSamples / 4)

        var candidateCuts = Array(stride(from: earliestCut, through: maxSamples, by: strideSamples))
        if candidateCuts.last != maxSamples {
            candidateCuts.append(maxSamples)
        }

        var bestCut = maxSamples
        var bestEnergy = Double.greatestFiniteMagnitude
        for cut in candidateCuts {
            // 看切點前面一小段的能量，下一段從最安靜的邊界之後開始。
            let windowStart = max(0, cut - windowSamples)
            guard windowStart < cut, cut <= samples.count else { continue }
            var energy = 0.0
            for value in samples[windowStart..<cut] {
                energy += Double(value * value)
            }
            energy /= Double(cut - windowStart)
            if energy <= bestEnergy {
                bestEnergy = energy
                bestCut = cut
            }
        }
        return max(minSamples, min(bestCut, maxSamples))
    }

    private func popSegment(sampleCount: Int) -> PCMSegment? {
        let count = min(sampleCount, samples.count)
        guard count > 0 else { return nil }
        let segmentSamples = Array(samples.prefix(count))
        let startSample = bufferStartSample
        discardSamples(sampleCount: count)
        guard rms(segmentSamples) >= config.minSpeechRMS else { return nil }
        return PCMSegment(startSample: startSample, endSample: startSample + Int64(count), samples: segmentSamples)
    }

    private func discardSamples(sampleCount: Int) {
        let count = min(sampleCount, samples.count)
        guard count > 0 else { return }
        samples.removeFirst(count)
        bufferStartSample += Int64(count)
    }

    private func trailingRMS(sampleCount: Int) -> Float {
        guard sampleCount > 0, samples.count >= sampleCount else { return .greatestFiniteMagnitude }
        return rms(samples.suffix(sampleCount))
    }

    private func rms<S: Sequence>(_ values: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count: Float = 0
        for value in values {
            sum += value * value
            count += 1
        }
        guard count > 0 else { return 0 }
        return sqrt(sum / count)
    }
}
