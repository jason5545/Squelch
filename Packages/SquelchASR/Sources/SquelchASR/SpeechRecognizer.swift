import Foundation
import MLX

/// 給 Squelch 用的入口：載入 Qwen3-ASR 1.7B（8-bit），把一段 16 kHz 單聲道取樣轉成文字。
///
/// 不用 Voco 那份模型資料夾裡的 `adapters`：那是針對特定使用者聲音訓練的，拿來辨識 YouTube 只會變差。
public actor SpeechRecognizer {
    public struct Result: Sendable {
        public let text: String
        /// 模型偵測到的語言，例如 "English"、"Japanese"、"Chinese"。
        public let language: String?
        public let averageLogProbability: Double
    }

    /// 模型資料夾裡一定要有的檔案。
    public static let requiredFiles = [
        "config.json", "model.safetensors", "model.safetensors.index.json",
        "vocab.json", "merges.txt", "tokenizer_config.json"
    ]

    private let engine = Qwen3ASREngine()
    private var loadedDirectory: URL?

    public init() {}

    public var isLoaded: Bool { loadedDirectory != nil }

    public func load(modelDirectory: URL) async throws {
        if loadedDirectory == modelDirectory { return }
        try await engine.loadModel(from: modelDirectory, modelSize: .large, usesAudioAdapter: false)
        loadedDirectory = modelDirectory
    }

    public func unload() async {
        await engine.unloadModel()
        loadedDirectory = nil
    }

    public func transcribe(_ samples: [Float], language: String? = nil) async throws -> Result {
        let result = try await engine.transcribe(samples: samples, language: language)
        return Result(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      language: result.detectedLanguage,
                      averageLogProbability: result.avgLogProb)
    }
}
