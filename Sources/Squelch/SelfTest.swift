import AppKit
import AVFoundation
import Foundation
import MediaPlayer

/// `Squelch.app/Contents/MacOS/Squelch --selftest`：不開視窗，實際連 YouTube 跑一次核心流程。
/// 驗證：網址解析、頻道清單、HLS 與下載備援兩條播放路徑（長度、開播、跳到中段、2 倍速）、SponsorBlock 查詢、存檔。
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

    /// App 裡的實際流程：播 HLS 時把音量拉過 100%，應該在背景下載、從同一個位置切到本機檔。
    private static func boostSwitch(_ ep: Episode) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-boost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedVolume = UserDefaults.standard.object(forKey: "volume")
        defer { UserDefaults.standard.set(savedVolume, forKey: "volume") }
        try? FileManager.default.removeItem(at: YTDLP.cacheDirectory.appendingPathComponent("\(ep.id).m4a"))

        let player = Player(library: Library(directory: dir))
        player.volume = 1
        player.avPlayer.isMuted = true
        player.play(ep)
        func wait(_ limit: Double, until done: () -> Bool) async {
            let start = Date()
            while !done(), Date().timeIntervalSince(start) < limit { try? await Task.sleep(for: .milliseconds(100)) }
        }
        await wait(20) { player.isPlaying && player.position > 2 }
        check(player.isPlaying && !player.isLocalPlayback, "player starts on HLS at 100%")
        player.seek(to: 300)
        await wait(5) { player.position > 301 }
        player.volume = 1.6
        check(player.boostPending, "volume above 100% starts preparing boost")
        await wait(30) { player.isLocalPlayback && player.isPlaying && !player.isLoading && player.position > 300 }
        check(player.isLocalPlayback && player.isPlaying, "switched to local file and kept playing")
        check(player.position > 300 && player.position < 330,
              "kept position across the switch: \(Format.time(player.position))")
        check(abs(Boost.gain - 1.6) < 0.001 && player.avPlayer.volume == 1, "gain 1.6 with player volume capped at 1.0")
        player.pause()
        player.volume = 1
        try? FileManager.default.removeItem(at: YTDLP.cacheDirectory.appendingPathComponent("\(ep.id).m4a"))
    }

    /// 勾選頻道的直播檢查：按重新整理才查、不帶帳號；自動更新不動快取。
    private static func liveWatch() async {
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
