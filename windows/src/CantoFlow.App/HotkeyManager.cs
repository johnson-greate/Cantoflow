using System.Runtime.InteropServices;

namespace CantoFlow.App;

/// <summary>
/// Registers a global hotkey via Win32 RegisterHotKey.
/// Mirrors macOS HotkeyManager.swift / PushToTalkManager.swift.
/// </summary>
public class HotkeyManager : IDisposable
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int HotkeyId = 9001;
    private readonly IntPtr _hwnd;

    public event Action? KeyPressed;
    public event Action? KeyReleased;

    public HotkeyManager(IntPtr windowHandle)
    {
        _hwnd = windowHandle;
    }

    /// <param name="vk">Virtual key code (e.g. 0x7E = F15)</param>
    /// <param name="modifiers">Modifier flags (0 = none)</param>
    public bool Register(uint vk, uint modifiers = 0)
    {
        return RegisterHotKey(_hwnd, HotkeyId, modifiers, vk);
    }

    public void Dispose() => UnregisterHotKey(_hwnd, HotkeyId);
}
