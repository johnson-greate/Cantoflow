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

    public string OutDir   => Path.Combine(AppData, ".out");
    public string WhisperCli   => Path.Combine(AppData, "whisper-cli.exe");
    public string WhisperModel => Path.Combine(AppData, "models", "ggml-base.bin");
}
