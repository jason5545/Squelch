import Foundation

/// `Squelch --subtitle-check <影片 ID> [--speech 秒數]`：不開視窗、不出聲，實際跑一次字幕流程，印出結果。
/// 會真的呼叫 Codex 翻一批（花 Codex 額度），所以不放進 `--selftest`。
/// 加 `--speech 30`：不用 YouTube 字幕，改用本機語音辨識前 30 秒（模型要先下載好）。
enum SubtitleCheck {
    static func run(_ arguments: [String]) async -> Bool {
        guard let index = arguments.firstIndex(of: "--subtitle-check"), index + 1 < arguments.count else {
            print("用法：Squelch --subtitle-check <影片 ID> [--speech 秒數]")
            return false
        }
        let id = arguments[index + 1]
        let speechSeconds = arguments.firstIndex(of: "--speech").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
        // `--target en`：翻成指定的語言（預設跟著介面語言）。
        let target = arguments.firstIndex(of: "--target").flatMap { $0 + 1 < arguments.count ? SubtitleTarget(rawValue: arguments[$0 + 1]) : nil } ?? .system
        print("目標語言：\(target.name)")
        do {
            var clock = Date()
            let stream = try await YTDLP.resolve(videoID: id)
            print("解析：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒，\(stream.title)（\(stream.channelTitle)），本機檔=\(stream.isLocal)")
            var cues: [Cue]
            if let speechSeconds {
                if !SpeechModel.isComplete(SpeechModel.directory) {
                    clock = Date()
                    let model = SpeechModel()
                    model.prepare()
                    while true {
                        try await Task.sleep(for: .seconds(1))
                        if model.state == .ready { break }
                        if case .failed(let why) = model.state { print("FAIL 模型：\(why)"); return false }
                        if case .preparing(let p) = model.state { print("  準備模型 \(Int(p * 100))%") }
                    }
                    print("準備模型：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒")
                }
                clock = Date()
                let transcriber = SpeechTranscriber()
                try await transcriber.load(SpeechModel.directory)
                print("載入模型：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒")
                clock = Date()
                let box = CueBox()
                let run = Task {
                    do {
                        try await transcriber.run(stream, from: 0, horizon: { speechSeconds }, emit: { cue, reached in
                            await box.add(cue, reached)
                        })
                        await box.finish(nil)
                    } catch {
                        await box.finish(error.localizedDescription)
                    }
                }
                while await box.reached < speechSeconds, await !box.done {
                    try await Task.sleep(for: .milliseconds(200))
                }
                run.cancel()
                if let error = await box.error { throw SubtitleError.codex(error) }
                cues = await box.cues.filter { $0.start < speechSeconds }
                print("辨識前 \(Int(speechSeconds)) 秒：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒，\(cues.count) 句")
            } else {
                guard let sources = stream.captions, let track = Captions.choose(sources, target: target) else {
                    print("FAIL 這部沒有可用的字幕")
                    return false
                }
                print("字幕：\(track.language) \(track.isAuto ? "自動" : "人工") \(track.handling.rawValue)")
                clock = Date()
                cues = try await Captions.fetch(track, target: target, headers: stream.headers)
                print("抓字幕：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒，\(cues.count) 句，到 \(Format.time(cues.last?.end ?? 0))")
                if track.handling != .translate {
                    for cue in cues.prefix(6) { print("  \(Format.time(cue.start)) \(cue.translation ?? "")") }
                    return !cues.isEmpty
                }
            }
            guard !cues.isEmpty else {
                print("FAIL 沒有任何字幕")
                return false
            }
            let picked = Array(cues.filter { $0.translation == nil }.prefix(6))
            let batch = CodexTranslator.Batch(
                target: target, title: stream.title, channel: stream.channelTitle,
                items: picked.enumerated().map { CodexTranslator.Item(id: $0.offset + 1, text: $0.element.text) },
                before: [], after: cues.dropFirst(picked.count).prefix(2).map(\.text))
            clock = Date()
            let translator = CodexTranslator()
            let result = try await translator.translate(batch)
            print("翻譯 \(picked.count) 句（\(CodexTranslator.model) \(CodexTranslator.effort) \(CodexTranslator.serviceTier)）：\(String(format: "%.1f", -clock.timeIntervalSinceNow)) 秒")
            let info = await translator.lastThread
            print("Codex 回報：model=\(info.model ?? "?") serviceTier=\(info.tier ?? "?") reasoningEffort=\(info.effort ?? "?")")
            for (n, cue) in picked.enumerated() {
                print("  \(Format.time(cue.start))–\(Format.time(cue.end)) \(cue.text)")
                print("      → \(result[n + 1] ?? "（缺）")")
            }
            await translator.stop()
            return result.count == picked.count
        } catch {
            print("FAIL \(error.localizedDescription)")
            return false
        }
    }
}

