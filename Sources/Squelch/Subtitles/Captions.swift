import Foundation

/// 一句字幕。時間是影片時間（秒）；直播是實際時間（UNIX 秒）。
nonisolated struct Cue: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    /// 原文。
    var text: String
    /// 翻成目標語言的字幕。原文就是目標語言的不用翻，直接放這裡。
    var translation: String?
    /// 語音辨識偵測到的語言（YouTube 字幕不填）。
    var language: String?
    /// 起步時用低推理等級先翻的，之後有空檔會用 xhigh 重翻。
    var draft: Bool?
}

/// 字幕要翻成哪種語言。預設跟著介面語言。
nonisolated enum SubtitleTarget: String, CaseIterable, Codable, Sendable {
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en
    case ja

    /// 介面用的是哪種語言（Squelch 的四種之一，其他語言顯示英文）。
    static var system: SubtitleTarget {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return SubtitleTarget(rawValue: code) ?? (code.hasPrefix("zh") ? .zhHant : code.hasPrefix("ja") ? .ja : .en)
    }

    /// 選單上用這個語言自己的寫法。
    var name: String {
        switch self {
        case .zhHant: "正體中文"
        case .zhHans: "简体中文"
        case .en: "English"
        case .ja: "日本語"
        }
    }

    /// 寫在翻譯提示裡的說法。
    var promptName: String {
        switch self {
        case .zhHant: "臺灣用語的正體中文"
        case .zhHans: "中国大陆用语的简体中文"
        case .en: "natural English"
        case .ja: "自然な日本語"
        }
    }

    var isChinese: Bool { self == .zhHant || self == .zhHans }

    /// YouTube 或語音辨識的語言代碼是不是這種語言。
    func matches(_ code: String) -> Bool {
        let c = code.lowercased()
        switch self {
        case .zhHant: return ["zh-tw", "zh-hant", "zh-hk", "zh-mo"].contains(c) || c.hasPrefix("zh-hant")
        case .zhHans: return ["zh", "zh-cn", "zh-hans", "zh-sg"].contains(c) || c.hasPrefix("zh-hans")
        case .en: return c == "en" || c.hasPrefix("en-")
        case .ja: return c == "ja" || c.hasPrefix("ja-")
        }
    }

    static func isChinese(_ code: String) -> Bool {
        let c = code.lowercased()
        return c == "zh" || c.hasPrefix("zh-") || c == "yue" || c.hasPrefix("yue-")
    }

    /// 原文是這個語言時要怎麼處理：同一種語言直接顯示，中文正簡互轉，其他交給 Codex。
    func handling(for language: String, isAuto: Bool) -> CaptionTrack.Handling {
        if matches(language) { return isAuto && isChinese ? .convert : .direct }
        if isChinese && Self.isChinese(language) { return .convert }
        return .translate
    }

    /// 中文轉成目標的字體（只轉字，不轉用詞：「軟件」不會變「軟體」）。
    func convert(_ text: String) -> String {
        switch self {
        case .zhHant: text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        case .zhHans: text.applyingTransform(StringTransform("Hans-Hant"), reverse: true) ?? text
        default: text
        }
    }
}

/// yt-dlp 列出的字幕軌（json3 網址），開播時存起來，要用時再依目標語言挑。網址約 6 小時過期。
nonisolated struct CaptionSources: Codable, Hashable, Sendable {
    var manual: [String: URL]
    var auto: [String: URL]
    /// 影片的原文語言（yt-dlp 的 `language`），可能沒有。
    var original: String?
}

/// 要用哪一軌字幕、拿到之後怎麼處理。
nonisolated struct CaptionTrack: Codable, Hashable, Sendable {
    enum Handling: String, Codable, Sendable {
        /// 就是目標語言：直接顯示。
        case direct
        /// 中文，目標也是中文：正簡轉換，不送翻譯。
        case convert
        /// 其他語言：交給 Codex 翻。
        case translate
    }

    var url: URL
    var language: String
    /// YouTube 自動產生的（語音辨識）。這種是逐字滾動的，要自己併成句子。
    var isAuto: Bool
    var handling: Handling
}

