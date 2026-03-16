using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// System tray icon + context menu. Mirrors macOS MenuBarController.swift.
/// </summary>
public class TrayIconController : IDisposable
{
    private readonly NotifyIcon _tray;
    private readonly AppConfig _config;
    public event Action? SettingsRequested;
    public event Action? QuitRequested;

    public TrayIconController(AppConfig config)
    {
        _config = config;
        _tray = new NotifyIcon
        {
            Text = "CantoFlow",
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        // Icon: use a placeholder until Resources/icon.ico is added
        _tray.Icon = SystemIcons.Application;
    }

    public void SetStatus(string status) => _tray.Text = $"CantoFlow — {status}";

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Settings...", null, (_, _) => SettingsRequested?.Invoke());
        menu.Items.Add(new ToolStripSeparator());
        var versionItem = new ToolStripMenuItem($"Version {BuildVersion.Version}") { Enabled = false };
        menu.Items.Add(versionItem);
        menu.Items.Add("Quit", null, (_, _) => QuitRequested?.Invoke());
        return menu;
    }

    public void Dispose() => _tray.Dispose();
}
