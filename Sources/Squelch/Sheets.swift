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
    @AppStorage(YTDLP.customPathKey) private var customPath = ""
    @AppStorage("sb.sponsor") private var sponsor = true
    @AppStorage("sb.selfpromo") private var selfpromo = false
    @AppStorage("sb.interaction") private var interaction = false
    @State private var version: String?

    var body: some View {
        Form {
            Section("yt-dlp") {
                LabeledContent("使用中", value: YTDLP.binaryPath().map { "\($0)  \(version ?? "")" } ?? "找不到")
                TextField("自訂路徑（留空自動找 Homebrew）", text: $customPath)
                Text("yt-dlp 要常更新，YouTube 一改版舊版就抓不到：`brew upgrade yt-dlp`。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        .task(id: customPath) { version = await YTDLP.version() }
    }
}
