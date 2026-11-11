import AVFoundation
import MediaToolbox
import Synchronization

/// 音量超過 100% 的放大。
///
/// - AVPlayer 的 `volume` 最大 1.0，要更大聲只能在音訊路徑上加增益。
/// - HLS 串流不經過 `MTAudioProcessingTap`（2026/11/11 實測處理函式被呼叫 0 次），所以只在本機檔上放大。
/// - YouTube 講話影片大約 -21 LUFS（實測兩部 Theo 影片 -20.6、-21.2），比 Spotify 的 -14 LUFS 小約 7 dB；
///   峰值已到 -2～-3 dBFS，直接放大會爆音，所以加柔性限幅：0.85 以下原樣，以上用 tanh 壓到不超過 1.0。
nonisolated enum Boost {
    private static let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private static let floatFormat = Atomic<Bool>(false)
    /// 處理過的音訊區塊數，自我測試用來確認 tap 有在跑。
    static let processedBlocks = Atomic<Int>(0)

    static var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(max(1, newValue).bitPattern, ordering: .relaxed) }
    }

    static let knee: Float = 0.85

    /// 柔性限幅：`knee` 以下原樣，以上用 tanh 壓到不超過 1.0。
    @inline(__always) static func shape(_ y: Float) -> Float {
        let a = abs(y)
        guard a > knee else { return y }
        let shaped = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return y < 0 ? -shaped : shaped
    }

    static func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        guard gain > 1.0001 else { return }
        for i in 0..<count { samples[i] = shape(samples[i] * gain) }
    }

    /// 給本機檔的 AVPlayerItem 用的 audioMix。增益隨時讀 `Boost.gain`，改音量不用重建。
    static func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: nil, finalize: nil,
            prepare: { _, _, format in
                let f = format.pointee
                Boost.floatFormat.store((f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32,
                                        ordering: .relaxed)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                Boost.processedBlocks.add(1, ordering: .relaxed)
                guard Boost.floatFormat.load(ordering: .relaxed) else { return }
                let gain = Boost.gain
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    Boost.process(data.assumingMemoryBound(to: Float.self),
                                  count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, gain: gain)
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
