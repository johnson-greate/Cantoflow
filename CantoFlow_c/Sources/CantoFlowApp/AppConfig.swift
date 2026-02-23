import Foundation

/// Application configuration parsed from CLI arguments
struct AppConfig {
    var projectRoot: URL
    var sttProfile: STTProfile = .fast
    var audioDevice: String = "MacBook Air Microphone"
    var fastIME: Bool = true
    var autoPaste: Bool = true
    var autoReplace: Bool = false
    var polishProvider: PolishProvider = .auto
    var whisperPath: String? = nil
    var modelPath: String? = nil

    // Phase 2: Push-to-Talk configuration
    var triggerKey: String = "auto"  // "auto", "fn", "f12", "f13", "f14", "f15"
    var showOverlay: Bool = true
    var useVocabulary: Bool = true

    // Metal GPU acceleration
    var useMetalGPU: Bool = true

    enum STTProfile: String, CaseIterable {
        case fast
        case balanced
        case accurate
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

    /// Auto-detect project root by looking for third_party/whisper.cpp
    private static func detectProjectRoot() -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Check current directory
        if fm.fileExists(atPath: cwd.appendingPathComponent("third_party/whisper.cpp").path) {
            return cwd
        }

        // Check parent directory (if running from CantoFlow_c)
        let parent = cwd.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.appendingPathComponent("third_party/whisper.cpp").path) {
            return parent
        }

        // Check common locations
        let home = fm.homeDirectoryForCurrentUser
        let commonPaths = [
            home.appendingPathComponent("Documents/CantoFlow"),
            home.appendingPathComponent("CantoFlow"),
        ]

        for path in commonPaths {
            if fm.fileExists(atPath: path.appendingPathComponent("third_party/whisper.cpp").path) {
                return path
            }
        }

        // Fallback to current directory
        print("Warning: Could not auto-detect project root. Use --project-root to specify.")
        return cwd
    }

    static func fromArgs() -> AppConfig {
        var config = AppConfig(projectRoot: detectProjectRoot())
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
            case "--trigger-key":
                if i + 1 < args.count {
                    config.triggerKey = args[i + 1]
                    i += 1
                }
            case "--no-overlay":
                config.showOverlay = false
            case "--no-vocabulary":
                config.useVocabulary = false
            case "--no-metal":
                config.useMetalGPU = false
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
        CantoFlow - Cantonese Speech-to-Text for macOS (Phase 2)

        Usage:
          cantoflow [OPTIONS]

        Options:
          --project-root PATH     Project root directory (default: current directory)
          --stt-profile PROFILE   STT profile: fast, balanced, accurate (default: fast)
          --audio-device NAME     Audio input device name (default: MacBook Air Microphone)
          --whisper PATH          Path to whisper-cli binary
          --model PATH            Path to whisper model file
          --polish-provider NAME  LLM provider: auto, openai, anthropic, qwen, none (default: auto)
          --fast-ime              Enable fast IME mode (paste raw, then replace with polished)
          --no-fast-ime           Disable fast IME mode
          --auto-paste            Auto-paste transcribed text
          --no-auto-paste         Disable auto-paste
          --auto-replace          Auto-replace raw with polished text
          --no-auto-replace       Disable auto-replace
          --trigger-key KEY       Trigger key: auto, fn, f12, f13, f14, f15 (default: auto)
          --no-overlay            Disable recording overlay panel
          --no-vocabulary         Disable vocabulary injection
          --no-metal              Disable Metal GPU acceleration (use CPU only)
          -h, --help              Show this help message

        Environment Variables:
          OPENAI_API_KEY          OpenAI API key for text polishing
          ANTHROPIC_API_KEY       Anthropic API key for text polishing
          QWEN_API_KEY            Qwen/DashScope API key for text polishing

        Push-to-Talk:
          Hold Fn (MacBook) or F15 (external keyboard) to record.
          Release to stop recording and process.
          Recording < 0.3s is treated as accidental tap and cancelled.

        Vocabulary System:
          Personal vocabulary stored in ~/Library/Application Support/CantoFlow/
          Built-in Hong Kong vocabulary (MTR stations, place names, slang, etc.)
          Vocabulary is injected into Whisper and LLM prompts for better accuracy.

        Permissions Required:
          - Microphone access (for audio recording)
          - Accessibility (for hotkey and text insertion)
          - Input Monitoring (for Fn/F15 key detection)
        """
        print(usage)
    }
}
