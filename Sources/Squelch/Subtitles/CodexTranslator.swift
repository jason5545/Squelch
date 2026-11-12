import Foundation

/// 用本機的 Codex（`codex app-server --stdio`，JSON-RPC 一行一則）翻字幕。用的是使用者自己的 Codex 登入，不需要 API key。
/// 模型固定 GPT-6 Luna、推理 xhigh、快速模式（serviceTier priority）。
///
/// 每一批開一個 ephemeral thread，前後文直接寫進這一批的提示，不留對話紀錄。thread 的工作目錄是空的暫存資料夾，
/// 不會讀到哪個 repo 的 AGENTS.md。沙盒唯讀、不准連網、不准要權限。協定的寫法跟 AISubtitle 的 codex-translate-lines.py 一樣。
actor CodexTranslator {
    static let model = "gpt-6-luna"
    static let effort = "xhigh"
    static let serviceTier = "priority"
    static let timeout: Double = 240

    struct Item: Sendable {
        var id: Int
        var text: String
    }

    struct Batch: Sendable {
        var target: SubtitleTarget
        var title: String
        var channel: String
        var items: [Item]
        /// 前面幾句（原文、譯文），只當參考。
        var before: [(String, String?)]
        /// 後面幾句原文，只當參考。
        var after: [String]
    }

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var nextID = 1
    private var responses: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var turns: [String: CheckedContinuation<String, Error>] = [:]
    /// 回應先到、還沒人在等的 turn 結果。
    private var finishedTurns: [String: Result<String, Error>] = [:]
    private var turnText: [String: String] = [:]
    /// 最近一次 thread/start 回報的模型和 service tier（檢查模式印出來對）。
    private(set) var lastThread: (model: String?, tier: String?, effort: String?) = (nil, nil, nil)

    // MARK: 找 codex

    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]

    /// `codex` 是 node 腳本，從 Finder 開的 App PATH 很短，要自己補。
    static func executable() -> String? {
        let candidates = searchPath.map { $0 + "/codex" } + ["/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executable() != nil }

    var isRunning: Bool { process?.isRunning == true }

    // MARK: 翻譯

    func translate(_ batch: Batch) async throws -> [Int: String] {
        try await ensureStarted()
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let thread = try await request("thread/start", [
            "cwd": cwd.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "ephemeral": true,
            "developerInstructions": Self.instructions(batch.target),
            "serviceName": "squelch",
            "model": Self.model,
            "serviceTier": Self.serviceTier,
        ])
        lastThread = (thread["model"] as? String, thread["serviceTier"] as? String, thread["reasoningEffort"] as? String)
        guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
            throw SubtitleError.codex("沒有 thread id")
        }
        let turn = try await request("turn/start", [
            "threadId": threadID,
            "input": [["type": "text", "text": Self.prompt(batch)]],
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
            "outputSchema": Self.schema,
            "summary": "none",
            "model": Self.model,
            "effort": Self.effort,
            "serviceTier": Self.serviceTier,
        ])
        guard let turnID = (turn["turn"] as? [String: Any])?["id"] as? String else {
            throw SubtitleError.codex("沒有 turn id")
        }
        let text = try await waitForTurn(turnID)
        return try Self.parse(text, expected: batch.items.map(\.id))
    }

    func stop() {
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        failAll(SubtitleError.codex("已停止"))
    }

    // MARK: 提示

    static func instructions(_ target: SubtitleTarget) -> String {
        """
        你是 YouTube 影片的字幕翻譯。把字幕翻成\(target.promptName)（\(target.name)）。
        - 口語、自然、簡短，像字幕，不要翻譯腔。專有名詞、產品名、人名保留原文或用\(target.name)通行的譯名。
        - 一個 id 一句，不合併、不拆開、不漏掉；語意跨句時照譯文的語序分配，但每句都要有內容。
        - 自動字幕可能有聽錯的字，依上下文修正後再翻。
        - 已經是\(target.name)的句子照抄。
        - 只輸出要求的 JSON，不要解釋。
        """
    }

    static func prompt(_ batch: Batch) -> String {
        var lines = ["影片：\(batch.title)（\(batch.channel)）", ""]
        if !batch.before.isEmpty {
            lines.append("前文（只供參考，不用翻）：")
            for (source, translation) in batch.before {
                lines.append("- \(source)" + (translation.map { " → \($0)" } ?? ""))
            }
            lines.append("")
        }
        lines.append("要翻的字幕：")
        for item in batch.items { lines.append("[\(item.id)] \(item.text)") }
        if !batch.after.isEmpty {
            lines.append("")
            lines.append("後文（只供參考，不用翻）：")
            for source in batch.after { lines.append("- \(source)") }
        }
        lines.append("")
        lines.append("翻成\(batch.target.promptName)。回傳 {\"items\": [{\"id\": 編號, \"translation\": \"譯文\"}, …]}，每個 id 剛好一次，照原本的順序。")
        return lines.joined(separator: "\n")
    }

    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["id": ["type": "integer"], "translation": ["type": "string"]],
                    "required": ["id", "translation"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["items"],
        "additionalProperties": false,
    ] }

    /// 模型的回覆 → `{id: 譯文}`。要的 id 少了就算失敗；多出來的丟掉。
    static func parse(_ text: String, expected: [Int]) throws -> [Int: String] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}") { body = String(body[open...close]) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { throw SubtitleError.badTranslation }
        var result: [Int: String] = [:]
        let wanted = Set(expected)
        for item in items {
            guard let id = (item["id"] as? NSNumber)?.intValue, wanted.contains(id),
                  let translation = (item["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translation.isEmpty else { continue }
            result[id] = translation
        }
        guard result.count == wanted.count else { throw SubtitleError.badTranslation }
        return result
    }

    // MARK: JSON-RPC

    private func ensureStarted() async throws {
        if let process, process.isRunning { return }
        guard let path = Self.executable() else { throw SubtitleError.codexMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--stdio"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Self.searchPath + (env["PATH"]?.split(separator: ":").map(String.init) ?? [])).joined(separator: ":")
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        reader = Task { [weak self] in
            for await line in lines { await self?.handle(line) }
            await self?.exited()
        }
        _ = try await request("initialize", ["clientInfo": ["name": "squelch", "title": "Squelch", "version": "1.0.0"]])
        send(["method": "initialized", "params": [String: Any]()])
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responses[id] = continuation
                send(["method": method, "id": id, "params": params])
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    await self?.timeoutRequest(id)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func waitForTurn(_ turnID: String) async throws -> String {
        if let done = finishedTurns.removeValue(forKey: turnID) { return try done.get() }
        return try await withCheckedThrowingContinuation { continuation in
            turns[turnID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                await self?.finishTurn(turnID, .failure(SubtitleError.codex("逾時")))
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // 伺服器要權限之類的：一律拒絕。
                send(["id": id, "error": ["code": -32601, "message": "Squelch does not handle \(method)"]])
                return
            }
            notification(method, message["params"] as? [String: Any] ?? [:])
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue, let continuation = responses.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: SubtitleError.codex(error["message"] as? String ?? "unknown error"))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            if let turnID = params["turnId"] as? String, let delta = params["delta"] as? String {
                turnText[turnID, default: ""] += delta
            }
        case "item/completed":
            if let turnID = params["turnId"] as? String, let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage", let text = item["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finishTurn(turnID, .success(text))
            }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String ?? params["turnId"] as? String else { return }
            if turn["status"] as? String != "completed" {
                let error = (turn["error"] as? [String: Any])?["message"] as? String ?? turn["status"] as? String ?? "failed"
                finishTurn(turnID, .failure(SubtitleError.codex(error)))
            } else if let text = turnText[turnID], !text.isEmpty {
                finishTurn(turnID, .success(text))
            } else {
                finishTurn(turnID, .failure(SubtitleError.badTranslation))
            }
        default:
            break
        }
    }

    private func finishTurn(_ turnID: String, _ result: Result<String, Error>) {
        turnText[turnID] = nil
        if let continuation = turns.removeValue(forKey: turnID) {
            continuation.resume(with: result)
        } else if finishedTurns[turnID] == nil {
            finishedTurns[turnID] = result
            if finishedTurns.count > 32 { finishedTurns.removeAll() }
        }
    }

    private func timeoutRequest(_ id: Int) {
        responses.removeValue(forKey: id)?.resume(throwing: SubtitleError.codex("沒有回應"))
    }

    private func cancelRequest(_ id: Int) {
        responses.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func exited() {
        process = nil
        input = nil
        failAll(SubtitleError.codex("codex app-server 結束了"))
    }

    private func failAll(_ error: Error) {
        for continuation in responses.values { continuation.resume(throwing: error) }
        responses.removeAll()
        for continuation in turns.values { continuation.resume(throwing: error) }
        turns.removeAll()
        turnText.removeAll()
    }
}

/// stdout 的資料切成一行一行。readabilityHandler 在背景執行緒呼叫，一次只會有一個。
nonisolated private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
