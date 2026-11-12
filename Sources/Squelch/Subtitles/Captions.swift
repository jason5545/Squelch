import Foundation

/// 一句字幕。時間是影片時間（秒）。
nonisolated struct Cue: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    /// 原文。
    var text: String
    /// 正體中文。原文就是正體中文的字幕不用翻，直接放這裡。
    var translation: String?
}

/// 要用哪一軌字幕、拿到之後怎麼處理。網址會過期（約 6 小時），拿到就整份抓下來存檔。
nonisolated struct CaptionTrack: Codable, Hashable, Sendable {
    enum Handling: String, Codable, Sendable {
        /// 人工上傳的正體中文：直接顯示。
        case direct
        /// 簡體或沒標地區的中文：轉成正體字就好，不送翻譯。
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
    /// 從 yt-dlp `-j` 的結果挑一軌。順序：人工正體中文 → 原文的人工字幕 → 原文的自動字幕。
    /// YouTube 自動翻譯的軌（`automatic_captions` 裡的 `zh-Hant` 之類）不用：翻譯交給 Codex。
    static func choose(_ obj: [String: Any]) -> CaptionTrack? {
        let manual = tracks(obj["subtitles"]).filter { $0.key != "live_chat" }
        let auto = tracks(obj["automatic_captions"])
        let original = (obj["language"] as? String).map(normalize)

        for key in ["zh-TW", "zh-Hant", "zh-HK"] {
            if let url = manual[key] { return CaptionTrack(url: url, language: key, isAuto: false, handling: .direct) }
        }
        if let original {
            if let (key, url) = manual.first(where: { normalize($0.key) == original }) ?? manual.first(where: { normalize($0.key).hasPrefix(original + "-") }) {
                return track(url, key, isAuto: false)
            }
            if let url = auto["\(original)-orig"] { return track(url, original, isAuto: true) }
        }
        // 沒標語言：有人工英文字幕就用，否則用 YouTube 標成原文（`-orig`）的自動字幕。
        if let url = manual["en"] { return track(url, "en", isAuto: false) }
        if let (key, url) = auto.first(where: { $0.key.hasSuffix("-orig") }) {
            return track(url, String(key.dropLast(5)), isAuto: true)
        }
        if manual.count == 1, let (key, url) = manual.first { return track(url, key, isAuto: false) }
        return nil
    }

    private static func track(_ url: URL, _ language: String, isAuto: Bool) -> CaptionTrack {
        let lang = normalize(language)
        let handling: CaptionTrack.Handling
        if lang == "zh-tw" || lang == "zh-hant" || lang == "zh-hk" {
            handling = isAuto ? .convert : .direct
        } else if lang == "zh" || lang.hasPrefix("zh-") {
            handling = .convert
        } else {
            handling = .translate
        }
        return CaptionTrack(url: url, language: language, isAuto: isAuto, handling: handling)
    }

    private static func normalize(_ code: String) -> String { code.lowercased() }

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

    static func fetch(_ track: CaptionTrack, headers: [String: String]) async throws -> [Cue] {
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
            for i in cues.indices { cues[i].translation = toTraditional(cues[i].text) }
        case .translate:
            break
        }
        return cues
    }

    /// 簡轉繁。只轉字，不轉用詞（「軟件」不會變「軟體」）。
    static func toTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
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
