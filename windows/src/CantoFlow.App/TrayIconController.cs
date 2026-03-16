using CantoFlow.Core;
using NAudio.Wave;

namespace CantoFlow.App;

/// <summary>
/// System tray icon + context menu.
/// Layout mirrors macOS MenuBarController.swift menu structure exactly.
/// </summary>
public class TrayIconController : IDisposable
{
    private readonly NotifyIcon    _tray;
    private readonly AppConfig     _config;

    private ToolStripMenuItem _recordItem    = null!;
    private ToolStripMenuItem _lastStatItem  = null!;
    private ToolStripMenuItem _copyLastItem  = null!;

    private string? _lastText;

    public event Action? SettingsRequested;
    public event Action? QuitRequested;
    public event Action? RecordToggleRequested;

    public TrayIconController(AppConfig config)
    {
        _config = config;
        _tray = new NotifyIcon
        {
            Text    = "CantoFlow",
            Visible = true,
            Icon    = SystemIcons.Application
        };
        _tray.ContextMenuStrip = BuildMenu();
    }

    // ── Public update API (thread-safe) ───────────────────────────────────────

    public void UpdateRecordingState(bool isRecording)
    {
        Invoke(() =>
        {
            _recordItem.Text = isRecording ? "Stop Recording" : "Start Recording";
            _tray.Text       = isRecording ? "CantoFlow — Recording…" : "CantoFlow";
        });
    }

    public void UpdateLastResult(string text, int charCount, int sttMs, int polishMs)
    {
        Invoke(() =>
        {
            _lastText = text;
            var total = sttMs + polishMs;
            _lastStatItem.Text    = $"上次: {charCount}字 · STT {sttMs / 1000.0:F1}s · LLM {polishMs / 1000.0:F1}s · 共 {total / 1000.0:F1}s";
            _lastStatItem.Visible = true;
            _copyLastItem.Enabled = true;
        });
    }

    // ── Build ─────────────────────────────────────────────────────────────────

    private ContextMenuStrip BuildMenu()
    {
        var menu    = new ContextMenuStrip();
        var boldFont = new Font(SystemFonts.MenuFont ?? SystemFonts.DefaultFont, FontStyle.Bold);
        var grayColor = SystemColors.GrayText;

        // ── Header ────────────────────────────────────────────────────────────
        menu.Items.Add(new ToolStripMenuItem("🎙  CantoFlow")
        {
            Enabled = false,
            Font    = boldFont
        });

        // Hotkey hint
        menu.Items.Add(new ToolStripMenuItem($"Press {_config.HotkeyRaw} to toggle recording")
        {
            Enabled    = false,
            ForeColor  = grayColor
        });

        // Audio input device
        menu.Items.Add(new ToolStripMenuItem($"Input: {GetDefaultInputDeviceName()}")
        {
            Enabled   = false,
            ForeColor = grayColor
        });

        menu.Items.Add(new ToolStripSeparator());

        // ── Start / Stop Recording ────────────────────────────────────────────
        _recordItem = new ToolStripMenuItem("Start Recording")
        {
            Font                    = boldFont,
            ShortcutKeyDisplayString = _config.HotkeyRaw
        };
        _recordItem.Click += (_, _) => RecordToggleRequested?.Invoke();
        menu.Items.Add(_recordItem);

        // Last session stats (hidden until first result)
        _lastStatItem = new ToolStripMenuItem("")
        {
            Enabled   = false,
            ForeColor = grayColor,
            Visible   = false
        };
        menu.Items.Add(_lastStatItem);

        // Copy Last Result
        _copyLastItem = new ToolStripMenuItem("Copy Last Result")
        {
            Enabled                  = false,
            ShortcutKeyDisplayString = "Ctrl+C"
        };
        _copyLastItem.Click += (_, _) =>
        {
            if (_lastText != null)
                try { Clipboard.SetText(_lastText); } catch { /* ignore clipboard lock */ }
        };
        menu.Items.Add(_copyLastItem);

        menu.Items.Add(new ToolStripSeparator());

        // ── Settings / Output folder ──────────────────────────────────────────
        menu.Items.Add("Settings…",            null, (_, _) => SettingsRequested?.Invoke());
        menu.Items.Add("Open Output Folder",   null, (_, _) =>
        {
            var dir = _config.OutDir;
            if (Directory.Exists(dir))
                System.Diagnostics.Process.Start("explorer.exe", dir);
        });

        menu.Items.Add(new ToolStripSeparator());

        // ── Quit / Version ────────────────────────────────────────────────────
        menu.Items.Add("Quit CantoFlow", null, (_, _) => QuitRequested?.Invoke());
        menu.Items.Add(new ToolStripMenuItem($"Version {BuildVersion.Version}") { Enabled = false });

        return menu;
    }

    private static string GetDefaultInputDeviceName()
    {
        try
        {
            if (WaveIn.DeviceCount == 0) return "No microphone";
            var caps = WaveIn.GetCapabilities(0);
            return caps.ProductName;
        }
        catch { return "System Default"; }
    }

    private void Invoke(Action a)
    {
        var strip = _tray.ContextMenuStrip;
        if (strip == null) { a(); return; }
        if (strip.InvokeRequired) strip.Invoke(a);
        else a();
    }

    public void Dispose() => _tray.Dispose();
}
