import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var selection: SidebarItem? = .latest
    @State private var showingAddChannel = false
    @State private var showingPlayURL = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            EpisodeList(item: selection ?? .latest)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                PlayerBar()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showingPlayURL = true } label: { Label("播放影片網址", systemImage: "link") }
                    .help("貼上 YouTube 影片網址直接播")
                Button { showingAddChannel = true } label: { Label("加入頻道", systemImage: "plus") }
                    .help("加入頻道")
                Button {
                    Task { await library.refresh() }
                } label: {
                    if library.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                }
                .help(library.lastRefresh.map { "上次更新：\($0.formatted(date: .omitted, time: .shortened))" } ?? "重新整理")
                .disabled(library.refreshing)
            }
        }
        .sheet(isPresented: $showingAddChannel) { AddChannelSheet() }
        .sheet(isPresented: $showingPlayURL) { PlayURLSheet() }
        .onKeyPress(.space) {
            guard player.current != nil else { return .ignored }
            player.toggle()
            return .handled
        }
    }
}

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("最新", systemImage: "tray.full").tag(SidebarItem.latest)
            Label("聽到一半", systemImage: "clock.arrow.circlepath").tag(SidebarItem.inProgress)
                .badge(library.progress.count)
            Label("待播清單", systemImage: "list.bullet").tag(SidebarItem.queue)
                .badge(library.queue.count)
            Section("頻道") {
                ForEach(library.channels) { channel in
                    ChannelRow(channel: channel).tag(SidebarItem.channel(channel.id))
                }
            }
        }
    }
}

struct ChannelRow: View {
    @Environment(Library.self) private var library
    let channel: Channel

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: channel.avatar) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            Text(channel.title).lineLimit(1)
            Spacer()
            if let error = library.channelErrors[channel.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .contextMenu {
            Toggle("包含直播回放", isOn: Binding(
                get: { channel.includeStreams },
                set: { library.setIncludeStreams(channel.id, $0) }))
            Button("在 YouTube 開啟") {
                if let url = URL(string: channel.id) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("移除頻道", role: .destructive) { library.removeChannel(channel.id) }
        }
    }
}

struct EpisodeList: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let item: SidebarItem

    var body: some View {
        let episodes = library.list(for: item)
        Group {
            if episodes.isEmpty {
                empty
            } else {
                List {
                    if item == .queue {
                        ForEach(episodes) { row($0) }
                            .onMove { library.moveQueue(from: $0, to: $1) }
                            .onDelete { offsets in
                                offsets.map { episodes[$0].id }.forEach(library.dequeue)
                            }
                    } else {
                        ForEach(episodes) { row($0) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(episodes))
    }

    private func row(_ ep: Episode) -> some View {
        EpisodeRow(episode: ep)
            .contentShape(Rectangle())
            .onTapGesture { player.play(ep) }
            .contextMenu {
                Button("播放") { player.play(ep) }
                Button("下一首播") { library.playNextInQueue(ep.id) }
                if library.queue.contains(ep.id) {
                    Button("移出待播清單") { library.dequeue(ep.id) }
                } else {
                    Button("加到待播清單") { library.enqueue(ep.id) }
                }
                Divider()
                Button(library.finished.contains(ep.id) ? "標成沒聽過" : "標成聽完了") {
                    library.toggleFinished(ep.id)
                }
                Divider()
                Button("在 YouTube 開啟") { NSWorkspace.shared.open(ep.watchURL) }
                Button("複製影片網址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ep.watchURL.absoluteString, forType: .string)
                }
            }
    }

    @ViewBuilder private var empty: some View {
        switch item {
        case .queue:
            ContentUnavailableView("待播清單是空的", systemImage: "list.bullet",
                                   description: Text("在影片上按右鍵，選「加到待播清單」。"))
        case .inProgress:
            ContentUnavailableView("沒有聽到一半的", systemImage: "clock.arrow.circlepath")
        default:
            if library.channels.isEmpty {
                ContentUnavailableView("還沒有頻道", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("按右上角的 + 加入頻道。"))
            } else if library.refreshing {
                ProgressView("正在抓頻道清單…")
            } else {
                ContentUnavailableView("還沒有影片", systemImage: "tray",
                                       description: Text("按右上角的重新整理。"))
            }
        }
    }

    private var title: String {
        switch item {
        case .latest: "最新"
        case .inProgress: "聽到一半"
        case .queue: "待播清單"
        case .channel(let id): library.channels.first { $0.id == id }?.title ?? "頻道"
        }
    }

    private func subtitle(_ episodes: [Episode]) -> String {
        let total = episodes.reduce(0) { $0 + ($1.duration ?? 0) }
        return episodes.isEmpty ? "" : "\(episodes.count) 部 · 共 \(Format.time(total))"
    }
}

struct EpisodeRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode

    var body: some View {
        let finished = library.finished.contains(episode.id)
        let progress = library.progress[episode.id]
        let isCurrent = player.current?.id == episode.id
        HStack(spacing: 12) {
            AsyncImage(url: episode.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if let d = episode.duration {
                    Text(Format.time(d))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(episode.channelTitle)
                    if let date = episode.published {
                        Text("·")
                        Text(date, format: .relative(presentation: .named))
                    }
                    if episode.isStream {
                        Text("直播回放")
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if library.queue.contains(episode.id) {
                        Image(systemName: "list.bullet").help("在待播清單裡")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let progress, let d = episode.duration, d > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: min(progress, d), total: d)
                            .frame(maxWidth: 160)
                        Text("剩 \(Format.time(d - progress))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .foregroundStyle(.tint)
            } else if finished {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .help("聽完了")
            }
        }
        .padding(.vertical, 4)
        .opacity(finished && !isCurrent ? 0.5 : 1)
    }
}