private actor CueBox {
    var cues: [Cue] = []
    var reached = 0.0
    var done = false
    var error: String?

    func finish(_ error: String?) {
        done = true
        self.error = error
    }

    func add(_ cue: Cue?, _ reached: Double) {
        if let cue { cues.append(cue) }
        self.reached = max(self.reached, reached)
    }
}

/// `Squelch --subtitle-flow <影片 ID>`：不出聲地真的播，字幕照 App 的流程跑（挑軌、翻譯排程、跳轉、快取），
/// 印出字幕多久出來、跳轉後多久跟上。會呼叫 Codex 翻好幾批。不碰使用者的資料庫和設定。
enum SubtitleFlowCheck {
    static func run(_ arguments: [String]) async -> Bool {
        guard let index = arguments.firstIndex(of: "--subtitle-flow"), index + 1 < arguments.count else { return false }
        let id = arguments[index + 1]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-subtitle-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheFile = Subtitles.cacheFile(id, .zhHant)
        try? FileManager.default.removeItem(at: cacheFile)

        guard let stream = try? await YTDLP.resolve(videoID: id) else {
            print("FAIL resolve")
            return false
        }
        let ep = Episode(id: id, title: stream.title, channelID: stream.channelID ?? "", channelTitle: stream.channelTitle,
                         duration: stream.duration, published: Date(), isLive: stream.isLive)
        let savedRate = UserDefaults.standard.object(forKey: "rate")
        let savedVolume = UserDefaults.standard.object(forKey: "volume")
        defer {
            UserDefaults.standard.set(savedRate, forKey: "rate")
            UserDefaults.standard.set(savedVolume, forKey: "volume")
        }
        let player = Player(library: Library(directory: dir))
        player.silent = true
        player.rate = 1
        let subtitles = Subtitles(preview: [], enabled: true)
        subtitles.player = player
        player.subtitles = subtitles
        var ok = true
        func check(_ pass: Bool, _ label: String) {
            print((pass ? "PASS  " : "FAIL  ") + label)
            if !pass { ok = false }
        }

        let started = Date()
        player.play(ep)
        if stream.isLive { return await live(player, subtitles, ep, started, cacheFile) }
        // 第一句有中文的字幕出現在畫面上（播放位置那句）。
        var firstShown: Double?
        while Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(for: .milliseconds(250))
            if let cue = subtitles.cue(at: player.position), cue.translation != nil, player.position > 0 {
                firstShown = Date().timeIntervalSince(started)
                print("info  \(Format.time(player.position)) \(cue.translation ?? "")")
                break
            }
        }
        check(firstShown != nil, "first translated line on screen after \(firstShown.map { String(format: "%.1f", $0) } ?? "–")s (status \(subtitles.status), error \(subtitles.translationError ?? "none"))")
        try? await Task.sleep(for: .seconds(30))
        let position = player.position
        let ahead = subtitles.cues.filter { $0.translation != nil && $0.start > position }.map(\.start).max().map { $0 - position } ?? 0
        let translated = subtitles.cues.filter { $0.translation != nil }.count
        check(ahead > 20, "translation runs ahead of playback: \(String(format: "%.0f", ahead))s ahead at \(Format.time(position)), \(translated)/\(subtitles.cues.count) lines")

