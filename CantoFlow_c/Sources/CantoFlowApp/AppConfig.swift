import Foundation

/// Application configuration parsed from CLI arguments
struct AppConfig {
    var projectRoot: URL
    var sttProfile: STTProfile = .fast
    var sttBackend: STTBackend = .whisper
    var audioDevice: String = "MacBook Air Microphone"
    var fastIME: Bool = false
    var autoPaste: Bool = false
    var autoReplace: Bool = false
    var polishProvider: PolishProvider = .auto
    var whisperPath: String? = nil
    var modelPath: String? = nil

    // FunASR server configuration
    var funasrHost: String = "127.0.0.1"
    var funasrPort: Int = 8765

    enum STTProfile: String, CaseIterable {
        case fast
        case balanced
        case accurate
    }

    enum STTBackend: String, CaseIterable {
        case whisper   // Local whisper.cpp
        case funasr    // FunASR HTTP server
    }

    enum PolishProvider: String, CaseIterable {
        case auto
        case openai
        case anthropic
        case qwen
        case none
    }

    /// Resolved paths based on projectRoot
    var outDir: URL { projectRoot.appendingPathComponent(".out", isDirectory: true) }
    var telemetryFile: URL { outDir.appendingPathComponent("telemetry.jsonl") }

    var whisperCLI: URL {
        if let path = whisperPath {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent("third_party/whisper.cpp/build/bin/whisper-cli")
    }

    var turboModelPath: URL {
        projectRoot.appendingPathComponent("third_party/whisper.cpp/models/ggml-large-v3-turbo.bin")
    }

    var largeModelPath: URL {
        projectRoot.appendingPathComponent("third_party/whisper.cpp/models/ggml-large-v3.bin")
    }

    var smallModelPath: URL {
        projectRoot.appendingPathComponent("third_party/whisper.cpp/models/ggml-small.bin")
    }

    /// Resolve the best available model based on profile and availability
    func resolveModelPath() -> URL {
        if let path = modelPath {
            return URL(fileURLWithPath: path)
        }

        let fm = FileManager.default
        switch sttProfile {
        case .fast:
            if fm.fileExists(atPath: turboModelPath.path) {
                return turboModelPath
            } else if fm.fileExists(atPath: largeModelPath.path) {
                return largeModelPath
            } else {
                return smallModelPath
            }
        case .balanced, .accurate:
            if fm.fileExists(atPath: largeModelPath.path) {
                return largeModelPath
            } else if fm.fileExists(atPath: turboModelPath.path) {
                return turboModelPath
            } else {
                return smallModelPath
            }
        }
    }

    static func fromArgs() -> AppConfig {
        var config = AppConfig(projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var i = 1
        let args = CommandLine.arguments

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--project-root":
                if i + 1 < args.count {
                    config.projectRoot = URL(fileURLWithPath: args[i + 1])
                    i += 1
                }
            case "--stt-profile":
                if i + 1 < args.count, let profile = STTProfile(rawValue: args[i + 1]) {
                    config.sttProfile = profile
                    i += 1
                }
            case "--audio-device":
                if i + 1 < args.count {
                    config.audioDevice = args[i + 1]
                    i += 1
                }
            case "--whisper":
                if i + 1 < args.count {
                    config.whisperPath = args[i + 1]
                    i += 1
                }
            case "--model":
                if i + 1 < args.count {
                    config.modelPath = args[i + 1]
                    i += 1
                }
            case "--polish-provider":
                if i + 1 < args.count, let provider = PolishProvider(rawValue: args[i + 1]) {
                    config.polishProvider = provider
                    i += 1
                }
            case "--stt-backend":
                if i + 1 < args.count, let backend = STTBackend(rawValue: args[i + 1]) {
                    config.sttBackend = backend
                    i += 1
                }
            case "--funasr-host":
                if i + 1 < args.count {
                    config.funasrHost = args[i + 1]
                    i += 1
                }
            case "--funasr-port":
                if i + 1 < args.count, let port = Int(args[i + 1]) {
                    config.funasrPort = port
                    i += 1
                }
            case "--fast-ime":
                config.fastIME = true
                config.autoPaste = true
                config.autoReplace = true
            case "--no-fast-ime":
                config.fastIME = false
            case "--auto-paste":
                config.autoPaste = true
            case "--no-auto-paste":
                config.autoPaste = false
            case "--auto-replace":
                config.autoReplace = true
            case "--no-auto-replace":
                config.autoReplace = false
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                break
            }
            i += 1
        }

        return config
    }

    static func printUsage() {
        let usage = """
        CantoFlow_c - Cantonese Speech-to-Text for macOS

        Usage:
          cantoflow [OPTIONS]

        Options:
          --project-root PATH     Project root directory (default: current directory)
          --stt-profile PROFILE   STT profile: fast, balanced, accurate (default: fast)
          --stt-backend BACKEND   STT backend: whisper, funasr (default: whisper)
          --audio-device NAME     Audio input device name (default: MacBook Air Microphone)
          --whisper PATH          Path to whisper-cli binary
          --model PATH            Path to whisper model file
          --polish-provider NAME  LLM provider: auto, openai, anthropic, qwen, none (default: auto)
          --funasr-host HOST      FunASR server host (default: 127.0.0.1)
          --funasr-port PORT      FunASR server port (default: 8765)
          --fast-ime              Enable fast IME mode (paste raw, then replace with polished)
          --no-fast-ime           Disable fast IME mode
          --auto-paste            Auto-paste transcribed text
          --no-auto-paste         Disable auto-paste
          --auto-replace          Auto-replace raw with polished text
          --no-auto-replace       Disable auto-replace
          -h, --help              Show this help message

        Environment Variables:
          OPENAI_API_KEY          OpenAI API key for text polishing
          ANTHROPIC_API_KEY       Anthropic API key for text polishing
          QWEN_API_KEY            Qwen/DashScope API key for text polishing

        STT Backends:
          whisper                 Local whisper.cpp (default, ~4-5s latency)
          funasr                  FunASR HTTP server (requires separate server, ~300ms streaming)

        Hotkeys:
          Fn (Globe key) or F12   Toggle recording

        Permissions Required:
          - Microphone access (for audio recording)
          - Accessibility (for hotkey and text insertion)
          - Input Monitoring (for Fn key detection)
        """
        print(usage)
    }
}
