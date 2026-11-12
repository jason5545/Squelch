import SwiftUI

/// 桌面迷你模式：浮在其他視窗上面的小播放器，拖背景就能移動。樣子跟底部播放列一樣：藍黑底、左邊透出封面的顏色。
/// 字幕開著時，下面多一塊字幕（高度固定，換句時視窗不會跳）。
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    @Environment(Subtitles.self) private var subtitles
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovering = false

    static let width: CGFloat = 380
    static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            if let ep = player.current {
                header(ep)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                MiniTransport()
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, subtitles.enabled ? 8 : 12)
                if subtitles.enabled {
                    MiniSubtitle()
                }
            } else {
                HStack {
                    Text("沒有在播").foregroundStyle(.secondary)
                    Spacer()
                    windowButtons
                }
                .padding(14)
            }
        }
        .frame(width: Self.width)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
    }

    private func header(_ ep: Episode) -> some View {
        HStack(spacing: 10) {
            Button { expand() } label: {
                Thumbnail(url: ep.thumbnail, cornerRadius: 5)
                    .frame(width: 72, height: 40)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
            .buttonStyle(PressStyle())
            .help("回到完整視窗")
            VStack(alignment: .leading, spacing: 1) {
                Text(ep.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.statusText ?? ep.channelTitle)
                    .font(.caption)
                    .foregroundStyle(player.statusText == nil ? .secondary : player.statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            windowButtons
        }
    }

    /// 回到完整視窗、關掉迷你視窗。滑鼠移進來才顯示，平常不搶畫面。
    private var windowButtons: some View {
        HStack(spacing: 2) {
            Button { expand() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("回到完整視窗（⌘⇧M）")
            Button { dismissWindow(id: "mini") } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("關掉迷你視窗（照樣在背景播）")
        }
        .opacity(hovering || player.current == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var background: some View {
        let tint = player.current.flatMap { ArtworkPalette.shared.color(for: $0.thumbnail) } ?? Theme.amber
        return ZStack {
            Theme.bar
            LinearGradient(colors: [tint.opacity(0.34), tint.opacity(0.1), .clear],
                           startPoint: .leading, endPoint: .trailing)
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
    }

    private func expand() {
        openWindow(id: "main")
        NSApp.activate()
        dismissWindow(id: "mini")
    }
}

/// 倒退、播放、快轉，加一條細進度條。直播沒有進度，只標「直播中」。
private struct MiniTransport: View {
    @Environment(Player.self) private var player
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(player.isLive && !player.canSeekLive)
            .help("倒退 15 秒")
            PlayCircle(size: 32, playing: player.isPlaying,
                       loading: player.isLoading || (player.isPlaying && player.isBuffering)) { player.toggle() }
                .help("播放／暫停")
            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(player.isLive && (!player.canSeekLive || player.isAtLiveEdge))
            .help("快轉 30 秒")
            timeline
        }
    }

    @ViewBuilder private var timeline: some View {
        if player.isLive {
            HStack(spacing: 6) {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                Text(player.isAtLiveEdge ? "直播中" : "落後 \(Format.time(player.liveBehind))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.live)
                Spacer()
            }
        } else {
            let position = scrubbing ?? player.position
            HStack(spacing: 8) {
                Text(Format.time(position))
                    .frame(width: 44, alignment: .trailing)
                ThinSlider(value: position, range: 0...max(player.duration, 1),
                           marks: player.segments.map { $0.start...$0.end }) { scrubbing = $0 } onEnded: { target in
                    player.seek(to: target)
                    scrubbing = nil
                }
                .disabled(player.duration <= 0)
                Text("-" + Format.time(max(0, player.duration - position)))
                    .frame(width: 48, alignment: .leading)
            }
            .font(.timecodeSmall)
            .foregroundStyle(.secondary)
        }
    }
}

/// 迷你視窗的字幕：上面正體中文，下面小字原文。高度固定兩行加一行。
private struct MiniSubtitle: View {
    @Environment(Player.self) private var player
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        let cue = subtitles.cue(at: player.subtitleClock)
        VStack(spacing: 2) {
            if let cue {
                Text(cue.translation ?? cue.text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(cue.translation == nil ? Color.white.opacity(0.6) : .white)
                    .lineLimit(2)
                if let translation = cue.translation, translation != cue.text {
                    Text(cue.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let note = SubtitleStrip.note(subtitles) {
                Text(note).font(.caption).foregroundStyle(.secondary)
                if subtitles.offerSpeech { SpeechOfferButton().font(.caption.weight(.semibold)) }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .padding(.horizontal, 14)
        .background {
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: cue)
    }
}