        // 跳到 10 分鐘：多久有中文。
        let target = min(600, max(0, (stream.duration ?? 700) - 90))
        let seekAt = Date()
        player.seek(to: target)
        var caughtUp: Double?
        while Date().timeIntervalSince(seekAt) < 90 {
            try? await Task.sleep(for: .milliseconds(250))
            if player.position > target, let cue = subtitles.cue(at: player.position), cue.translation != nil {
                caughtUp = Date().timeIntervalSince(seekAt)
                print("info  \(Format.time(player.position)) \(cue.translation ?? "")")
                break
            }
        }
        check(caughtUp != nil, "after seeking to \(Format.time(target)), translated line after \(caughtUp.map { String(format: "%.1f", $0) } ?? "–")s")
        player.pause()
        try? await Task.sleep(for: .seconds(3))
        let saved = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let savedTranslated = (saved?["cues"] as? [[String: Any]])?.filter { $0["translation"] != nil }.count ?? 0
        check(savedTranslated >= translated, "cache saved \(savedTranslated) translated lines")

        // 重新接上同一部：從快取讀，不再抓字幕。
        let again = Subtitles(preview: [], enabled: true)
        again.player = player
        again.attach(ep, stream)
        try? await Task.sleep(for: .milliseconds(500))
        check(again.cues.filter { $0.translation != nil }.count == savedTranslated, "reattach reads the cache")
        print(ok ? "ALL PASS" : "FAILED")
        return ok
    }

    /// 直播：沒有字幕，靠本機語音辨識。量字幕出來的速度，和字幕比播放位置早或晚多少。
    private static func live(_ player: Player, _ subtitles: Subtitles, _ ep: Episode, _ started: Date, _ cacheFile: URL) async -> Bool {
        var ok = true
        func check(_ pass: Bool, _ label: String) {
            print((pass ? "PASS  " : "FAIL  ") + label)
            if !pass { ok = false }
        }
        while Date().timeIntervalSince(started) < 30, player.liveDate < 1e9 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let behind = Date().timeIntervalSince1970 - player.liveDate
        check(player.liveDate > 1e9, "live: AVPlayer reports the program date (playing \(String(format: "%.0f", behind))s behind real time)")
        var firstSource: Double?, firstShown: Double?
        while Date().timeIntervalSince(started) < 120, firstShown == nil {
            try? await Task.sleep(for: .milliseconds(250))
            if firstSource == nil, subtitles.cue(at: player.subtitleClock) != nil { firstSource = Date().timeIntervalSince(started) }
            if let cue = subtitles.cue(at: player.subtitleClock), cue.translation != nil {
                firstShown = Date().timeIntervalSince(started)
                print("info  \(cue.text)\n      → \(cue.translation ?? "")")
            }
        }
        check(subtitles.status == .speech, "live: no captions, speech recognition started (status \(subtitles.status))")
        check(firstShown != nil, "live: first line on screen after \(firstSource.map { String(format: "%.1f", $0) } ?? "–")s, translated after \(firstShown.map { String(format: "%.1f", $0) } ?? "–")s (error \(subtitles.translationError ?? "none"))")
        // 再聽 60 秒：每秒看一次播放位置那句有沒有字幕、有沒有翻好。
        var seconds = 0, withLine = 0, translated = 0
        while seconds < 60 {
            try? await Task.sleep(for: .seconds(1))
            seconds += 1
            if let cue = subtitles.cue(at: player.subtitleClock) {
                withLine += 1
                if cue.translation != nil { translated += 1 }
            }
        }
        let clock = player.subtitleClock
        let newest = subtitles.cues.last.map { $0.end - clock } ?? -999
        print("info  60s: line on screen \(withLine)s, translated \(translated)s; newest cue ends \(String(format: "%+.0f", newest))s from playback; \(subtitles.cues.count) cues")
        check(translated >= 20, "live: translated lines shown for \(translated) of 60 seconds")
        player.pause()
        try? await Task.sleep(for: .seconds(3))
        check(FileManager.default.fileExists(atPath: cacheFile.path), "live: cache saved")
        try? FileManager.default.removeItem(at: cacheFile)
        print(ok ? "ALL PASS" : "FAILED")
        return ok
    }
}
