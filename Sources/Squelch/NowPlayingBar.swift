import SwiftUI

/// 視窗底部的播放列：左邊是正在播的集數（點封面開關右側面板），中間是播放鍵和進度，右邊是倍速、音量、面板開關。
/// 沒在播時整條收起來。
struct NowPlayingBar: View {
    @Environment(Player.self) private var player
    @Binding var showPanel: Bool

    var body: some View {
        if let ep = player.current {
            HStack(spacing: 20) {
                nowPlaying(ep)
                    .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    BarTransport()
                    BarTimeline()
                }
                .frame(minWidth: 320, maxWidth: 600)
                BarExtras(showPanel: $showPanel)
                    .frame(minWidth: 200, maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 84)
            .background { background(ep) }
        }
    }

    private func nowPlaying(_ ep: Episode) -> some View {
        HStack(spacing: 12) {
            Button { showPanel.toggle() } label: {
                Thumbnail(url: ep.thumbnail, cornerRadius: 6)
                    .frame(width: 96, height: 54)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
            .buttonStyle(PressStyle())
            .help(showPanel ? "收起正在播放" : "顯示正在播放")
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(ep.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let status = player.statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(player.statusColor)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 藍黑底，左邊淡淡透出封面的顏色。
    private func background(_ ep: Episode) -> some View {
        let tint = ArtworkPalette.shared.color(for: ep.thumbnail) ?? Theme.amber
        return ZStack {
            Theme.bar
            LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.08), .clear],
                           startPoint: .leading, endPoint: .trailing)
            VStack {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
    }
}

private struct BarTransport: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 26) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .help("倒退 15 秒（⌘←）")
            .disabled(player.isLive && !player.canSeekLive)
            PlayCircle(size: 38, playing: player.isPlaying,
                       loading: player.isLoading || (player.isPlaying && player.isBuffering)) { player.toggle() }
                .help("播放／暫停（空白鍵、⌘↩）")
            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .help("快轉 30 秒（⌘→）")
            .disabled(player.isLive && (!player.canSeekLive || player.isAtLiveEdge))
            Button { player.playNext() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(library.queue.filter { $0 != player.current?.id }.isEmpty)
            .help("下一集（待播清單）")
        }
    }
}

/// 進度條、SponsorBlock 片段、經過／剩下的時間碼。直播不顯示聽了多久：能回放的顯示落後最新多少和「回到直播」，不能的只標「直播中」。
private struct BarTimeline: View {
    @Environment(Player.self) private var player
    @State private var scrubbing: Double?

    var body: some View {
        if player.isLive && player.canSeekLive, let window = player.liveWindow {
            // 有回放窗口的直播：可以往回拉，左邊是落後最新多少，右邊一鍵回到最新。
            let time = scrubbing ?? player.liveTime
            let behind = max(0, window.upperBound - time)
            let atEdge = scrubbing == nil ? player.isAtLiveEdge : behind < 15
            HStack(spacing: 10) {
                Text(atEdge ? "0:00" : "-" + Format.time(behind))
                    .frame(width: 56, alignment: .trailing)
                ThinSlider(value: time, range: window, fill: Theme.live) { scrubbing = $0 } onEnded: { target in
                    player.seekLive(to: target)
                    scrubbing = nil
                }
                .help("拖曳可以往回聽")
                LiveBadge(atEdge: atEdge) { player.goLive() }
                    .frame(width: 56, alignment: .leading)
            }
            .font(.timecodeSmall)
            .foregroundStyle(.secondary)
        } else if player.isLive {
            HStack(spacing: 6) {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                Text("直播中").font(.caption.weight(.bold)).foregroundStyle(Theme.live)
            }
            .frame(height: 16)
        } else {
            let position = scrubbing ?? player.position
            HStack(spacing: 10) {
                Text(Format.time(position))
                    .frame(width: 56, alignment: .trailing)
                ThinSlider(value: position, range: 0...max(player.duration, 1),
                           marks: player.segments.map { $0.start...$0.end }) { scrubbing = $0 } onEnded: { target in
                    player.seek(to: target)
                    scrubbing = nil
                }
                .disabled(player.duration <= 0)
                .help(player.segments.isEmpty ? "" : String(localized: "綠色的片段會自動跳過"))
                Text("-" + Format.time(max(0, player.duration - position)))
                    .frame(width: 56, alignment: .leading)
            }
            .font(.timecodeSmall)
            .foregroundStyle(.secondary)
        }
    }
}

/// 直播標記：在最新的地方是實心紅點「直播」；落後時變成可以按的「回到直播」。
private struct LiveBadge: View {
    var atEdge: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(atEdge ? Theme.live : Color.white.opacity(0.5)).frame(width: 6, height: 6)
                Text(atEdge ? "直播" : "回到直播")
                    .font(.caption2.weight(.bold))
                    .fixedSize()
            }
            .foregroundStyle(atEdge ? Theme.live : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .disabled(atEdge)
        .help(atEdge ? "正在聽最新的" : "跳回最新的地方")
    }
}

/// 播放列右邊：倍速、音量、字幕、迷你模式、面板開關。
private struct BarExtras: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var showPanel: Bool

    var body: some View {
        HStack(spacing: 14) {
            if !player.isLive {
                Menu {
                    ForEach(Player.rates, id: \.self) { rate in
                        Toggle(Format.rate(rate), isOn: Binding(get: { player.rate == rate }, set: { _ in player.rate = rate }))
                    }
                } label: {
                    Text(Format.rate(player.rate))
                        .font(.timecodeSmall.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(player.rate == 1 ? Color.white.opacity(0.1) : Theme.amber))
                        .foregroundStyle(player.rate == 1 ? Color.white.opacity(0.8) : Theme.onAmber)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("播放速度（⌘[ ⌘]）")
            }
            BarVolume()
            SubtitleToggle()
            Button {
                openWindow(id: "mini")
                dismissWindow(id: "main")
            } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("迷你模式（⌘⇧M）")
            Button { showPanel.toggle() } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottom) {
                        if showPanel { Circle().fill(Theme.amber).frame(width: 4, height: 4).offset(y: 6) }
                    }
            }
            .buttonStyle(GlyphButtonStyle(active: showPanel))
            .help(showPanel ? "收起正在播放" : "顯示正在播放")
        }
    }
}

/// 音量 0–200%：喇叭點了靜音，刻度是 100%，超過的部分是放大，變珊瑚紅。
private struct BarVolume: View {
    @Environment(Player.self) private var player

    var body: some View {
        let boosting = player.volume > 1
        HStack(spacing: 8) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.volumeSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
            }
            .buttonStyle(GlyphButtonStyle())
            .help(player.volume == 0 ? "取消靜音" : "靜音")
            ThinSlider(value: Double(player.volume), range: 0...2,
                       fill: boosting ? Theme.boost : .white,
                       activeFill: boosting ? Theme.boost : Theme.amber,
                       tick: 1, step: 0.05) { player.volume = Float($0) }
                .frame(width: 96)
                .help(player.volumeHelp)
            Text(player.volumeLabel)
                .font(.timecodeSmall)
                .foregroundStyle(boosting ? Theme.boost : .secondary)
                .frame(width: 40, alignment: .leading)
        }
    }
}
