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
        case gemini
        case openai
        case anthropic
        case qwen
        case local
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

    /// Auto-detect project root by looking for known project markers.
    private static func detectProjectRoot(args: [String]) -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        if let explicitRoot = explicitProjectRoot(from: args) {
            return explicitRoot
        }

        func looksLikeProjectRoot(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("app/Package.swift").path) ||
            fm.fileExists(atPath: url.appendingPathComponent("third_party/whisper.cpp").path)
        }

        // Check current directory
        if looksLikeProjectRoot(cwd) {
            return cwd
        }

        // Check parent directory (if running from the app subdirectory)
        let parent = cwd.deletingLastPathComponent()
        if looksLikeProjectRoot(parent) {
            return parent
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableCandidates = [
            executableURL.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]
        for path in executableCandidates where looksLikeProjectRoot(path) {
            return path
        }

        // Check common locations
        let home = fm.homeDirectoryForCurrentUser
        let commonPaths = [
            home.appendingPathComponent("Documents/CantoFlow"),
            home.appendingPathComponent("CantoFlow"),
        ]

        for path in commonPaths {
            if looksLikeProjectRoot(path) {
                return path
            }
        }

        // Fallback to current directory
        print("Warning: Could not auto-detect project root. Use --project-root to specify.")
        return cwd
    }

    private static func explicitProjectRoot(from args: [String]) -> URL? {
        var i = 1
        while i < args.count {
            if args[i] == "--project-root", i + 1 < args.count {
                return URL(fileURLWithPath: args[i + 1])
            }
            i += 1
        }
        return nil
    }

    static func fromArgs() -> AppConfig {
        var i = 1
        let args = CommandLine.arguments
        var config = AppConfig(projectRoot: detectProjectRoot(args: args))

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
          --polish-provider NAME  LLM provider: auto, gemini, openai, anthropic, qwen, local, none (default: auto)
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
          GEMINI_API_KEY         Google Gemini API key for text polishing
          DASHSCOPE_API_KEY      DashScope API key for Qwen text polishing
          OPENAI_API_KEY          OpenAI API key for text polishing
          ANTHROPIC_API_KEY       Anthropic API key for text polishing
          QWEN_API_KEY            Legacy alias for Qwen/DashScope API key
          LOCAL_LLM_ENDPOINT      Local LLM endpoint URL (default: http://localhost:11434/v1/chat/completions)
          LOCAL_LLM_MODEL         Local LLM model name (default: auto)

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
