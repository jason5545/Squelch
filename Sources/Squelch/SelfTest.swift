import AppKit
import AVFoundation
import Foundation
import MediaPlayer

/// `Squelch.app/Contents/MacOS/Squelch --selftest`：不開視窗，實際連 YouTube 跑一次核心流程。
/// 驗證：網址解析、頻道清單、三條播放路徑（自己解碼的 HLS、AVPlayer 的 HLS、下載備援：長度、開播、跳到中段、倍速）、
/// 音量放大、SponsorBlock 查詢、存檔。
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ label: String) {
        print((ok ? "PASS  " : "FAIL  ") + label)
        if !ok { failures += 1 }
    }

    static func run() async -> Bool {
        // 測試用的頻道：影片多、長片多、不會消失。
        let channel = "https://www.youtube.com/@AppleDeveloper"
        check(ChannelInput.normalize("@AppleDeveloper") == channel, "normalize @handle")
        check(ChannelInput.normalize("AppleDeveloper") == channel, "normalize bare handle")
        check(ChannelInput.normalize("https://www.youtube.com/@AppleDeveloper/videos?x=1") == channel, "normalize channel URL")
        check(ChannelInput.normalize("youtube.com/channel/UCabcdefghijklmnopqrstuv/featured")
              == "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv", "normalize /channel URL")
        check(ChannelInput.normalize("https://example.com/@x") == nil, "reject other host")
        let cmd = { (s: String) in ChannelInput.command(from: URL(string: s)!) }
        check(cmd("squelch://add?channel=@AppleDeveloper") == .add("@AppleDeveloper")
              && cmd("squelch://subscribe?url=https://www.youtube.com/@AppleDeveloper/videos")
                  == .add("https://www.youtube.com/@AppleDeveloper/videos")
              && cmd("squelch://add/@AppleDeveloper") == .add("@AppleDeveloper"), "subscribe URL")
        check(cmd("squelch://remove?channel=@AppleDeveloper") == .remove("@AppleDeveloper")
              && cmd("squelch://unsubscribe/@AppleDeveloper") == .remove("@AppleDeveloper"), "unsubscribe URL")
        check(cmd("squelch://add") == nil && cmd("squelch://play?channel=@x") == nil
              && cmd("https://www.youtube.com/@x") == nil && cmd("squelch://add?channel=https://example.com/@x") == nil,
              "channel URL rejects junk")
        check(ChannelInput.videoID("https://youtu.be/abcDEF12345?t=3") == "abcDEF12345", "videoID youtu.be")
        check(ChannelInput.videoID("https://www.youtube.com/watch?v=abcDEF12345&list=x") == "abcDEF12345", "videoID watch")
        check(ChannelInput.videoID("https://www.youtube.com/live/abc-EF_2345") == "abc-EF_2345", "videoID live")
        check(Format.time(3725) == "1:02:05" && Format.time(65) == "1:05", "format time")
        check(Format.rate(1.5) == "1.5×" && Format.rate(2) == "2×", "format rate")

        nonisolated(unsafe) let artwork = NowPlaying.makeArtwork(NSImage(size: NSSize(width: 32, height: 18)))
        // 要用 async：sync 會直接在呼叫端（主執行緒）跑，測不到。
        let fromBackground = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: !Thread.isMainThread && artwork.image(at: CGSize(width: 32, height: 18)) != nil)
            }
        }
        check(fromBackground, "Now Playing artwork can be read from a background thread")

        var samples: [Float] = [0.1, 0.4, -0.5, 0.95, -1.0]
        samples.withUnsafeMutableBufferPointer { Boost.process($0.baseAddress!, count: $0.count, gain: 2) }
        check(abs(samples[0] - 0.2) < 0.0001 && abs(samples[1] - 0.8) < 0.0001, "boost doubles quiet samples")
        check(samples.allSatisfy { abs($0) <= 1 } && samples[2] < -0.85 && samples[3] > samples[1],
              "boost soft-limits loud samples below 1.0: \(samples.map { String(format: "%.3f", $0) })")
        var unity: [Float] = [0.3, -0.9]
        unity.withUnsafeMutableBufferPointer { Boost.process($0.baseAddress!, count: $0.count, gain: 1) }
        check(unity == [0.3, -0.9], "boost at 100% leaves audio untouched")

        await tools()
        print("yt-dlp: \(YTDLP.binaryPath() ?? "missing") \(await YTDLP.version() ?? "")")

        var episode: Episode?
        do {
            let started = Date()
            let feed = try await YTDLP.feed(channelID: channel, includeStreams: false)
            let dated = feed.episodes.filter { $0.published != nil }
            check(feed.episodes.count >= 10, "feed has \(feed.episodes.count) episodes (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
            check(dated.count == feed.episodes.count, "every episode has an approximate date")
            check(feed.avatar != nil, "channel avatar")
            let sorted = feed.episodes.sorted(by: Library.newestFirst).map(\.id)
            check(sorted == feed.episodes.map(\.id), "date sort keeps channel order")
            episode = feed.episodes.first { ($0.duration ?? 0) > 900 }
        } catch {
            check(false, "feed: \(error.localizedDescription)")
        }

        if let ep = episode {
            print("episode: \(ep.id) \(ep.title)")
            do {
                let started = Date()
                let stream = try await YTDLP.resolve(videoID: ep.id)
                check(!stream.isLocal, "resolve HLS audio (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
                await decoding(stream)
                await segments(stream, duration: ep.duration ?? 0)
                await playback(stream, duration: ep.duration ?? 0, label: "HLS")
                let dlStart = Date()
                let local = try await YTDLP.download(videoID: ep.id)
                check(local.isLocal && FileManager.default.fileExists(atPath: local.url.path),
                      "download fallback (\(String(format: "%.1f", Date().timeIntervalSince(dlStart)))s)")
                await playback(local, duration: ep.duration ?? 0, label: "download")
                try? FileManager.default.removeItem(at: local.url)
            } catch {
                check(false, "resolve: \(error.localizedDescription)")
            }
            await boostInline(ep)
            await boostSwitch(ep)
            let segments = await SponsorBlock.segments(videoID: ep.id, categories: ["sponsor", "selfpromo"])
            print("info  SponsorBlock segments: \(segments.map { "\($0.category) \(Format.time($0.start))–\(Format.time($0.end))" })")
        }

        await refreshAvoidsAccount(channel: channel)
        await accountChecks()
        await live()
        await liveWatch()
        persistence(channel: channel)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    /// 內建的 yt-dlp 和 deno、自動更新。整個自我測試都不准用 Homebrew 的 yt-dlp，PATH 也沒有 Homebrew。
    private static func tools() async {
        YTDLP.allowHomebrew.store(false, ordering: .relaxed)
        YTDLPUpdate.automatic.store(false, ordering: .relaxed)
        let bundled = YTDLP.bundledDirectory.flatMap { YTDLP.installed(in: $0, source: .bundled) }
        check(bundled?.version?.isEmpty == false, "tools: yt-dlp inside the app: \(bundled?.version ?? "missing")")
        let deno = YTDLP.helpersDirectory.appendingPathComponent("deno").path
        check(FileManager.default.isExecutableFile(atPath: deno), "tools: deno inside the app")
        let custom = UserDefaults.standard.string(forKey: YTDLP.customPathKey) ?? ""
        if custom.isEmpty {
            let source = YTDLP.binary()?.source
            check(source == .bundled || source == .updated, "tools: uses the built-in or auto-updated yt-dlp (\(String(describing: source)))")
        } else {
            print("info  tools: custom yt-dlp path \(custom)")
        }
        if let path = YTDLP.binaryPath() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-v", "--simulate", "--flat-playlist", "-I", "1:1", "https://www.youtube.com/@AppleDeveloper/videos"]
            process.environment = YTDLP.environment()
            let err = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            let p = process
            let text = await Task.detached {
                try? p.run()
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }.value
            let line = text.split(separator: "\n").first { $0.contains("JS runtimes") }.map(String.init) ?? "none"
            check(line.contains("deno"), "tools: yt-dlp finds the built-in deno: \(line)")
        }

        check(YTDLPUpdate.isNewer("2026.11.2", than: "2026.10.26") && YTDLPUpdate.isNewer("2026.10.26.1", than: "2026.10.26")
              && !YTDLPUpdate.isNewer("2026.10.26", than: "2026.10.26") && !YTDLPUpdate.isNewer("2025.12.31", than: "2026.1.1"),
              "tools: version comparison")
        let started = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-selftest-ytdlp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let latest = try await YTDLPUpdate.latestVersion()
            try await YTDLPUpdate.install(version: latest, into: dir)
            let installed = YTDLP.installed(in: dir, source: .updated)
            check(installed?.version == latest,
                  "tools: update downloads, verifies and runs yt-dlp \(latest) (\(fixed(Date().timeIntervalSince(started)))s)")
        } catch {
            check(false, "tools: update: \(error.localizedDescription)")
        }
    }

    private static func playback(_ stream: ResolvedStream, duration: Double, label: String) async {
        let asset = Player.makeAsset(stream)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let blocksBefore = Boost.processedBlocks.load(ordering: .relaxed)
        if stream.isLocal, let track = try? await asset.loadTracks(withMediaType: .audio).first {
            Boost.gain = 2
            item.audioMix = Boost.makeAudioMix(for: track)
        }
        let player = AVPlayer(playerItem: item)
        player.volume = 0

        let started = Date()
        while item.status == .unknown, Date().timeIntervalSince(started) < 30 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let readyIn = Date().timeIntervalSince(started)
        let length = item.duration.seconds
        if duration > 0, length.isFinite {
            check(abs(length - duration) < 3, "\(label): duration \(Format.time(length)) matches \(Format.time(duration))")
        }
        check(item.status == .readyToPlay, "\(label): AVPlayer ready in \(String(format: "%.1f", readyIn))s (status \(item.status.rawValue) \(item.error?.localizedDescription ?? ""))")
        guard item.status == .readyToPlay else { return }

        player.playImmediately(atRate: 1)
        let playStart = Date()
        while player.currentTime().seconds < 0.5, Date().timeIntervalSince(playStart) < 15 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print(String(format: "info  %@: first audio %.1fs after ready", label, Date().timeIntervalSince(playStart)))
        try? await Task.sleep(for: .seconds(2))
        let t1 = player.currentTime().seconds
        check(t1 > 1, "\(label): plays from start: t=\(String(format: "%.1f", t1))")

        let middle = duration > 0 ? duration / 2 : 600
        await player.seek(to: CMTime(seconds: middle, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: 2)
        try? await Task.sleep(for: .seconds(3))
        var t2 = player.currentTime().seconds
        if t2 - middle <= 3 {
            // 偶發的「播放中但時間不走」：用 App 裡同一套輕推，要能自己恢復。
            print("info  \(label): stalled after seek (rate=\(player.rate) tcs=\(player.timeControlStatus.rawValue) t=\(t2)), nudging")
            await Player.nudge(player, rate: 2)
            let resumeAt = player.currentTime().seconds
            try? await Task.sleep(for: .seconds(3))
            t2 = player.currentTime().seconds
            check(t2 - resumeAt > 3, "\(label): recovered after nudge: advanced \(String(format: "%.1f", t2 - resumeAt))s in 3s")
        } else {
            check(true, "\(label): seek to \(Format.time(middle)) at 2×: advanced \(String(format: "%.1f", t2 - middle))s in 3s")
        }
        player.pause()
        if stream.isLocal {
            let blocks = Boost.processedBlocks.load(ordering: .relaxed) - blocksBefore
            check(blocks > 50, "\(label): boost tap processed \(blocks) audio blocks")
            Boost.gain = 1
        }
    }

    /// 自動更新（每 30 分鐘）不准碰帳號：在「已登入」的狀態下跑一次，帶 cookie 的 yt-dlp 呼叫次數不能增加。
    private static func refreshAvoidsAccount(channel: String) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-noacct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeCookies = dir.appendingPathComponent("cookies.txt")
        FileManager.default.createFile(atPath: fakeCookies.path, contents: Data("# test\n".utf8))
        let account = Account(cookieFile: fakeCookies, checkWebKit: false)
        let library = Library(directory: dir)
        library.account = account
        library.channels = [Channel(id: channel, title: "test")]
        let before = YTDLP.accountCalls.load(ordering: .relaxed)
        await library.refresh()
        let after = YTDLP.accountCalls.load(ordering: .relaxed)
        check(account.isLoggedIn && after == before && !library.episodes.isEmpty,
              "auto refresh while logged in makes no account requests (\(after - before))")
        check(WatchHistory.pingInterval >= 300, "watch-time reports at most every 5 minutes while playing")
    }

    private static func accountChecks() async {
        let props: [HTTPCookiePropertyKey: Any] = [.domain: ".youtube.com", .path: "/", .name: "__Secure-3PAPISID",
                                                   .value: "abc/def", .secure: "TRUE",
                                                   .expires: Date(timeIntervalSince1970: 1_900_000_000)]
        let cookie = HTTPCookie(properties: props)!
        let back = Account.parseNetscape(Account.netscape([cookie]))
        check(back.count == 1 && back[0].name == cookie.name && back[0].value == cookie.value
              && back[0].domain == ".youtube.com" && back[0].isSecure, "cookie file round trip")
        check(Account.isAccountDomain(".youtube.com") && Account.isAccountDomain("accounts.google.com")
              && !Account.isAccountDomain("notyoutube.com"), "account cookie domains")

        // 沒登入的影片頁也有回報網址，可以驗證解析；不送出回報。
        var request = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=2cq3ytwLrLk&hl=zh-TW")!)
        request.setValue(Account.userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await URLSession.shared.data(for: request) {
            let tracking = WatchHistory.parseTracking(html: String(decoding: data, as: UTF8.self))
            check(tracking?.playback.host?.hasSuffix("youtube.com") == true && tracking?.watchtime.path.contains("watchtime") == true,
                  "parse playbackTracking from watch page")
        } else {
            check(false, "fetch watch page")
        }

        do {
            let results = try await YTDLP.search("WWDC SwiftUI")
            check(results.count >= 10, "search returns \(results.count) results")
            check(results.filter { !$0.channelTitle.isEmpty }.count >= results.count - 2
                  && results.contains { $0.channelID.hasPrefix("https://www.youtube.com/") },
                  "search results carry channel info")
        } catch {
            check(false, "search: \(error.localizedDescription)")
        }

        // 已登入才測訂閱動態（只讀）。
        let cookieFile = Account.defaultCookieFile
        if FileManager.default.fileExists(atPath: cookieFile.path) {
            do {
                let feed = try await YTDLP.subscriptions(cookies: cookieFile)
                check(!feed.isEmpty, "subscriptions feed: \(feed.count) items, \(feed.filter(\.liveNow).count) live")
                check(feed.allSatisfy { !$0.channelID.contains("/feed/") && !$0.channelTitle.isEmpty }, "subscription items carry their own channel")
            } catch {
                check(false, "subscriptions: \(error.localizedDescription)")
            }
            do {
                let history = try await YTDLP.history(cookies: cookieFile)
                check(!history.isEmpty, "watch history: \(history.count) items")
            } catch {
                check(false, "history: \(error.localizedDescription)")
            }
        } else {
            print("info  not logged in, skipping subscriptions feed")
        }
    }

    private static func wait(_ limit: Double, until done: () -> Bool) async {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < limit { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private static func fixed(_ value: Double) -> String { String(format: "%.1f", value) }

    /// 播放清單、ADTS、解碼器：兩段連著解，取樣數要剛好是 frame 數 × 1024（沒有掉、沒有多），而且有聲音。
    private static func decoding(_ stream: ResolvedStream) async {
        do {
            var request = URLRequest(url: stream.url)
            for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
            let (text, _) = try await URLSession.shared.data(for: request)
            let playlist = try SegmentPlaylist.parse(String(decoding: text, as: UTF8.self), baseURL: stream.url)
            check(playlist.segments.count > 10 && playlist.index(at: 0) == 0
                  && playlist.index(at: playlist.duration + 5) == playlist.segments.count - 1
                  && playlist.index(at: playlist.segments[3].start + 0.01) == 3,
                  "segments: playlist has \(playlist.segments.count) segments, \(Format.time(playlist.duration))")
            var decoder: SegmentDecoder?
            var frames = 0, samples = 0, energy = 0.0, peak: Float = 0
            for segment in playlist.segments[5..<7] {
                var request = URLRequest(url: segment.url)
                for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let parsed = ADTS.parse(data) else {
                    check(false, "segments: segment is ADTS AAC")
                    return
                }
                if decoder == nil { decoder = SegmentDecoder(format: parsed.format) }
                guard let decoder else {
                    check(false, "segments: decoder for \(parsed.format)")
                    return
                }
                let pcm = decoder.decode(data, packets: parsed.packets)
                frames += parsed.packets.count
                samples += pcm.count / parsed.format.channels
                for x in pcm {
                    energy += Double(x * x)
                    peak = max(peak, abs(x))
                }
            }
            let rms = (energy / Double(max(1, samples * 2))).squareRoot()
            check(samples == frames * 1024, "segments: decoded \(frames) AAC frames into \(samples) samples, no gaps")
            check(rms > 0.0005 && peak <= 1.5, "segments: decoded audio is not silent (rms \(String(format: "%.4f", rms)), peak \(String(format: "%.2f", peak)))")
        } catch {
            check(false, "segments: \(error.localizedDescription)")
        }
        check(ADTS.parse(Data([0x47, 0x40, 0x00, 0x10, 0, 0, 0, 0, 0, 0])) == nil, "segments: MPEG-TS is rejected")
        let live = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,\na.aac\n"
        check((try? SegmentPlaylist.parse(live, baseURL: stream.url)) == nil
              && (try? SegmentPlaylist.parse(live + "#EXT-X-ENDLIST\n", baseURL: stream.url))?.segments.count == 1,
              "segments: playlist without an end (live) is rejected")
    }

    /// 自己解碼的 HLS：長度、開播、跳轉、2 倍和 3 倍速、放大不中斷、暫停、播到結尾。全程不出聲。
    private static func segments(_ stream: ResolvedStream, duration: Double) async {
        let engine = SegmentPlayer(stream: stream)
        engine.silent = true
        var length: Double?
        var failure: String?
        var finished = false
        engine.onReady = { length = $0 }
        engine.onFailed = { message, _ in failure = message }
        engine.onFinished = { finished = true }
        defer { engine.stop() }

        let started = Date()
        engine.load(at: 0)
        await wait(20) { length != nil || failure != nil }
        check(length != nil, "segments: ready in \(fixed(Date().timeIntervalSince(started)))s \(failure ?? "")")
        guard let length else { return }
        if duration > 0 {
            check(abs(length - duration) < 3, "segments: duration \(Format.time(length)) matches \(Format.time(duration))")
        }

        engine.play()
        let playStart = Date()
        await wait(15) { engine.currentTime > 0.5 }
        print("info  segments: first audio \(fixed(Date().timeIntervalSince(playStart)))s after ready")
        try? await Task.sleep(for: .seconds(2))
        check(engine.currentTime > 1.5, "segments: plays from start: t=\(fixed(engine.currentTime))")

        let middle = length / 2
        engine.rate = 2
        let seekStart = Date()
        engine.seek(to: middle)
        await wait(10) { engine.currentTime > middle + 0.2 }
        let seekDelay = Date().timeIntervalSince(seekStart)
        let from = engine.currentTime
        try? await Task.sleep(for: .seconds(3))
        var advanced = engine.currentTime - from
        check(seekDelay < 3 && advanced > 5 && advanced < 7,
              "segments: seek to \(Format.time(middle)) at 2×: audio after \(fixed(seekDelay))s, advanced \(fixed(advanced))s in 3s")
        if advanced <= 5 { print("info  segments: \(engine.debugState)") }

        // 往前跳 30 秒：分段已經先抓好了，不用等網路。
        let skipTo = engine.currentTime + 30
        let skipStart = Date()
        engine.seek(to: skipTo)
        await wait(5) { engine.currentTime > skipTo + 0.2 }
        let skipDelay = Date().timeIntervalSince(skipStart)
        check(skipDelay < 1, "segments: skip ahead 30s inside the fetched range: audio after \(String(format: "%.2f", skipDelay))s")

        // 放大：只換掉還沒播的音訊，不重新開始，位置照常前進。
        let before = engine.stats
        var at = engine.currentTime
        engine.volume = 1.6
        try? await Task.sleep(for: .seconds(2))
        advanced = engine.currentTime - at
        let after = engine.stats
        check(abs(engine.gain - 1.6) < 0.001 && after.rebakes == before.rebakes + 1 && after.restarts == before.restarts
              && after.rebakeFallbacks == before.rebakeFallbacks && advanced > 3.5 && advanced < 4.5,
              "segments: boost to 160% swaps queued audio without restarting (rebakes \(after.rebakes), fallbacks \(after.rebakeFallbacks), advanced \(fixed(advanced))s in 2s)")
        check(abs(engine.playingGain - 1.6) < 0.001 && abs(engine.effectiveVolume - 1.6) < 0.001,
              "segments: boosted audio is playing 2s later (×\(fixed(Double(engine.effectiveVolume))))")
        // 往下調：舊增益的音訊還在播，先用 renderer 的音量補，立刻生效；之後換成沒放大的音訊。
        engine.volume = 0.5
        check(engine.gain == 1 && abs(engine.playingGain - 1.6) < 0.001 && abs(engine.effectiveVolume - 0.5) < 0.001,
              "segments: turning down takes effect at once (×\(fixed(Double(engine.effectiveVolume))) while ×\(fixed(Double(engine.playingGain))) audio is still queued)")
        try? await Task.sleep(for: .seconds(2))
        check(engine.playingGain == 1 && abs(engine.effectiveVolume - 0.5) < 0.001 && engine.stats.restarts == before.restarts
              && engine.stats.rebakeFallbacks == before.rebakeFallbacks,
              "segments: unboosted audio takes over, still 50% (playing ×\(fixed(Double(engine.playingGain))), restarts \(engine.stats.restarts - before.restarts), fallbacks \(engine.stats.rebakeFallbacks - before.rebakeFallbacks), rebakes \(engine.stats.rebakes - before.rebakes))")
        engine.volume = 1

        engine.rate = 3
        at = engine.currentTime
        try? await Task.sleep(for: .seconds(2))
        advanced = engine.currentTime - at
        check(advanced > 5 && advanced < 7, "segments: 3× advanced \(fixed(advanced))s in 2s")

        engine.pause()
        at = engine.currentTime
        try? await Task.sleep(for: .seconds(1))
        check(abs(engine.currentTime - at) < 0.05, "segments: pause holds position")

        engine.seek(to: length - 5)
        engine.play()
        await wait(10) { finished }
        check(finished && engine.stats.underruns == 0,
              "segments: plays to the end and reports finished (underruns \(engine.stats.underruns), fetched \(engine.stats.segmentsFetched) segments)")
    }

    /// App 裡的實際流程：HLS 由 `SegmentPlayer` 播，音量拉過 100% 直接放大，不下載、不切換。
    private static func boostInline(_ ep: Episode) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-inline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedVolume = UserDefaults.standard.object(forKey: "volume")
        defer { UserDefaults.standard.set(savedVolume, forKey: "volume") }
        try? FileManager.default.removeItem(at: YTDLP.cacheDirectory.appendingPathComponent("\(ep.id).m4a"))

        // 自我測試跟裝好的 App 共用偏好設定，動過的要還原。
        let savedRate = UserDefaults.standard.object(forKey: "rate")
        defer { UserDefaults.standard.set(savedRate, forKey: "rate") }

        let player = Player(library: Library(directory: dir))
        player.silent = true
        player.volume = 1
        player.rate = 1
        player.play(ep)
        await wait(20) { player.isPlaying && player.position > 2 }
        check(player.isPlaying && player.segmentPlayer != nil && player.canBoost && player.avPlayer.currentItem == nil,
              "player decodes HLS itself and can boost right away")
        check(abs(player.duration - (ep.duration ?? 0)) < 3, "player duration \(Format.time(player.duration))")
        player.seek(to: 300)
        await wait(5) { player.position > 301 }
        player.volume = 1.6
        try? await Task.sleep(for: .seconds(2))
        check(!player.boostPending && !player.isLocalPlayback && player.isPlaying && !player.isLoading,
              "volume above 100% needs no download and no switch")
        check(abs((player.segmentPlayer?.gain ?? 0) - 1.6) < 0.001 && player.position > 302 && player.position < 310,
              "boost applied in place, position kept: \(Format.time(player.position))")
        player.pause()
        let paused = player.position
        try? await Task.sleep(for: .seconds(1))
        check(!player.isPlaying && abs((player.segmentPlayer?.currentTime ?? 0) - paused) < 0.6, "player pause stops the audio clock")
        player.toggle()
        await wait(5) { player.position > paused + 1 }
        check(player.isPlaying && player.position > paused + 1, "player resumes from the same spot")
        player.pause()
        player.volume = 1
    }

    /// 備援：`SegmentPlayer` 解不了、HLS 交給 AVPlayer 播的時候，音量拉過 100% 要在背景下載、從同一個位置切到本機檔。
    private static func boostSwitch(_ ep: Episode) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-boost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedVolume = UserDefaults.standard.object(forKey: "volume")
        defer { UserDefaults.standard.set(savedVolume, forKey: "volume") }
        try? FileManager.default.removeItem(at: YTDLP.cacheDirectory.appendingPathComponent("\(ep.id).m4a"))
        Player.useSegments = false
        defer { Player.useSegments = true }

        let player = Player(library: Library(directory: dir))
        player.silent = true
        player.volume = 1
        player.play(ep)
        await wait(20) { player.isPlaying && player.position > 2 }
        check(player.isPlaying && !player.isLocalPlayback && player.segmentPlayer == nil, "fallback: player starts on AVPlayer HLS at 100%")
        player.seek(to: 300)
        await wait(5) { player.position > 301 }
        player.volume = 1.6
        check(player.boostPending, "fallback: volume above 100% starts preparing boost")
        await wait(30) { player.isLocalPlayback && player.isPlaying && !player.isLoading && player.position > 300 }
        check(player.isLocalPlayback && player.isPlaying, "fallback: switched to local file and kept playing")
        check(player.position > 300 && player.position < 330,
              "fallback: kept position across the switch: \(Format.time(player.position))")
        check(abs(Boost.gain - 1.6) < 0.001 && player.avPlayer.volume == 1, "fallback: gain 1.6 with player volume capped at 1.0")
        player.pause()
        player.volume = 1
        try? FileManager.default.removeItem(at: YTDLP.cacheDirectory.appendingPathComponent("\(ep.id).m4a"))
    }

    /// 勾選頻道的直播檢查：按重新整理才查、不帶帳號；自動更新不動快取。
    private static func liveWatch() async {
        let lofi = await LiveProbe.check(channelID: "https://www.youtube.com/@LofiGirl", channelTitle: "Lofi Girl")
        check(lofi?.liveNow == true && lofi?.id.count == 11, "live probe: 24h stream channel is live (\(lofi?.title.prefix(30) ?? "nil"))")
        check(LiveProbe.parse(html: "<html><body>channel home, no player</body></html>", channelID: "x", channelTitle: "x") == nil,
              "live probe: channel page without a player is not live")
        let upcoming = #"ytInitialPlayerResponse = {"videoDetails":{"videoId":"abcDEF12345","title":"t","isUpcoming":true,"isLiveContent":true}};"#
        check(LiveProbe.parse(html: upcoming, channelID: "x", channelTitle: "x") == nil, "live probe: scheduled stream is not live")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-livewatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        library.channels = [Channel(id: "https://www.youtube.com/@LofiGirl", title: "Lofi Girl", watchLive: true),
                            Channel(id: "https://www.youtube.com/@AppleDeveloper", title: "Apple Developer")]
        let before = YTDLP.accountCalls.load(ordering: .relaxed)
        await library.checkLive()
        let lives = library.list(for: .live)
        check(!lives.isEmpty && lives.allSatisfy(\.liveNow) && library.liveChecked != nil,
              "live check finds \(lives.count) live on the ticked channel")
        check(lives.allSatisfy { $0.channelID.hasSuffix("@LofiGirl") }, "live check only looks at ticked channels")
        check(YTDLP.accountCalls.load(ordering: .relaxed) == before, "live check makes no account requests")
        let checked = library.liveChecked
        await library.refresh()
        check(library.liveChecked == checked && library.list(for: .live).map(\.id) == lives.map(\.id)
              && library.list(for: .live).allSatisfy(\.liveNow), "auto refresh keeps cached live status")
        let reloaded = Library(directory: dir)
        check(reloaded.list(for: .live).map(\.id) == lives.map(\.id) && reloaded.channels.first?.watchLive == true,
              "live status and ticks survive restart")
    }

    /// 24 小時直播的頻道，拿來測直播清單和直播播放。
    private static func live() async {
        do {
            let feed = try await YTDLP.tab(channelID: "https://www.youtube.com/@LofiGirl", path: "streams", limit: 5, isStream: true)
            guard let ep = feed.episodes.first(where: \.liveNow) else {
                check(false, "live: no live entry on @LofiGirl/streams")
                return
            }
            check(true, "live entry flagged: \(ep.title.prefix(40))")
            let stream = try await YTDLP.resolve(videoID: ep.id)
            check(stream.isLive && !stream.isLocal, "live resolves to HLS")
            let item = AVPlayerItem(asset: Player.makeAsset(stream))
            let player = AVPlayer(playerItem: item)
            player.volume = 0
            let started = Date()
            while item.status == .unknown, Date().timeIntervalSince(started) < 20 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            player.play()
            let t0 = player.currentTime().seconds
            try? await Task.sleep(for: .seconds(4))
            let advanced = player.currentTime().seconds - t0
            check(item.status == .readyToPlay && advanced > 1, "live plays: ready in \(String(format: "%.1f", Date().timeIntervalSince(started) - 4))s, advanced \(String(format: "%.1f", advanced))s")
            player.pause()

            // 直播一開播就在最新的地方；能回放的（這個頻道有約 1 小時窗口）可以往回拉、再一鍵回到最新。換集再回來也是從最新開始。
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let live = Player(library: Library(directory: dir))
            live.silent = true
            for round in 1...2 {
                live.play(ep)
                await wait(25) { live.isPlaying && live.liveWindow != nil && live.liveTime > 0 }
                check(live.isLive && live.isPlaying && live.isAtLiveEdge,
                      "live starts at the newest (play \(round)): behind \(fixed(live.liveBehind))s")
            }
            let window = live.liveWindow.map { $0.upperBound - $0.lowerBound } ?? 0
            check(live.canSeekLive, "live with DVR can seek: window \(Format.time(window))")
            live.skip(-60)
            await wait(10) { live.liveBehind > 50 && live.isPlaying && !live.isBuffering }
            try? await Task.sleep(for: .seconds(2))
            check(live.liveBehind > 50 && live.liveBehind < 90 && !live.isAtLiveEdge,
                  "live seek back 60s: behind \(fixed(live.liveBehind))s")
            live.pause()
            live.goLive()
            await wait(10) { live.isPlaying && live.isAtLiveEdge }
            try? await Task.sleep(for: .seconds(2))
            check(live.isPlaying && live.isAtLiveEdge, "go live jumps to the newest and plays: behind \(fixed(live.liveBehind))s")
            live.pause()
        } catch {
            check(false, "live: \(error.localizedDescription)")
        }
    }

    private static func persistence(channel: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Library(directory: dir)
        check(a.channels.isEmpty, "first launch starts with no channels")
        let ep = Episode(id: "abcDEF12345", title: "t", channelID: channel, channelTitle: "c", duration: 2901, published: Date())
        a.remember(ep)
        a.setProgress(ep.id, 1234)
        a.enqueue(ep.id)
        let b = Library(directory: dir)
        check(b.progress[ep.id] == 1234 && b.queue == [ep.id], "progress and queue survive reload")
        check(b.resumePosition(for: ep) == 1234, "resume position")
        b.markFinished(ep.id)
        check(b.resumePosition(for: ep) == 0 && b.queue.isEmpty, "finished restarts from 0 and leaves queue")
    }
}
