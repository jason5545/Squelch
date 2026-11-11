import SwiftUI

/// 視窗右側的「正在播放」面板（inspector，可收合）。
/// 倍速、音量放大、SponsorBlock 片段、待播清單各有自己的位置；時間碼一律用等寬字。
struct PlayerPanel: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let ep = player.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Artwork(episode: ep)
                    info(ep)
                    Timeline()
                    Transport()
                    if !player.isLive {
                        RateControl()
                    }
                    VolumeControl()
                    Divider()
                    UpNext()
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("沒有在播", systemImage: "waveform",
                                   description: Text("點清單裡的影片開始播放。"))
        }
    }

    private func info(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ep.title)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
            Text(ep.channelTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let status = statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String? {
        if let error = player.errorMessage { return error }
        if let notice = player.notice { return notice }
        if player.isLoading { return String(localized: "載入中…") }
        if !player.segments.isEmpty { return String(localized: "會跳過 \(player.segments.count) 段") }
        return nil
    }

    private var statusColor: Color {
        if player.errorMessage != nil { return .red }
        if player.notice != nil { return .green }
        return .secondary
    }
}

/// 等寬時間碼的字型，面板和清單共用。
extension Font {
    static let timecode = Font.callout.monospaced()
    static let timecodeSmall = Font.caption2.monospaced()
}

private struct Artwork: View {
    let episode: Episode

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: episode.thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// 進度條、SponsorBlock 片段、經過／剩下的時間碼。直播只顯示已聽多久。
private struct Timeline: View {
    @Environment(Player.self) private var player
    @State private var scrubbing: Double?

    var body: some View {
        if player.isLive {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("直播中").font(.callout.weight(.semibold))
                Spacer()
                Text("已聽 \(Format.time(player.position))")
                    .font(.timecode)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 2) {
                Slider(value: Binding(
                    get: { scrubbing ?? player.position },
                    set: { scrubbing = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target)
                        scrubbing = nil
                    }
                }
                .controlSize(.small)
                .disabled(player.duration <= 0)
                .overlay { segmentMarks }
                HStack {
                    Text(Format.time(scrubbing ?? player.position))
                    Spacer()
                    Text("-" + Format.time(max(0, player.duration - (scrubbing ?? player.position))))
                }
                .font(.timecode)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 進度條下方標出 SponsorBlock 會跳過的片段。
    private var segmentMarks: some View {
        GeometryReader { geo in
            let total = max(player.duration, 1)
            ForEach(player.segments, id: \.self) { seg in
                Rectangle()
                    .fill(.green.opacity(0.7))
                    .frame(width: max(2, geo.size.width * (seg.end - seg.start) / total), height: 3)
                    .offset(x: geo.size.width * seg.start / total, y: geo.size.height / 2 + 5)
                    .help("\(seg.label)：會自動跳過")
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Transport: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 22) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .help("倒退 15 秒（⌘←）")
                .disabled(player.isLive)
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(.tint)
                    if player.isLoading || (player.isPlaying && player.isBuffering) {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: 48, height: 48)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("播放／暫停（空白鍵、⌘↩）")
            Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                .help("快轉 30 秒（⌘→）")
                .disabled(player.isLive)
            Button { player.playNext() } label: { Image(systemName: "forward.end.fill") }
                .disabled(library.queue.filter { $0 != player.current?.id }.isEmpty)
                .help("下一集（待播清單）")
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .frame(maxWidth: .infinity)
    }
}

/// 一排倍速按鈕，點一下就換。
private struct RateControl: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("播放速度")
                Spacer()
                Text(Format.rate(player.rate)).font(.timecode)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(Player.rates, id: \.self) { rate in
                    let on = rate == player.rate
                    Button { player.rate = rate } label: {
                        Text(String(Format.rate(rate).dropLast()))
                            .font(.timecodeSmall)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(on ? .white : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .help("播放速度（⌘[ ⌘]）")
    }
}

/// 音量 0–200%：喇叭圖示點了靜音，滑桿中間的刻度是 100%，超過的部分是放大，變橘色。
struct VolumeControl: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        let boosting = player.volume > 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(boosting ? "音量 · 放大" : "音量")
                Spacer()
                Text(label)
                    .font(.timecode)
                    .foregroundStyle(boosting ? .orange : .secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { player.toggleMute() } label: {
                    Image(systemName: icon).frame(width: 22)
                }
                .buttonStyle(.borderless)
                .help(player.volume == 0 ? "取消靜音" : "靜音")
                Slider(value: $player.volume, in: 0...2)
                    .controlSize(.small)
                    .tint(boosting ? .orange : .accentColor)
                    .overlay {
                        // 100% 的刻度：左右內縮一樣多，正中間就是 100%。
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.secondary)
                                .frame(width: 1, height: 6)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2 + 9)
                        }
                        .allowsHitTesting(false)
                    }
                    .help(help)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch player.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private var label: String {
        if player.boostPending { return String(localized: "準備中") }
        return "\(Int((player.volume * 100).rounded()))%"
    }

    /// 放大時才顯示的說明，平常不佔位置。
    private var note: String? {
        guard player.volume > 1 else { return nil }
        if player.isLive { return String(localized: "直播沒辦法放大，最大就是 100%") }
        if player.boostPending { return String(localized: "正在下載音軌，下載好就會放大") }
        return player.canBoost ? nil : String(localized: "超過 100% 要先下載音軌")
    }

    private var help: String {
        if player.volume <= 1 { return String(localized: "音量（⌘↑ ⌘↓）。超過 100% 會放大，YouTube 通常比 Spotify 小聲。") }
        if player.isLive { return String(localized: "直播沒辦法放大，最大就是 100%") }
        if player.boostPending { return String(localized: "正在下載音軌，下載好就會放大") }
        return player.canBoost ? String(localized: "放大中") : String(localized: "超過 100% 要先下載音軌")
    }
}

/// 待播清單裡接下來要播的。點一下直接播。
private struct UpNext: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        let upcoming = library.queue
            .filter { $0 != player.current?.id }
            .compactMap { library.episodes[$0] }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("接下來")
                Spacer()
                if !upcoming.isEmpty {
                    Text(upcoming.count, format: .number).font(.timecode)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if upcoming.isEmpty {
                Text("待播清單是空的。在影片上按右鍵，選「加到待播清單」。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(upcoming) { ep in
                    HStack(spacing: 8) {
                        AsyncImage(url: ep.thumbnail) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(.quaternary)
                        }
                        .frame(width: 56, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).font(.caption).lineLimit(2)
                            HStack(spacing: 4) {
                                Text(ep.channelTitle).lineLimit(1)
                                if let d = ep.duration {
                                    Spacer(minLength: 4)
                                    Text(Format.time(d)).font(.timecodeSmall)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(ep) }
                    .contextMenu {
                        Button("播放") { player.play(ep) }
                        Button("移出待播清單") { library.dequeue(ep.id) }
                    }
                }
            }
        }
    }
}
