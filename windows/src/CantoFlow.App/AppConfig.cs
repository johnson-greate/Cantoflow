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
    public string HotkeyDescription { get; set; } = "F15";

    public string OutDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", ".out");
    public string WhisperCli => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", "whisper", "whisper-cli.exe");
    public string WhisperModel => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", "whisper", "models", "ggml-large-v3-turbo.bin");
}
