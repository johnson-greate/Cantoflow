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
    /// Retries up to 5 times with 50ms delay if clipboard is locked by another app.
    /// </summary>
    public static void InsertViaClipboard(string text)
    {
        for (int i = 0; i < 5; i++)
        {
            try
            {
                Clipboard.SetText(text);
                break;
            }
            catch (System.Runtime.InteropServices.ExternalException)
            {
                if (i == 4) return; // give up after 5 attempts
                Thread.Sleep(50);
            }
        }
        SendCtrlV();
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
