import SwiftUI

/// 桌面迷你模式：浮在其他視窗上面的小播放器，拖背景就能移動。樣子跟底部播放列一樣：藍黑底、左邊透出封面的顏色。
/// 上排是封面、標題，右邊字幕開關和倍速；下排是播放控制和進度。字幕開著時，下面多一塊字幕（高度固定，換句時視窗不會跳）。
/// 回到完整視窗和關閉都不佔位置：滑鼠移到封面上出現放大圖示，關閉鈕在左上角，滑鼠移進來才出現。
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    @Environment(Subtitles.self) private var subtitles
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovering = false
    @State private var hoveringArtwork = false

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
                    Button("打開 Squelch") { expand() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.amber)
                }
                .padding(14)
            }
        }
        .frame(width: Self.width)
        .overlay(alignment: .topLeading) { closeButton }
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
                    .overlay {
                        // 滑鼠移到封面上：變暗、出現放大圖示，點了回到完整視窗。
                        if hoveringArtwork {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.5))
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
            .buttonStyle(PressStyle())
            .onHover { hoveringArtwork = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringArtwork)
            .help("回到完整視窗（⌘⇧M）")
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
            MiniExtras()
        }
    }

    /// 左上角的關閉鈕（照樣在背景播）。滑鼠移進視窗才出現。
    private var closeButton: some View {
        Button { dismissWindow(id: "mini") } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(white: 0.25)))
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(PressStyle())
        .help("關掉迷你視窗（照樣在背景播）")
        .padding(6)
        .opacity(hovering ? 1 : 0)
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
    @Environment(Library.self) private var library
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 10) {
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
            Button { player.playNext() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(library.queue.filter { $0 != player.current?.id }.isEmpty)
            .help("下一集（待播清單）")
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
            HStack(spacing: 6) {
                Text(Format.time(position))
                    .frame(width: 40, alignment: .trailing)
                ThinSlider(value: position, range: 0...max(player.duration, 1),
                           marks: player.segments.map { $0.start...$0.end }) { scrubbing = $0 } onEnded: { target in
                    player.seek(to: target)
                    scrubbing = nil
                }
                .disabled(player.duration <= 0)
                Text("-" + Format.time(max(0, player.duration - position)))
                    .frame(width: 44, alignment: .leading)
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

/// 上排右邊：字幕開關、倍速（直播沒有倍速）。
private struct MiniExtras: View {
    @Environment(Player.self) private var player
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        HStack(spacing: 6) {
            Button { subtitles.enabled.toggle() } label: {
                Image(systemName: subtitles.enabled ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GlyphButtonStyle(active: subtitles.enabled))
            .help(subtitles.enabled ? String(localized: "關掉字幕") : String(localized: "顯示字幕（翻成\(subtitles.target.name)）"))
            if !player.isLive {
                Menu {
                    ForEach(Player.rates, id: \.self) { rate in
                        Toggle(Format.rate(rate), isOn: Binding(get: { player.rate == rate }, set: { _ in player.rate = rate }))
                    }
                } label: {
                    Text(Format.rate(player.rate))
                        .font(.timecodeSmall.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(player.rate == 1 ? Color.white.opacity(0.1) : Theme.amber))
                        .foregroundStyle(player.rate == 1 ? Color.white.opacity(0.8) : Theme.onAmber)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("播放速度（⌘[ ⌘]）")
            }
        }
    }
}
