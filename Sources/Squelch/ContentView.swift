import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Account.self) private var account
    @State private var selection: SidebarItem?

    init(initialSelection: SidebarItem = .latest) {
        _selection = State(initialValue: initialSelection)
    }
    @State private var showingAddChannel = false
    @State private var showingPlayURL = false
    @State private var showingLogin = false
    @State private var searchText = ""

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
                if account.isLoggedIn {
                    Menu {
                        Text("已登入 YouTube")
                        Button("登出") {
                            Task { await account.logout() }
                        }
                    } label: {
                        Label("帳號", systemImage: "person.crop.circle.fill")
                    }
                    .help("已登入：訂閱動態和播放紀錄會同步")
                } else {
                    Button { showingLogin = true } label: { Label("登入 YouTube", systemImage: "person.crop.circle") }
                        .help("登入後可以看訂閱動態（含直播），播放紀錄也會同步到 YouTube")
                }
                Button { showingPlayURL = true } label: { Label("播放影片網址", systemImage: "link") }
                    .help("貼上 YouTube 影片網址直接播")
                Button { showingAddChannel = true } label: { Label("加入頻道", systemImage: "plus") }
                    .help("加入頻道")
                Button {
                    Task {
                        await library.checkLive()
                        if selection == .history { await library.loadHistory() }
                        if selection == .subscriptions { await library.loadSubscriptions(force: true) }
                        await library.refresh()
                    }
                } label: {
                    if library.refreshing || library.subscriptionsLoading || library.historyLoading || library.checkingLive {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                }
                .help(library.lastRefresh.map { "上次更新：\($0.formatted(date: .omitted, time: .shortened))" } ?? "重新整理")
                .disabled(library.refreshing)
            }
        }
        // 按 Enter 才搜尋，打字當下不查，免得一直呼叫 yt-dlp。
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜尋 YouTube")
        .onSubmit(of: .search) {
            selection = .search
            Task { await library.search(searchText) }
        }
        .sheet(isPresented: $showingAddChannel) { AddChannelSheet() }
        .sheet(isPresented: $showingPlayURL) { PlayURLSheet() }
        .sheet(isPresented: $showingLogin) { LoginSheet() }
        .onKeyPress(.space) {
            guard player.current != nil else { return .ignored }
            player.toggle()
            return .handled
        }
    }
}

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Environment(Account.self) private var account
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("最新", systemImage: "tray.full").tag(SidebarItem.latest)
            Label("直播中", systemImage: "dot.radiowaves.left.and.right").tag(SidebarItem.live)
                .badge(library.list(for: .live).count)
            Label("搜尋結果", systemImage: "magnifyingglass").tag(SidebarItem.search)
            // 0.2.0 這一列是登入後才插入、外面包 HStack，點了沒反應；改成一律顯示、跟其他列同樣的結構。
            Label("訂閱動態", systemImage: "person.2.wave.2").tag(SidebarItem.subscriptions)
                .badge(account.isLoggedIn ? library.list(for: .subscriptions).filter(\.liveNow).count : 0)
            Label("聽到一半", systemImage: "clock.arrow.circlepath").tag(SidebarItem.inProgress)
                .badge(library.progress.count)
            Label("待播清單", systemImage: "list.bullet").tag(SidebarItem.queue)
                .badge(library.queue.count)
            Label("觀看記錄", systemImage: "clock").tag(SidebarItem.history)
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
            Toggle("檢查直播", isOn: Binding(
                get: { channel.watchLive == true },
                set: { library.setWatchLive(channel.id, $0) }))
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
    @Environment(Account.self) private var account
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
        .task(id: item) {
            if item == .history { await library.loadHistory() }
            if item == .subscriptions { await library.loadSubscriptions() }
            if item == .live, (library.liveChecked.map { Date().timeIntervalSince($0) > 120 } ?? true) {
                await library.checkLive()
            }
        }
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
                if !ep.channelID.isEmpty, !library.channels.contains(where: { $0.id == ep.channelID }) {
                    Divider()
                    Button("加入頻道「\(ep.channelTitle.isEmpty ? "這個頻道" : ep.channelTitle)」") {
                        Task { try? await library.addChannel(ep.channelID) }
                    }
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
        case .live:
            if library.liveWatchChannels.isEmpty {
                ContentUnavailableView {
                    Label("還沒有勾選要檢查直播的頻道", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("在設定的「直播狀態」，或在側欄的頻道上按右鍵勾選。")
                } actions: {
                    SettingsLink { Text("打開設定") }
                }
            } else if library.checkingLive {
                ProgressView("正在檢查直播…")
            } else {
                ContentUnavailableView("目前沒有在直播", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text(liveStatusText))
            }
        case .search:
            if library.searching {
                ProgressView("搜尋「\(library.searchQuery)」…")
            } else if let error = library.searchError {
                ContentUnavailableView("搜尋失敗", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
            } else if !library.searchQuery.isEmpty {
                ContentUnavailableView.search(text: library.searchQuery)
            } else {
                ContentUnavailableView("搜尋 YouTube", systemImage: "magnifyingglass",
                                       description: Text("在右上角的搜尋框輸入關鍵字，按 Enter。"))
            }
        case .history:
            if library.historyLoading {
                ProgressView("正在抓觀看記錄…")
            } else if let error = library.historyError {
                ContentUnavailableView("抓不到觀看記錄", systemImage: "clock", description: Text(error))
            } else {
                ContentUnavailableView("還沒有觀看記錄", systemImage: "clock",
                                       description: Text(account.isLoggedIn ? "按右上角的重新整理。" : "在 Squelch 聽過的影片會出現在這裡。登入後會顯示 YouTube 的觀看記錄。"))
            }
        case .subscriptions:
            if !account.isLoggedIn {
                ContentUnavailableView {
                    Label("登入後才有訂閱動態", systemImage: "person.2.wave.2")
                } description: {
                    Text("按右上角的人像登入 YouTube。")
                }
            } else if library.subscriptionsLoading {
                ProgressView("正在抓訂閱動態…")
            } else {
                ContentUnavailableView("訂閱動態是空的", systemImage: "person.2.wave.2",
                                       description: Text(library.channelErrors[YTDLP.subscriptionsURL] ?? "按右上角的重新整理。"))
            }
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

    private var liveStatusText: String {
        let names = library.liveWatchChannels.map(\.title).joined(separator: "、")
        guard let checked = library.liveChecked else { return "檢查：\(names)，每 10 分鐘自動查一次" }
        return "檢查：\(names) · \(checked.formatted(date: .omitted, time: .shortened)) 查的，每 10 分鐘自動查一次"
    }

    private var title: String {
        switch item {
        case .latest: "最新"
        case .live: "直播中"
        case .search: library.searchQuery.isEmpty ? "搜尋結果" : "搜尋：\(library.searchQuery)"
        case .history: "觀看記錄"
        case .subscriptions: "訂閱動態"
        case .inProgress: "聽到一半"
        case .queue: "待播清單"
        case .channel(let id): library.channels.first { $0.id == id }?.title ?? "頻道"
        }
    }

    private func subtitle(_ episodes: [Episode]) -> String {
        if item == .subscriptions, let error = library.channelErrors[YTDLP.subscriptionsURL] { return "更新失敗：\(error)" }
        if item == .subscriptions, let fetched = library.subscriptionsFetched {
            return "\(episodes.count) 部 · \(fetched.formatted(date: .omitted, time: .shortened)) 更新，打開這裡或按重新整理才會再抓"
        }
        if item == .live { return liveStatusText }
        if item == .history { return account.isLoggedIn ? "YouTube 觀看記錄（含手機）" : "Squelch 本機記錄" }
        if item == .search, library.searching { return "搜尋中…" }
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
                if episode.liveNow {
                    Text("● 直播中")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.red, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if let d = episode.duration {
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
                    if episode.isStream && !episode.liveNow {
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
