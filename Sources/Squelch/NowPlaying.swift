import AppKit
import MediaPlayer

/// 控制中心的「正在播放」和媒體鍵（F7–F9、耳機按鍵）。
@MainActor
final class NowPlaying {
    private weak var player: Player?
    private var artwork: MPMediaItemArtwork?
    private var artworkID: String?

    func attach(_ player: Player) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player, MPRemoteCommandEvent) -> Void) {
            // @Sendable：系統可能在背景執行緒呼叫，不能綁在主執行緒（見 artwork 的說明）。
            command.addTarget { @Sendable [weak player] event in
                nonisolated(unsafe) let event = event
                Task { @MainActor in
                    if let player { action(player, event) }
                }
                return .success
            }
        }
        on(center.playCommand) { p, _ in p.resume() }
        on(center.pauseCommand) { p, _ in p.pause() }
        on(center.togglePlayPauseCommand) { p, _ in p.toggle() }
        center.skipForwardCommand.preferredIntervals = [30]
        on(center.skipForwardCommand) { p, _ in p.skip(30) }
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipBackwardCommand) { p, _ in p.skip(-15) }
        on(center.nextTrackCommand) { p, _ in p.playNext() }
        on(center.previousTrackCommand) { p, _ in p.skip(-15) }
        on(center.changePlaybackPositionCommand) { p, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { p.seek(to: event.positionTime) }
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Player.rates.map { NSNumber(value: $0) }
        on(center.changePlaybackRateCommand) { p, event in
            if let event = event as? MPChangePlaybackRateCommandEvent { p.rate = event.playbackRate }
        }
    }

    func update() {
        guard let player, let ep = player.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: ep.channelTitle,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: ep.id,
            MPNowPlayingInfoPropertyIsLiveStream: player.isLive,
        ]
        if artworkID == ep.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        if artworkID != ep.id { loadArtwork(for: ep) }
    }

    /// MediaPlayer 在自己的背景佇列取縮圖。closure 若綁在主執行緒（預設 MainActor 隔離），
    /// Swift 的執行時檢查會直接讓 App 當掉（0.2.1 實際發生）。所以標成 @Sendable。自我測試會從背景執行緒呼叫它。
    static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func loadArtwork(for ep: Episode) {
        artworkID = ep.id
        artwork = nil
        let url = ep.thumbnail
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), artworkID == ep.id else { return }
            artwork = Self.makeArtwork(image)
            update()
        }
    }
}
