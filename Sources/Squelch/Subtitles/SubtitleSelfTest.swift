import Foundation
import SquelchASR

/// 字幕的自我測試。不呼叫 Codex（要額度）、不載入語音模型（2.5 GB），那兩段用 `--subtitle-check` 另外測。
extension SelfTest {
    static func subtitleUnits() {
        // 挑字幕軌：人工正體中文 > 原文人工 > 原文自動；YouTube 自動翻譯的 zh-Hant 不用。
        func info(_ subs: [String], _ auto: [String], language: String?) -> [String: Any] {
            func formats(_ keys: [String]) -> [String: [[String: Any]]] {
                Dictionary(uniqueKeysWithValues: keys.map { ($0, [["ext": "json3", "url": "https://x.test/\($0)"]]) })
            }
            var obj: [String: Any] = ["subtitles": formats(subs), "automatic_captions": formats(auto)]
            if let language { obj["language"] = language }
            return obj
        }
        let zhManual = Captions.choose(info(["en", "zh-TW"], ["en-orig", "zh-Hant"], language: "en"))
        check(zhManual?.language == "zh-TW" && zhManual?.handling == .direct, "captions: manual zh-TW shown as-is")
        let original = Captions.choose(info(["en"], ["en-orig", "zh-Hant"], language: "en"))
        check(original?.language == "en" && original?.isAuto == false && original?.handling == .translate, "captions: manual original language")
        let auto = Captions.choose(info(["live_chat"], ["ja-orig", "ja", "zh-Hant"], language: "ja"))
        check(auto?.language == "ja" && auto?.isAuto == true && auto?.url.lastPathComponent == "ja-orig", "captions: auto original, not YouTube's translation")
        let chinese = Captions.choose(info([], ["zh-Hans-orig", "zh-Hant"], language: "zh-Hans"))
        check(chinese?.handling == .convert, "captions: Chinese source only converted")
        check(Captions.choose(info([], ["zh-Hant", "fr"], language: "en")) == nil, "captions: none when only translated tracks")

        // json3：人工一句一個事件；自動字幕逐字，跨行接字要補空格。
        let manual = Captions.parseManual(Data(#"{"events":[{"tStartMs":5200,"dDurationMs":1041,"segs":[{"utf8":"Too hot!"}]},{"tStartMs":7000,"dDurationMs":900,"segs":[{"utf8":"Line one\nline two"}]}]}"#.utf8))
        check(manual.count == 2 && manual[0].start == 5.2 && abs(manual[0].end - 6.241) < 0.001 && manual[1].text == "Line one line two",
              "captions: manual json3 \(manual.map(\.text))")
        let autoData = Data(#"""
        {"events":[
         {"tStartMs":1000,"dDurationMs":3000,"segs":[{"utf8":"Sorry"},{"utf8":" about","tOffsetMs":300}]},
         {"tStartMs":1700,"aAppend":1,"segs":[{"utf8":"\n"}]},
         {"tStartMs":1700,"dDurationMs":3000,"segs":[{"utf8":"that."},{"utf8":" I","tOffsetMs":500}]},
         {"tStartMs":5000,"dDurationMs":2000,"segs":[{"utf8":"blame"},{"utf8":" YouTube.","tOffsetMs":400}]}
        ]}
        """#.utf8)
        let words = Captions.parseAuto(autoData)
        // 「that.」句尾斷開；「I」之後停了 2.8 秒也斷開。
        check(words.map(\.text) == ["Sorry about that.", "I", "blame YouTube."] && words[0].start == 1 && words[2].start == 5,
              "captions: auto json3 joins words, breaks at sentence ends and pauses \(words.map(\.text))")
        check(Captions.join(["今日は", "いい", "天気"]) == "今日はいい天気" && Captions.join(["Hi", "there", ","]) == "Hi there,", "captions: join spacing")
        check(Captions.toTraditional("软件和网络") == "軟件和網絡", "captions: Chinese converted to traditional characters")

        // 顯示：找這個時間的那句；句尾留 1 秒，或到下一句開始。
        let subs = Subtitles(preview: [Cue(start: 1, end: 2, text: "a"), Cue(start: 2.5, end: 4, text: "b"), Cue(start: 9, end: 10, text: "c")], enabled: true)
        check(subs.cue(at: 0.5) == nil && subs.cue(at: 1.5)?.text == "a" && subs.cue(at: 2.4)?.text == "a"
              && subs.cue(at: 2.6)?.text == "b" && subs.cue(at: 4.9)?.text == "b" && subs.cue(at: 5.5) == nil && subs.cue(at: 9)?.text == "c",
              "subtitles: cue lookup at playback time")

        // 翻譯回覆：每個 id 都要有，多的丟掉，前後有雜字也能讀。
        let parsed = try? CodexTranslator.parse(#"ok {"items":[{"id":1,"translation":"一"},{"id":2,"translation":" 二 "},{"id":9,"translation":"多"}]}"#, expected: [1, 2])
        check(parsed == [1: "一", 2: "二"], "translator: parses batch JSON")
        check((try? CodexTranslator.parse(#"{"items":[{"id":1,"translation":"一"}]}"#, expected: [1, 2])) == nil, "translator: rejects missing ids")
        let prompt = CodexTranslator.prompt(.init(title: "T", channel: "C", items: [.init(id: 1, text: "hello")], before: [("hi", "嗨")], after: ["bye"]))
        check(prompt.contains("[1] hello") && prompt.contains("- hi → 嗨") && prompt.contains("- bye"), "translator: prompt carries context")

        // 切段：在安靜的地方切，時間接得上。
        var config = PCMSegmenter.Config()
        config.minSegmentSeconds = 1
        config.maxSegmentSeconds = 4
        config.silenceSeconds = 0
        config.hardCutWindowSeconds = 0.1
        let segmenter = PCMSegmenter(config: config, startSample: 16_000 * 60)
        var tone = [Float](repeating: 0.25, count: 4 * 16_000)
        tone.replaceSubrange((3 * 16_000)..<(3 * 16_000 + 2_400), with: repeatElement(0.0001, count: 2_400))
        let cut = segmenter.append(tone)
        let tail = segmenter.finish()
        check(cut.count == 1 && (49_600...50_400).contains(cut[0].endSample - 16_000 * 60) && cut[0].startSeconds == 60
              && tail.count == 1 && tail[0].startSample == cut[0].endSample && tail[0].endSeconds == 64,
              "speech: segmenter cuts at the quiet spot, timeline from 60s")

        // 直播播放清單：時間 = 開頭的 PROGRAM-DATE-TIME 加上前面各段的長度，序號從 MEDIA-SEQUENCE 起算。
        let livePlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:407270
        #EXT-X-PROGRAM-DATE-TIME:2026-11-12T04:50:53.749+00:00
        #EXTINF:5.0,
        https://x.test/sq/407270/seg.ts
        #EXTINF:5.0,
        https://x.test/sq/407271/seg.ts
        #EXTINF:4.5,
        https://x.test/sq/407272/seg.ts
        """
        let live = LiveHLSChunks.parse(livePlaylist, baseURL: URL(string: "https://x.test/index.m3u8")!)
        check(live.count == 3 && live[0].sequence == 407270 && live[2].sequence == 407272
              && abs(live[0].start - 1794459053.749) < 0.001 && abs(live[2].start - live[0].start - 10) < 0.001,
              "speech: live playlist segment times from PROGRAM-DATE-TIME")

        // 轉成 16 kHz 單聲道：1 秒的 48 kHz 立體聲 → 約 16000 個取樣，左右平均。
        let stereo = (0..<48_000).flatMap { i -> [Float] in [0.5, 0.1] }
        let mono = MonoResampler(sampleRate: 48_000)?.convert(stereo, channels: 2) ?? []
        check(abs(mono.count - 16_000) < 200 && abs((mono.dropFirst(100).first ?? 0) - 0.3) < 0.02,
              "speech: resample 48k stereo to 16k mono (\(mono.count) samples)")
    }

    /// 真的抓這部的字幕（不翻譯），也照語音辨識的路徑抓一段 HLS 解成 16 kHz（不載入模型）。
    static func subtitles(_ stream: ResolvedStream, videoID: String) async {
        guard let track = stream.captions else {
            check(false, "subtitles: resolve found no caption track")
            return
        }
        do {
            let cues = try await Captions.fetch(track, headers: stream.headers)
            check(cues.count > 20 && zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start },
                  "subtitles: fetched \(track.language) \(track.isAuto ? "auto" : "manual") captions: \(cues.count) cues")
        } catch {
            check(false, "subtitles: fetch: \(error.localizedDescription)")
        }
        do {
            let chunks = try await HLSChunks(stream: stream, from: 62)
            if let (samples, end) = try await chunks.next() {
                // 從 62 秒開始：第一段只留 62 秒之後的部分。
                let seconds = Double(samples.count) / 16_000
                check(seconds > 0.5 && seconds < 7 && abs((end - seconds) - 62) < 0.1,
                      "speech: HLS segment decoded to 16 kHz from 62s (\(String(format: "%.2f", seconds))s, ends \(String(format: "%.1f", end)))")
            } else {
                check(false, "speech: HLS gave no audio")
            }
        } catch {
            check(false, "speech: HLS: \(error.localizedDescription)")
        }
        do {
            let track = try await YTDLP.captions(videoID: videoID)
            check(track?.url.absoluteString.contains("timedtext") == true, "subtitles: caption lookup for local files")
        } catch {
            check(false, "subtitles: caption lookup: \(error.localizedDescription)")
        }
    }
}
