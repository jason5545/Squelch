import SwiftUI

/// 視窗右側的「正在播放」面板（inspector，可收合）：模糊封面當背景，大封面、標題、倍速、音量放大、接下來。
/// 播放鍵和進度在底部的播放列（`NowPlayingBar`），這裡不重複。時間碼一律用等寬字。
struct PlayerPanel: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let ep = player.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("正在播放")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.6))
                    Artwork(episode: ep, playing: player.isPlaying)
                    info(ep)
                    if !player.isLive {
                        RateControl()
                    }
                    VolumeControl()
                    UpNext()
                }
                .padding(20)
            }
            .background { AmbientBackground(url: ep.thumbnail) }
        } else {
            ContentUnavailableView("沒有在播", systemImage: "waveform",
                                   description: Text("點清單裡的影片開始播放。"))
                .background(Theme.base)
        }
    }

    private func info(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ep.title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline) {
                Text(ep.channelTitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                Button { NSWorkspace.shared.open(ep.watchURL) } label: {
                    Image(systemName: "safari").font(.body.weight(.semibold))
                }
                .buttonStyle(GlyphButtonStyle())
                .help("在 YouTube 開啟")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ep.watchURL.absoluteString, forType: .string)
                } label: {
                    Image(systemName: "link").font(.body.weight(.semibold))
                }
                .buttonStyle(GlyphButtonStyle())
                .help("複製影片網址")
            }
            if let status = player.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(player.statusColor)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Player {
    /// 錯誤、提示（已跳過贊助片段）、載入中、會跳過幾段。播放列和面板共用。
    var statusText: String? {
        if let error = errorMessage { return error }
        if let notice { return notice }
        if isLoading { return String(localized: "載入中…") }
        if !segments.isEmpty { return String(localized: "會跳過 \(segments.count) 段") }
        return nil
    }

    var statusColor: Color {
        if errorMessage != nil { return Theme.live }
        if notice != nil { return Theme.sponsor }
        return .secondary
    }

    var volumeSymbol: String {
        switch volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var volumeLabel: String {
        if boostPending { return String(localized: "準備中") }
        return "\(Int((volume * 100).rounded()))%"
    }

    var volumeHelp: String {
        if volume <= 1 { return String(localized: "音量（⌘↑ ⌘↓）。超過 100% 會放大，YouTube 通常比 Spotify 小聲。") }
        if isLive { return String(localized: "直播沒辦法放大，最大就是 100%") }
        if boostPending { return String(localized: "正在下載音軌，下載好就會放大") }
        return canBoost ? String(localized: "放大中") : String(localized: "超過 100% 要先下載音軌")
    }
}

/// 等寬時間碼的字型，面板和清單共用。
extension Font {
    static let timecode = Font.callout.monospaced()
    static let timecodeSmall = Font.caption2.monospaced()
}

/// 面板背景：封面放大、高度模糊，再壓一層暗色，字才看得清楚。
private struct AmbientBackground: View {
    let url: URL

    var body: some View {
        ZStack {
            Theme.base
            if let ambient = ArtworkPalette.shared.ambient(for: url) {
                Image(decorative: ambient, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .blur(radius: 30)
                    .saturation(1.4)
                    .opacity(0.9)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: url)
    }
}

/// 大封面。暫停時縮一點，繼續播時彈回來。
private struct Artwork: View {
    let episode: Episode
    let playing: Bool

    var body: some View {
        Thumbnail(url: episode.thumbnail, cornerRadius: 12)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(playing ? 0.5 : 0.3), radius: playing ? 22 : 10, y: playing ? 12 : 5)
            .scaleEffect(playing ? 1 : 0.9)
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: playing)
    }
}

/// 一排倍速按鈕，點一下就換。
private struct RateControl: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("播放速度").font(.headline)
                Spacer()
                Text(Format.rate(player.rate)).font(.timecode).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(Player.rates, id: \.self) { rate in
                    let on = rate == player.rate
                    Button { player.rate = rate } label: {
                        Text(String(Format.rate(rate).dropLast()))
                            .font(.timecodeSmall.weight(on ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? Theme.amber : .clear, in: Capsule())
                            .foregroundStyle(on ? Theme.onAmber : .white.opacity(0.85))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .help("播放速度（⌘[ ⌘]）")
    }
}

/// 音量 0–200%：喇叭圖示點了靜音，滑桿上的刻度是 100%，超過的部分是放大，變珊瑚紅。
struct VolumeControl: View {
    @Environment(Player.self) private var player

    var body: some View {
        let boosting = player.volume > 1
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(boosting ? "音量 · 放大" : "音量").font(.headline)
                Spacer()
                Text(player.volumeLabel)
                    .font(.timecode)
                    .foregroundStyle(boosting ? Theme.boost : .secondary)
            }
            HStack(spacing: 10) {
                Button { player.toggleMute() } label: {
                    Image(systemName: player.volumeSymbol).frame(width: 22)
                }
                .buttonStyle(GlyphButtonStyle())
                .help(player.volume == 0 ? "取消靜音" : "靜音")
                ThinSlider(value: Double(player.volume), range: 0...2,
                           fill: boosting ? Theme.boost : .white,
                           activeFill: boosting ? Theme.boost : Theme.amber,
                           tick: 1, step: 0.05) { player.volume = Float($0) }
                    .help(player.volumeHelp)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 放大時才顯示的說明，平常不佔位置。
    private var note: String? {
        guard player.volume > 1 else { return nil }
        if player.isLive { return String(localized: "直播沒辦法放大，最大就是 100%") }
        if player.boostPending { return String(localized: "正在下載音軌，下載好就會放大") }
        return player.canBoost ? nil : String(localized: "超過 100% 要先下載音軌")
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("接下來").font(.headline)
                Spacer()
                if !upcoming.isEmpty {
                    Text(upcoming.count, format: .number).font(.timecode).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)
            if upcoming.isEmpty {
                Text("待播清單是空的。在影片上按右鍵，選「加到待播清單」。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(upcoming) { UpNextRow(episode: $0) }
            }
        }
    }
}

private struct UpNextRow: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let episode: Episode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: episode.thumbnail, cornerRadius: 5)
                .frame(width: 64, height: 36)
                .overlay {
                    if hovering {
                        RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(.caption.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 4) {
                    Text(episode.channelTitle).lineLimit(1)
                    if let d = episode.duration {
                        Spacer(minLength: 4)
                        Text(Format.time(d)).font(.timecodeSmall)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { player.play(episode) }
        .contextMenu {
            Button("播放") { player.play(episode) }
            Button("移出待播清單") { library.dequeue(episode.id) }
        }
    }
}
