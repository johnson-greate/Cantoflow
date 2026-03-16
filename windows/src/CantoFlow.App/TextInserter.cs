using System.Runtime.InteropServices;
using System.Text;

namespace CantoFlow.App;

/// <summary>
/// Inserts text into the focused application via clipboard + Ctrl+V.
/// Detects terminal applications and applies safety rules (no raw paste in terminals).
/// Mirrors macOS TextInserter.swift.
/// </summary>
public static class TextInserter
{
    // Terminal process names — same safety rule as macOS bundle-ID list
    private static readonly HashSet<string> TerminalProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "cmd", "powershell", "pwsh", "wt",
        "ConEmu64", "mintty", "alacritty", "Code" // VSCode integrated terminal
    };

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static bool IsForegroundAppTerminal()
    {
        var hwnd = GetForegroundWindow();
        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            var proc = System.Diagnostics.Process.GetProcessById((int)pid);
            return TerminalProcessNames.Contains(proc.ProcessName);
        }
        catch { return false; }
    }

    /// <summary>
    /// Copy text to clipboard and simulate Ctrl+V paste.
    /// Restores the previous clipboard content after paste.
    /// </summary>
    public static void InsertViaClipboard(string text)
    {
        var previous = Clipboard.GetText();
        Clipboard.SetText(text);
        SendCtrlV();
        Task.Delay(100).ContinueWith(_ =>
        {
            if (!string.IsNullOrEmpty(previous))
                Clipboard.SetText(previous);
        });
    }

    /// <summary>Undo last paste (Ctrl+Z), wait 50ms, then paste new text.</summary>
    public static void UndoAndReplace(string newText)
    {
        SendKeys.Send("^z");
        Thread.Sleep(50); // same 50ms delay as macOS STTPipeline.swift line 207
        InsertViaClipboard(newText);
    }

    private static void SendCtrlV() => SendKeys.Send("^v");
}
