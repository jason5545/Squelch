import SwiftUI

struct AddChannelSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("加入頻道").font(.headline)
            TextField("@handle 或頻道網址", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .disabled(working)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("例如 @AppleDeveloper、https://www.youtube.com/@AppleDeveloper").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prefillFromClipboard)
    }

    private func prefillFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              text.contains("youtube.com/@") || text.contains("youtube.com/channel/") else { return }
        input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await library.addChannel(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct PlayURLSheet: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放影片網址").font(.headline)
            TextField("https://www.youtube.com/watch?v=…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(play)
                .disabled(working)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("直播回放、沒訂閱的頻道都可以，只播聲音。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("播放", action: play)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ChannelInput.videoID(input) == nil || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let text = NSPasteboard.general.string(forType: .string), ChannelInput.videoID(text) != nil {
                input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func play() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await player.playURL(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct SettingsView: View {
    @Environment(Account.self) private var account
    @Environment(Library.self) private var library
    @State private var showingLogin = false
    @AppStorage(YTDLP.customPathKey) private var customPath = ""
    @AppStorage("sb.sponsor") private var sponsor = true
    @AppStorage("sb.selfpromo") private var selfpromo = false
    @AppStorage("sb.interaction") private var interaction = false
    @State private var ytdlp: YTDLP.Binary?
    @State private var updateStatus: String?
    @State private var checkingUpdate = false

    var body: some View {
        Form {
            Section("YouTube 帳號") {
                LabeledContent("狀態", value: account.isLoggedIn ? String(localized: "已登入") : String(localized: "沒有登入"))
                if account.isLoggedIn {
                    Button("登出") { Task { await account.logout() } }
                } else {
                    Button("登入 YouTube…") { showingLogin = true }
                }
Text("帳號只用在：打開訂閱動態、打開觀看記錄時各抓一次，以及把播放紀錄回報給 YouTube（每部影片約 10 次）。自動更新、解析音軌、搜尋都不帶帳號。yt-dlp 官方提醒，帳號搭配 yt-dlp 有被封鎖的風險。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("直播狀態") {
                if library.channels.isEmpty {
                    Text("先加入頻道。").foregroundStyle(.secondary)
                }
                ForEach(library.channels) { channel in
                    Toggle(channel.title, isOn: Binding(
                        get: { channel.watchLive == true },
                        set: { library.setWatchLive(channel.id, $0) }))
                }
                Text("勾選的頻道每 10 分鐘自動檢查一次有沒有在直播（打開頻道的 /live 網頁，一個頻道一個請求，不帶帳號、不用 yt-dlp）。按重新整理會立刻查。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("yt-dlp") {
                LabeledContent("使用中", value: ytdlpDescription)
                HStack {
                    Button("檢查更新") { checkUpdate() }
                        .disabled(checkingUpdate || !customPath.isEmpty)
                    if checkingUpdate { ProgressView().controlSize(.small) }
                    if let updateStatus { Text(updateStatus).foregroundStyle(.secondary) }
                }
                TextField("自訂路徑（留空用內建的）", text: $customPath)
                Text("Squelch 內建 yt-dlp 和它需要的 deno，不用另外安裝。YouTube 一改版舊的 yt-dlp 就抓不到，所以每天會到 GitHub 查一次，有新版就自動下載到「~/Library/Application Support/Squelch/yt-dlp」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SubtitleSettings()
            Section("SponsorBlock") {
                Toggle("跳過贊助片段", isOn: $sponsor)
                Toggle("跳過自我宣傳（自家產品、周邊）", isOn: $selfpromo)
                Toggle("跳過「記得訂閱」提醒", isOn: $interaction)
                Text("片段由 SponsorBlock 社群標記。查詢時只送出影片 ID 雜湊的前 4 碼到 sponsor.ajay.app。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .sheet(isPresented: $showingLogin) { LoginSheet() }
        .task(id: customPath) { await loadYTDLP() }
    }

    private var ytdlpDescription: String {
        guard let ytdlp else { return String(localized: "找不到") }
        let version = ytdlp.version ?? ""
        switch ytdlp.source {
        case .bundled: return String(localized: "內建 \(version)")
        case .updated: return String(localized: "自動更新 \(version)")
        case .homebrew: return "Homebrew \(version)"
        case .custom: return "\(ytdlp.path)  \(version)"
        }
    }

    private func loadYTDLP() async {
        var binary = YTDLP.binary()
        if binary != nil, binary?.version == nil { binary?.version = await YTDLP.version() }
        ytdlp = binary
    }

    private func checkUpdate() {
        checkingUpdate = true
        updateStatus = nil
        Task {
            do {
                switch try await YTDLPUpdate.check() {
                case .upToDate: updateStatus = String(localized: "已經是最新版")
                case .updated(let version): updateStatus = String(localized: "已更新到 \(version)")
                }
            } catch {
                updateStatus = error.localizedDescription
            }
            await loadYTDLP()
            checkingUpdate = false
        }
    }
}
