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
    @AppStorage("showPlayerPanel") private var showPanel = true

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                // 搜尋框放在側欄上方（像 Apple Music）。一定要掛在側欄這一欄：掛在整個視窗上時，
                // 工具列最右邊還會多一個，橫跨整個「正在播放」面板（截圖程式會列出搜尋框在哪）。
                // 按 Enter 才搜尋，打字當下不查，免得一直呼叫 yt-dlp。
                .searchable(text: $searchText, placement: .sidebar, prompt: "搜尋 YouTube")
                .onSubmit(of: .search) {
                    selection = .search
                    Task { await library.search(searchText) }
                }
                // 欄寬要放最外層，包在 .searchable 裡面會失效，側欄被擠到約 144 點。
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            EpisodeList(item: selection ?? .latest)
        }
        // 沒在播時不佔位置；有在播才照使用者上次的開關。
        .inspector(isPresented: Binding(
            get: { showPanel && player.current != nil },
            set: { showPanel = $0 })) {
            PlayerPanel()
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        // 播放列橫跨整個視窗底部，播放鍵、進度、音量都在這裡；右側面板放封面和接下來。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SubtitleStrip()
                NowPlayingBar(showPanel: $showPanel)
            }
        }
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
        // 從沒在播變成開始播時，把收起來的面板打開。
        .onChange(of: player.current?.id) { old, new in
            if old == nil, new != nil { showPanel = true }
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
                .help(library.lastRefresh.map { String(localized: "上次更新：\($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "重新整理"))
                .disabled(library.refreshing)
            }
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

// MARK: - 側欄

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Environment(Account.self) private var account
    @Binding var selection: SidebarItem?

    var body: some View {
        let liveChannels = Set(library.episodes.values.filter(\.liveNow).map(\.channelID))
        let newest = newestByChannel
        List(selection: $selection) {
            // `.tag` 一定要放在最後（`.badge` 之後）。寫成 `.tag(...).badge(...)` 時 tag 被包在裡面，
            // List 讀不到，有數字的列（直播中、訂閱動態、聽到一半、待播清單）點了都選不到。
            Section("資料庫") {
                tile("最新", .latest).tag(SidebarItem.latest)
                tile("直播中", .live)
                    .badge(library.list(for: .live).count)
                    .tag(SidebarItem.live)
                tile("搜尋結果", .search).tag(SidebarItem.search)
                tile("訂閱動態", .subscriptions)
                    .badge(account.isLoggedIn ? library.list(for: .subscriptions).filter(\.liveNow).count : 0)
                    .tag(SidebarItem.subscriptions)
                tile("聽到一半", .inProgress)
                    .badge(library.progress.count)
                    .tag(SidebarItem.inProgress)
                tile("待播清單", .queue)
                    .badge(library.queue.count)
                    .tag(SidebarItem.queue)
                tile("觀看記錄", .history).tag(SidebarItem.history)
            }
            Section("頻道") {
                ForEach(library.channels) { channel in
                    ChannelRow(channel: channel, isLive: liveChannels.contains(channel.id), newest: newest[channel.id])
                        .tag(SidebarItem.channel(channel.id))
                }
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ item: SidebarItem) -> some View {
        Label { Text(title) } icon: { TileIcon(item: item) }
    }

    /// 每個頻道最新一部的時間，側欄第二行用。
    private var newestByChannel: [String: Date] {
        var result: [String: Date] = [:]
        for ep in library.episodes.values {
            guard let date = ep.published else { continue }
            if date > result[ep.channelID] ?? .distantPast { result[ep.channelID] = date }
        }
        return result
    }
}

struct ChannelRow: View {
    @Environment(Library.self) private var library
    let channel: Channel
    var isLive = false
    var newest: Date?

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: channel.avatar, cornerRadius: 15)
                .frame(width: 30, height: 30)
                .overlay {
                    if isLive { Circle().strokeBorder(Theme.live, lineWidth: 2) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.title).lineLimit(1)
                Group {
                    if isLive {
                        Text("● 直播中").foregroundStyle(Theme.live)
                    } else if let newest {
                        Text(newest, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let error = library.channelErrors[channel.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { ChannelMenu(channel: channel) }
    }
}

/// 頻道的右鍵選單，頁首的「⋯」也用同一份。
struct ChannelMenu: View {
    @Environment(Library.self) private var library
    let channel: Channel

    var body: some View {
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

/// 影片的右鍵選單，清單每一列的「⋯」和卡片也用同一份。
struct EpisodeMenu: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode

    var body: some View {
        let ep = episode
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
            Button("加入頻道「\(ep.channelTitle.isEmpty ? String(localized: "這個頻道") : ep.channelTitle)」") {
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

// MARK: - 清單頁

struct EpisodeList: View {
    @Environment(Library.self) private var library
    @Environment(Account.self) private var account
    @Environment(Player.self) private var player
    let item: SidebarItem

    var body: some View {
        let episodes = library.list(for: item)
        let live = item == .latest ? library.list(for: .live) : []
        let resume = item == .latest ? Array(library.list(for: .inProgress).prefix(12)) : []
        Group {
            if episodes.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        header(episodes)
                        empty
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
            } else {
                List {
                    header(episodes).plainRow()
                    if !live.isEmpty {
                        Shelf(title: "正在直播", episodes: live).plainRow()
                    }
                    if !resume.isEmpty {
                        Shelf(title: "繼續聽", episodes: resume).plainRow()
                    }
                    if !live.isEmpty || !resume.isEmpty {
                        Text("最新影片")
                            .font(.title2.bold())
                            .padding(.horizontal, 28)
                            .padding(.top, 14)
                            .plainRow()
                    }
                    columnHeader.plainRow()
                    if item == .queue {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, ep in row(ep, index) }
                            .onMove { library.moveQueue(from: $0, to: $1) }
                            .onDelete { offsets in
                                offsets.map { episodes[$0].id }.forEach(library.dequeue)
                            }
                    } else {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, ep in row(ep, index) }
                    }
                    Color.clear.frame(height: 24).plainRow()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background { PageBackground(color: pageColor) }
        .navigationTitle(title)
        .toolbar(removing: .title)
        .task(id: item) {
            if item == .history { await library.loadHistory() }
            if item == .subscriptions { await library.loadSubscriptions() }
            if item == .live, (library.liveChecked.map { Date().timeIntervalSince($0) > 120 } ?? true) {
                await library.checkLive()
            }
        }
    }

    private func row(_ ep: Episode, _ index: Int) -> some View {
        EpisodeRow(episode: ep, index: index + 1, showChannel: channel == nil)
            .contentShape(Rectangle())
            .onTapGesture {
                // 點正在播的那一列是暫停／繼續，不要從頭重新載入。
                if player.current?.id == ep.id { player.toggle() } else { player.play(ep) }
            }
            .contextMenu { EpisodeMenu(episode: ep) }
            .plainRow()
    }

    // MARK: 頁首

    private var channel: Channel? {
        if case .channel(let id) = item { return library.channels.first { $0.id == id } }
        return nil
    }

    private var pageColor: Color {
        if let channel {
            return ArtworkPalette.shared.color(for: channel.avatar) ?? item.colors[1]
        }
        return item.colors[0]
    }

    private func header(_ episodes: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            // 中間這欄夠寬就用大封面；視窗窄、兩側都開著時改小封面，副標題才不會被擠成兩行。
            ViewThatFits(in: .horizontal) {
                headline(episodes, cover: 168, title: 54)
                headline(episodes, cover: 96, title: 34)
                VStack(alignment: .leading, spacing: 14) {
                    cover.frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    headlineText(episodes, title: 34)
                }
            }
            HStack(spacing: 20) {
                if let target = playTarget(episodes) {
                    let ownsCurrent = player.current.map { cur in episodes.contains { $0.id == cur.id } } ?? false
                    PlayCircle(size: 56, playing: ownsCurrent && player.isPlaying,
                               loading: ownsCurrent && player.isLoading) {
                        if ownsCurrent { player.toggle() } else { player.play(target) }
                    }
                    .help(ownsCurrent ? "播放／暫停（空白鍵、⌘↩）" : "從「\(target.title)」開始播")
                }
                if let channel {
                    Menu { ChannelMenu(channel: channel) } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(GlyphButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("頻道設定")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private func headline(_ episodes: [Episode], cover size: CGFloat, title: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: size > 100 ? 24 : 16) {
            cover
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: size / 7, y: size / 14)
            headlineText(episodes, title: title)
                .padding(.bottom, 4)
        }
    }

    private func headlineText(_ episodes: [Episode], title size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(channel == nil ? "清單" : "頻道")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
            Text(headerTitle)
                .font(.system(size: size, weight: .black))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
            Text(subtitle(episodes))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
        }
    }

    @ViewBuilder private var cover: some View {
        if let channel {
            Thumbnail(url: channel.avatar, cornerRadius: 84)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: item.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: item.symbol)
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
        }
    }

    /// 頁首的大播放鍵從哪一集開始：第一部還沒聽完的。
    private func playTarget(_ episodes: [Episode]) -> Episode? {
        episodes.first { !library.finished.contains($0.id) } ?? episodes.first
    }

    /// Spotify 式的欄位標題：編號、標題、長度。
    private var columnHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Text("#").frame(width: 28)
                Text("標題")
                Spacer()
                Image(systemName: "clock").frame(width: 84, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: 空的時候

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
                                       description: Text("在側欄上方的搜尋框輸入關鍵字，按 Enter。"))
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
                                       description: Text(library.channelErrors[YTDLP.subscriptionsURL] ?? String(localized: "按右上角的重新整理。")))
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
        let names = library.liveWatchChannels.map(\.title).formatted(.list(type: .and))
        guard let checked = library.liveChecked else { return String(localized: "檢查：\(names)，每 10 分鐘自動查一次") }
        return String(localized: "檢查：\(names) · \(checked.formatted(date: .omitted, time: .shortened)) 查的，每 10 分鐘自動查一次")
    }

    private var title: String {
        switch item {
        case .latest: String(localized: "最新")
        case .live: String(localized: "直播中")
        case .search: library.searchQuery.isEmpty ? String(localized: "搜尋結果") : String(localized: "搜尋：\(library.searchQuery)")
        case .history: String(localized: "觀看記錄")
        case .subscriptions: String(localized: "訂閱動態")
        case .inProgress: String(localized: "聽到一半")
        case .queue: String(localized: "待播清單")
        case .channel(let id): library.channels.first { $0.id == id }?.title ?? String(localized: "頻道")
        }
    }

    /// 頁首的大標題。搜尋頁直接放關鍵字。
    private var headerTitle: String {
        if item == .search, !library.searchQuery.isEmpty { return String(localized: "「\(library.searchQuery)」") }
        return title
    }

    private func subtitle(_ episodes: [Episode]) -> String {
        if item == .subscriptions, let error = library.channelErrors[YTDLP.subscriptionsURL] { return String(localized: "更新失敗：\(error)") }
        if item == .subscriptions, let fetched = library.subscriptionsFetched {
            return String(localized: "\(episodes.count) 部 · \(fetched.formatted(date: .omitted, time: .shortened)) 更新，打開這裡或按重新整理才會再抓")
        }
        if item == .live { return liveStatusText }
        if item == .history { return account.isLoggedIn ? String(localized: "YouTube 觀看記錄（含手機）") : String(localized: "Squelch 本機記錄") }
        if item == .search, library.searching { return String(localized: "搜尋中…") }
        let total = episodes.reduce(0) { $0 + ($1.duration ?? 0) }
        return episodes.isEmpty ? "" : String(localized: "\(episodes.count) 部 · 共 \(Format.time(total))")
    }
}

// MARK: - 橫向卡片列

/// 首頁上方一排可以左右捲的卡片（正在直播、繼續聽）。
struct Shelf: View {
    let title: LocalizedStringKey
    let episodes: [Episode]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 6) {
                    ForEach(episodes) { EpisodeCard(episode: $0) }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 14)
    }
}

struct EpisodeCard: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == episode.id
        let progress = library.progress[episode.id]
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: episode.thumbnail, cornerRadius: 8)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if let progress, let d = episode.duration, d > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle().fill(Theme.amber).frame(width: geo.size.width * min(progress / d, 1))
                            }
                        }
                        .frame(height: 4)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if episode.liveNow {
                        Text("● 直播中")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.live, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    PlayCircle(size: 40, playing: isCurrent && player.isPlaying) {
                        if isCurrent { player.toggle() } else { player.play(episode) }
                    }
                    .padding(10)
                    .opacity(hovering || isCurrent ? 1 : 0)
                    .offset(y: hovering || isCurrent ? 0 : 8)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isCurrent ? Theme.amber : .white)
                    .lineLimit(2, reservesSpace: true)
                Group {
                    if let progress, let d = episode.duration, d > progress {
                        Text("\(episode.channelTitle) · 剩 \(Format.time(d - progress))")
                    } else {
                        Text(episode.channelTitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(width: 210)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture {
            if isCurrent { player.toggle() } else { player.play(episode) }
        }
        .contextMenu { EpisodeMenu(episode: episode) }
    }
}

// MARK: - 清單的一列

struct EpisodeRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode
    var index = 0
    /// 頻道頁每一列都是同一個頻道，不用再寫。
    var showChannel = true
    @State private var hovering = false

    var body: some View {
        let finished = library.finished.contains(episode.id)
        let progress = library.progress[episode.id]
        let isCurrent = player.current?.id == episode.id
        let queued = library.queue.contains(episode.id)
        HStack(spacing: 14) {
            Group {
                if hovering {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.callout)
                        .foregroundStyle(.white)
                } else if isCurrent {
                    EqualizerBars(playing: player.isPlaying)
                } else {
                    Text(index, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)

            Thumbnail(url: episode.thumbnail, cornerRadius: 6)
                .frame(width: 104, height: 58)
                .overlay(alignment: .bottomLeading) {
                    if episode.liveNow {
                        Text("● 直播中")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.live, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? Theme.amber : .white)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if episode.isStream && !episode.liveNow {
                        Text("直播回放")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if showChannel {
                        Text(episode.channelTitle)
                    }
                    if let date = episode.published {
                        if showChannel { Text("·") }
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let progress, let d = episode.duration, d > 0 {
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule().fill(Theme.amber).frame(width: max(3, geo.size.width * min(progress / d, 1)))
                            }
                        }
                        .frame(width: 120, height: 3)
                        Text("剩 \(Format.time(max(0, d - progress)))")
                            .font(.timecodeSmall)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)

            // 滑鼠移上去才出現的按鈕；已經在待播清單裡的，琥珀色的勾一直留著。
            HStack(spacing: 10) {
                Button {
                    if queued { library.dequeue(episode.id) } else { library.enqueue(episode.id) }
                } label: {
                    Image(systemName: queued ? "text.badge.checkmark" : "text.badge.plus")
                        .font(.body)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(GlyphButtonStyle(active: queued))
                .help(queued ? "移出待播清單" : "加到待播清單")
                .opacity(hovering || queued ? 1 : 0)

                Menu { EpisodeMenu(episode: episode) } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(GlyphButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
            }

            HStack(spacing: 6) {
                if finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.amber)
                        .help("聽完了")
                }
                if episode.liveNow {
                    Text("直播").foregroundStyle(Theme.live)
                } else if let d = episode.duration {
                    Text(Format.time(d))
                }
            }
            .font(.timecode)
            .foregroundStyle(.secondary)
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering ? Theme.hover : isCurrent ? Color.white.opacity(0.04) : .clear))
        .opacity(finished && !isCurrent && !hovering ? 0.5 : 1)
        .padding(.horizontal, 16)
        .onHover { hovering = $0 }
    }
}
