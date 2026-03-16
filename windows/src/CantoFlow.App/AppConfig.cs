using CantoFlow.Core;

namespace CantoFlow.App;

public class AppConfig
{
    // Defaults mirror macOS AppConfig.swift
    public bool FastIME { get; set; } = true;
    public bool AutoPaste { get; set; } = true;
    public bool AutoReplace { get; set; } = false; // conservative default (same as macOS)
    public PolishProvider PolishProvider { get; set; } = PolishProvider.Auto;
    public string PolishStyle { get; set; } = "cantonese";
    public bool ServerEnabled { get; set; } = true;
    public int ServerPort { get; set; } = 8765;
    public string HotkeyRaw { get; set; } = "Ctrl+Shift+Space";

    public HotkeyConfig Hotkey => HotkeyConfig.Parse(HotkeyRaw) ?? HotkeyConfig.Default;

    private static string AppData => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow");

    public string OutDir     => Path.Combine(AppData, ".out");
    public string WhisperCli => Path.Combine(AppData, "whisper-cli.exe");

    /// <summary>
    /// Auto-derived OpenVINO encoder path (e.g. ggml-large-v3-turbo-encoder-openvino.xml).
    /// Created by: python convert-whisper-to-openvino.py --model large-v3-turbo
    /// If this file exists, WhisperRunner adds --openvino-encode-device GPU automatically.
    /// </summary>
    public string WhisperOpenVinoEncoder
    {
        get
        {
            var model = WhisperModel;
            var dir   = Path.GetDirectoryName(model) ?? "";
            var stem  = Path.GetFileNameWithoutExtension(model); // ggml-large-v3-turbo
            return Path.Combine(dir, stem + "-encoder-openvino.xml");
        }
    }

    /// <summary>
    /// Auto-selects best available model in %APPDATA%\CantoFlow\models\.
    /// Preference: large-v3-turbo > large-v3 > medium > base.
    /// </summary>
    public string WhisperModel
    {
        get
        {
            var modelsDir = Path.Combine(AppData, "models");
            string[] preference =
            [
                "ggml-large-v3-turbo-q5_0.bin",  // quantized — faster, near-identical quality
                "ggml-large-v3-turbo.bin",
                "ggml-large-v3.bin",
                "ggml-medium.bin",
                "ggml-base.bin"
            ];
            foreach (var name in preference)
            {
                var path = Path.Combine(modelsDir, name);
                if (File.Exists(path)) return path;
            }
            // Fallback: first .bin found
            var any = Directory.Exists(modelsDir)
                ? Directory.EnumerateFiles(modelsDir, "*.bin").FirstOrDefault()
                : null;
            return any ?? Path.Combine(modelsDir, "ggml-base.bin");
        }
    }
}
