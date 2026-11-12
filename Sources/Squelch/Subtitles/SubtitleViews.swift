import SwiftUI

/// 播放列上方的字幕：上面是正體中文，下面小字是原文。還沒翻好的先顯示原文。
struct SubtitleStrip: View {
    @Environment(Player.self) private var player
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        if subtitles.enabled, player.current != nil {
            let cue = subtitles.cue(at: player.subtitleClock)
            VStack(spacing: 3) {
                if let cue {
                    Text(cue.translation ?? cue.text)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(cue.translation == nil ? Color.white.opacity(0.6) : .white)
                    if let translation = cue.translation, translation != cue.text {
                        Text(cue.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let note = Self.note(subtitles) {
                    HStack(spacing: 10) {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if subtitles.offerSpeech { SpeechOfferButton() }
                    }
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 40)
            .padding(.vertical, 6)
            .background {
                ZStack(alignment: .top) {
                    Theme.bar
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
            }
            .animation(.easeOut(duration: 0.12), value: cue)
        }
    }

    /// 沒有字幕可以顯示時，說明為什麼。迷你視窗也用。
    static func note(_ subtitles: Subtitles) -> String? {
        if let error = subtitles.translationError { return error }
        switch subtitles.status {
        case .idle: return nil
        case .loading: return String(localized: "正在抓字幕…")
        case .unavailable(let why): return why
        case .speech:
            if case .preparing(let progress) = subtitles.model.state {
                return String(localized: "正在準備語音辨識模型 \(Int(progress * 100))%")
            }
            if case .failed(let why) = subtitles.model.state { return why }
            return subtitles.cues.isEmpty ? String(localized: "正在辨識…") : nil
        case .captions:
            return subtitles.needsTranslation && !subtitles.cues.contains(where: { $0.translation != nil })
                ? String(localized: "正在翻譯…") : nil
        }
    }
}

/// 沒有字幕時：打開本機語音辨識。模型不在這台 Mac 上的話，按了才下載。
struct SpeechOfferButton: View {
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        Button(subtitles.model.state == .ready ? "用本機語音辨識" : "用本機語音辨識（下載 2.5 GB）") {
            subtitles.speechFallback = true
        }
        .buttonStyle(.borderless)
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.amber)
    }
}

/// 播放列右邊的字幕開關。
struct SubtitleToggle: View {
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        @Bindable var subtitles = subtitles
        Button { subtitles.enabled.toggle() } label: {
            Image(systemName: subtitles.enabled ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(GlyphButtonStyle(active: subtitles.enabled))
        .help(subtitles.enabled ? "關掉字幕" : "顯示字幕（翻成正體中文）")
    }
}

/// 設定裡的「字幕」。
struct SubtitleSettings: View {
    @Environment(Subtitles.self) private var subtitles

    var body: some View {
        @Bindable var subtitles = subtitles
        Section("字幕") {
            Toggle("顯示字幕", isOn: $subtitles.enabled)
            LabeledContent("翻譯", value: CodexTranslator.isInstalled
                           ? String(localized: "Codex · GPT-6 Luna · xhigh · 快速模式")
                           : String(localized: "找不到 codex"))
            Text("有 YouTube 字幕就用（人工上傳的優先，其次是自動字幕），交給本機的 Codex 翻成正體中文，用的是你自己的 Codex 登入。原文是中文的不翻，只轉成正體字。翻好的存在快取，重聽不用再翻。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("沒有字幕時用本機語音辨識", isOn: $subtitles.speechFallback)
            modelStatus
            Text("用 Qwen3-ASR 1.7B 在這台 Mac 上辨識，不會上傳聲音。第一次打開要下載約 2.5 GB 的模型（Hugging Face）。直播一定沒有字幕：模型下載過就自動聽寫，這個開關關著也一樣。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch subtitles.model.state {
        case .missing:
            LabeledContent("模型", value: String(localized: "沒有下載"))
        case .preparing(let progress):
            LabeledContent("模型") {
                HStack {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))%").monospacedDigit()
                    Button("取消") { subtitles.model.cancel() }
                }
            }
        case .ready:
            LabeledContent("模型") {
                HStack {
                    Text("已下載")
                    Button("刪除") {
                        subtitles.speechFallback = false
                        subtitles.model.delete()
                    }
                }
            }
        case .failed(let why):
            LabeledContent("模型") {
                HStack {
                    Text(why).foregroundStyle(.red)
                    Button("重試") { subtitles.model.prepare() }
                }
            }
        }
    }
}
