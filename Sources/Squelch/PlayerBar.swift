import SwiftUI

struct PlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var scrubbing: Double?

    var body: some View {
        if let ep = player.current {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    AsyncImage(url: ep.thumbnail) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ep.title).lineLimit(1).font(.headline)
                        Text(statusLine(ep)).lineLimit(1).font(.caption).foregroundStyle(statusColor)
                    }
                    Spacer(minLength: 12)

                    controls
                }

                if player.isLive {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("直播中").font(.caption.weight(.semibold))
                        Text("已聽 \(Format.time(player.position))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 92)
                } else {
                HStack(spacing: 8) {
                    Text(Format.time(scrubbing ?? player.position))
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                    Slider(value: Binding(
                        get: { scrubbing ?? player.position },
                        set: { scrubbing = $0 }),
                           in: 0...max(player.duration, 1)) { editing in
                        if !editing, let target = scrubbing {
                            player.seek(to: target)
                            scrubbing = nil
                        }
                    }
                    .disabled(player.duration <= 0)
                    .overlay { segmentMarks }
                    Text("-" + Format.time(max(0, player.duration - (scrubbing ?? player.position))))
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .leading)
                }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .help("倒退 15 秒（⌘←）")
                .disabled(player.isLive)
            Button { player.toggle() } label: {
                ZStack {
                    if player.isLoading || (player.isPlaying && player.isBuffering) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 28, height: 28)
            }
            .font(.title2)
            .help("播放／暫停（空白鍵、⌘↩）")
            Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                .help("快轉 30 秒（⌘→）")
                .disabled(player.isLive)
            Button { player.playNext() } label: { Image(systemName: "forward.end.fill") }
                .disabled(library.queue.filter { $0 != player.current?.id }.isEmpty)
                .help("下一集（待播清單）")
            Menu {
                ForEach(Player.rates, id: \.self) { rate in
                    Button {
                        player.rate = rate
                    } label: {
                        if rate == player.rate {
                            Label(Format.rate(rate), systemImage: "checkmark")
                        } else {
                            Text(Format.rate(rate))
                        }
                    }
                }
            } label: {
                Text(Format.rate(player.rate)).monospacedDigit()
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(player.isLive)

            VolumeControl()
            .help("播放速度（⌘[ ⌘]）")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    /// 進度條上標出 SponsorBlock 會跳過的片段。
    private var segmentMarks: some View {
        GeometryReader { geo in
            let total = max(player.duration, 1)
            ForEach(player.segments, id: \.self) { seg in
                Rectangle()
                    .fill(.green.opacity(0.6))
                    .frame(width: max(2, geo.size.width * (seg.end - seg.start) / total), height: 3)
                    .offset(x: geo.size.width * seg.start / total, y: geo.size.height / 2 + 5)
                    .help("\(seg.label)：會自動跳過")
            }
        }
        .allowsHitTesting(false)
    }

    private func statusLine(_ ep: Episode) -> String {
        if let error = player.errorMessage { return error }
        if let notice = player.notice { return notice }
        if player.isLoading { return String(localized: "\(ep.channelTitle) · 載入中…") }
        let skips = player.segments.isEmpty ? "" : String(localized: " · 會跳過 \(player.segments.count) 段")
        return ep.channelTitle + skips
    }

    private var statusColor: Color {
        if player.errorMessage != nil { return .red }
        if player.notice != nil { return .green }
        return .secondary
    }
}

/// Spotify 式音量：喇叭圖示點了靜音，旁邊一條滑桿。滑桿到 200%，超過 100% 的部分是放大。
struct VolumeControl: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: {
                Image(systemName: icon)
                    .frame(width: 22)
            }
            .help(player.volume == 0 ? "取消靜音" : "靜音")
            Slider(value: $player.volume, in: 0...2)
                .frame(width: 110)
                .controlSize(.small)
                .tint(player.volume > 1 ? .orange : .accentColor)
                .help(help)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(player.volume > 1 ? .orange : .secondary)
                .frame(width: 40, alignment: .leading)
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

    private var help: String {
        if player.volume <= 1 { return String(localized: "音量（⌘↑ ⌘↓）。超過 100% 會放大，YouTube 通常比 Spotify 小聲。") }
        if player.isLive { return String(localized: "直播沒辦法放大，最大就是 100%") }
        if player.boostPending { return String(localized: "正在下載音軌，下載好就會放大") }
        return player.isLocalPlayback ? String(localized: "放大中") : String(localized: "超過 100% 要先下載音軌")
    }
}
