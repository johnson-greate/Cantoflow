import Foundation

/// Speech-recognition engines available in CantoFlow.
enum STTEngine: String, CaseIterable, Identifiable {
    case whisper
    case senseVoice = "sensevoice"
    case qwen3ASR = "qwen3-asr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .senseVoice: return "SenseVoice INT8"
        case .qwen3ASR: return "Qwen3-ASR 8-bit"
        }
    }

    var shortName: String {
        switch self {
        case .whisper: return "Whisper"
        case .senseVoice: return "SenseVoice"
        case .qwen3ASR: return "Qwen3"
        }
    }

    var detail: String {
        switch self {
        case .whisper:
            return "現有穩定基準；whisper.cpp + Metal，支援 vocabulary prompt。"
        case .senseVoice:
            return "234M INT8 粵語模型；體積小、CPU 推論快，適合比較原始辨識速度。"
        case .qwen3ASR:
            return "0.6B MLX 8-bit；使用 Apple GPU，原生支援 Cantonese 及 context vocabulary。"
        }
    }
}

/// Stable on-disk locations shared by the Swift app and the local ASR bridge.
struct ASRRuntimePaths {
    static let senseVoiceDirectoryName = "sensevoice-small-int8-2025-09-09"
    static let qwenDirectoryName = "qwen3-asr-0.6b-8bit"

    let root: URL

    init(root: URL = ASRRuntimePaths.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CANTOFLOW_ASR_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CantoFlow/asr-runtime", isDirectory: true)
    }

    var python: URL { root.appendingPathComponent("venv/bin/python3") }
    var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }

    /// Environment that forces fully-local model loading. Without this,
    /// `mlx_qwen3_asr.load_model` still contacts the HuggingFace Hub even when
    /// given a local model dir — and if the user's HF cache lives on an unplugged
    /// external volume (e.g. /Volumes/JTDev) that aborts with a permission error.
    /// Also keeps any HF cache inside our own runtime dir and skips the slow
    /// first-run fetch (works offline for students).
    var offlineModelEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let hfHome = root.appendingPathComponent("hf-home", isDirectory: true).path
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HOME"] = hfHome
        env["HUGGINGFACE_HUB_CACHE"] = hfHome + "/hub"
        return env
    }
    var senseVoiceDirectory: URL { modelsDirectory.appendingPathComponent(Self.senseVoiceDirectoryName, isDirectory: true) }
    var senseVoiceModel: URL { senseVoiceDirectory.appendingPathComponent("model.int8.onnx") }
    var senseVoiceTokens: URL { senseVoiceDirectory.appendingPathComponent("tokens.txt") }
    var qwenModelDirectory: URL { modelsDirectory.appendingPathComponent(Self.qwenDirectoryName, isDirectory: true) }

    func readiness(for engine: STTEngine, config: AppConfig) -> (ready: Bool, message: String) {
        let fm = FileManager.default

        switch engine {
        case .whisper:
            let model = config.resolveModelPath()
            let ready = fm.isExecutableFile(atPath: config.whisperCLI.path) && fm.fileExists(atPath: model.path)
            return ready
                ? (true, "已安裝 · \(model.lastPathComponent)")
                : (false, "尚未齊備 whisper-cli 或 Whisper 模型")

        case .senseVoice:
            let ready = fm.isExecutableFile(atPath: python.path)
                && fm.fileExists(atPath: senseVoiceModel.path)
                && fm.fileExists(atPath: senseVoiceTokens.path)
            return ready
                ? (true, "已安裝 · SenseVoiceSmall INT8 (2025-09-09)")
                : (false, "尚未安裝約 166 MB 模型及本機 runtime")

        case .qwen3ASR:
            let configFile = qwenModelDirectory.appendingPathComponent("config.json")
            let hasWeights = ((try? fm.contentsOfDirectory(at: qwenModelDirectory, includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension == "safetensors" }
            let ready = fm.isExecutableFile(atPath: python.path)
                && fm.fileExists(atPath: configFile.path)
                && hasWeights
            return ready
                ? (true, "已安裝 · Qwen3-ASR 0.6B MLX 8-bit")
                : (false, "尚未安裝；首次準備需下載並量化模型")
        }
    }
}
