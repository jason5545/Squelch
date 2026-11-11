import AVFoundation
import Foundation

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
            let segments = await SponsorBlock.segments(videoID: ep.id, categories: ["sponsor", "selfpromo"])
            print("info  SponsorBlock segments: \(segments.map { "\($0.category) \(Format.time($0.start))–\(Format.time($0.end))" })")
        }

        persistence(channel: channel)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    private static func playback(_ stream: ResolvedStream, duration: Double, label: String) async {
        let item = AVPlayerItem(asset: Player.makeAsset(stream))
        item.audioTimePitchAlgorithm = .timeDomain
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
        let t2 = player.currentTime().seconds
        check(t2 - middle > 3, "\(label): seek to \(Format.time(middle)) at 2×: advanced \(String(format: "%.1f", t2 - middle))s in 3s")
        player.pause()
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