nonisolated enum Captions {
    /// yt-dlp `-j` 的結果 → 這部有哪些字幕軌。一軌都沒有就回 nil。
    static func sources(_ obj: [String: Any]) -> CaptionSources? {
        let manual = tracks(obj["subtitles"]).filter { $0.key != "live_chat" }
        let auto = tracks(obj["automatic_captions"])
        guard !manual.isEmpty || !auto.isEmpty else { return nil }
        return CaptionSources(manual: manual, auto: auto, original: obj["language"] as? String)
    }

    /// 挑一軌。順序：目標語言的人工字幕 → 原文的人工字幕 → 原文的自動字幕。
    /// YouTube 自動翻譯的軌（`automatic_captions` 裡的 `zh-Hant`、`ja` 之類）不用：翻譯交給 Codex。
    static func choose(_ sources: CaptionSources, target: SubtitleTarget) -> CaptionTrack? {
        let manual = sources.manual
        let auto = sources.auto
        func track(_ url: URL, _ language: String, isAuto: Bool) -> CaptionTrack {
            CaptionTrack(url: url, language: language, isAuto: isAuto, handling: target.handling(for: language, isAuto: isAuto))
        }
        if let (key, url) = manual.sorted(by: { $0.key < $1.key }).first(where: { target.matches($0.key) }) {
            return track(url, key, isAuto: false)
        }
        // 原文常帶地區（`en-US`），字幕軌卻只寫語言（`en`、`en-orig`）：先比完整的，再比語言。
        if let original = sources.original?.lowercased() {
            let base = String(original.prefix(while: { $0 != "-" }))
            let names = base == original ? [original] : [original, base]
            for name in names {
                if let (key, url) = manual.first(where: { $0.key.lowercased() == name })
                    ?? manual.sorted(by: { $0.key < $1.key }).first(where: { $0.key.lowercased().hasPrefix(name + "-") }) {
                    return track(url, key, isAuto: false)
                }
            }
            for name in names {
                if let (key, url) = auto.first(where: { $0.key.lowercased() == name + "-orig" }) {
                    return track(url, String(key.dropLast(5)), isAuto: true)
                }
            }
        }
        // 沒標語言：有人工英文字幕就用，否則用 YouTube 標成原文（`-orig`）的自動字幕。
        // 有 AI 配音的影片，每條配音都有自己的 `-orig`（2026/11 的 DEF CON 影片有 20 條）：英文優先，其餘照字母排，不要靠字典順序。
        if let url = manual["en"] { return track(url, "en", isAuto: false) }
        let origs = auto.filter { $0.key.hasSuffix("-orig") }.sorted { $0.key < $1.key }
        if let (key, url) = origs.first(where: { $0.key == "en-orig" }) ?? origs.first {
            return track(url, String(key.dropLast(5)), isAuto: true)
        }
        if manual.count == 1, let (key, url) = manual.first { return track(url, key, isAuto: false) }
        return nil
    }

    /// `{語言: [{ext, url}, …]}` → `{語言: json3 的網址}`。
    private static func tracks(_ value: Any?) -> [String: URL] {
        guard let dict = value as? [String: [[String: Any]]] else { return [:] }
        var result: [String: URL] = [:]
        for (key, formats) in dict {
            if let format = formats.first(where: { $0["ext"] as? String == "json3" }),
               let string = format["url"] as? String, let url = URL(string: string) {
                result[key] = url
            }
        }
        return result
    }

    // MARK: 抓、解析

    static func fetch(_ track: CaptionTrack, target: SubtitleTarget, headers: [String: String]) async throws -> [Cue] {
        var request = URLRequest(url: track.url)
        request.timeoutInterval = 20
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubtitleError.http(http.statusCode)
        }
        var cues = track.isAuto ? parseAuto(data) : parseManual(data)
        switch track.handling {
        case .direct:
            for i in cues.indices { cues[i].translation = cues[i].text }
        case .convert:
            for i in cues.indices { cues[i].translation = target.convert(cues[i].text) }
        case .translate:
            break
        }
        return cues
    }

    private struct JSON3: Decodable {
        struct Event: Decodable {
            var tStartMs: Double?
            var dDurationMs: Double?
            var aAppend: Int?
            var segs: [Seg]?
        }
        struct Seg: Decodable {
            var utf8: String?
            var tOffsetMs: Double?
        }
        var events: [Event]?
    }

    /// 人工字幕：一個事件就是一句。
    static func parseManual(_ data: Data) -> [Cue] {
        guard let doc = try? JSONDecoder().decode(JSON3.self, from: data) else { return [] }
        var cues: [Cue] = []
        for event in doc.events ?? [] {
            guard let start = event.tStartMs, let segs = event.segs else { continue }
            let text = clean(segs.compactMap(\.utf8).joined())
            guard !text.isEmpty else { continue }
            let end = start + (event.dDurationMs ?? 2000)
            cues.append(Cue(start: start / 1000, end: end / 1000, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// 自動字幕：每個字有自己的時間，畫面上是兩行滾動。把字取出來，在停頓、句尾或太長的地方斷成一句一句。
    static func parseAuto(_ data: Data) -> [Cue] {
        guard let doc = try? JSONDecoder().decode(JSON3.self, from: data) else { return [] }
        struct Word { var start: Double; var end: Double; var text: String }
        var words: [Word] = []
        for event in doc.events ?? [] {
            guard event.aAppend == nil, let start = event.tStartMs, let segs = event.segs else { continue }
            for seg in segs {
                guard let text = seg.utf8, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let t = (start + (seg.tOffsetMs ?? 0)) / 1000
                words.append(Word(start: t, end: t, text: text.replacingOccurrences(of: "\n", with: " ")))
            }
        }
        words.sort { $0.start < $1.start }
        // 下一個字的開頭就是這個字的結尾，最短 0.2 秒、最長 1.5 秒。
        for i in words.indices {
            let next = i + 1 < words.count ? words[i + 1].start : words[i].start + 1.5
            words[i].end = min(max(words[i].start + 0.2, next), words[i].start + 1.5)
        }

        var cues: [Cue] = []
        var line: [Word] = []
        func flush() {
            guard let first = line.first, let last = line.last else { return }
            let text = clean(join(line.map(\.text)))
            if !text.isEmpty { cues.append(Cue(start: first.start, end: last.end, text: text)) }
            line = []
        }
        for word in words {
            if let first = line.first, let last = line.last {
                let text = join(line.map(\.text))
                let cjk = text.unicodeScalars.contains { $0.value >= 0x3000 }
                let tooLong = text.count >= (cjk ? 32 : 84)
                let pause = word.start - last.end > 0.8
                let sentenceEnd = last.text.trimmingCharacters(in: .whitespaces).last.map { ".?!。？！".contains($0) } ?? false
                if pause || tooLong || word.end - first.start > 7 || (sentenceEnd && text.count >= 12) {
                    flush()
                }
            }
            line.append(word)
        }
        flush()
        return cues
    }

    /// 自動字幕每一行的第一個字前面沒有空格，接到上一行後面時要補（中日文不用）。
    static func join(_ words: [String]) -> String {
        var result = ""
        for word in words {
            if let last = result.last, let next = word.first, !last.isWhitespace, !next.isWhitespace,
               !isCJK(last), !isCJK(next), !",.?!;:'’".contains(next) {
                result.append(" ")
            }
            result += word
        }
        return result
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.value >= 0x2E80 }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum SubtitleError: LocalizedError {
    case http(Int)
    case codexMissing
    case codex(String)
    case badTranslation

    var errorDescription: String? {
        switch self {
        case .http(let code): String(localized: "字幕讀取失敗（HTTP \(code)）")
        case .codexMissing: String(localized: "找不到 codex，沒辦法翻譯")
        case .codex(let message): String(localized: "翻譯失敗：\(message)")
        case .badTranslation: String(localized: "翻譯結果看不懂")
        }
    }
}
