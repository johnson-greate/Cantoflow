namespace CantoFlow.App;

/// <summary>
/// Parses a hotkey string like "Ctrl+Shift+Space" into Win32 VK code + modifier flags.
/// Stored in cantoflow.env as CANTOFLOW_HOTKEY=Ctrl+Shift+Space.
/// </summary>
public sealed class HotkeyConfig
{
    public uint Vk        { get; }
    public uint Modifiers { get; }
    public string Display { get; }

    private const uint MOD_ALT   = 0x0001;
    private const uint MOD_CTRL  = 0x0002;
    private const uint MOD_SHIFT = 0x0004;
    private const uint MOD_WIN   = 0x0008;

    public HotkeyConfig(uint vk, uint modifiers, string display)
    {
        Vk        = vk;
        Modifiers = modifiers;
        Display   = display;
    }

    public static HotkeyConfig Default => Parse("Ctrl+Shift+Space") ?? ParseFallback();

    public static HotkeyConfig? Parse(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;

        var parts = raw.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        uint mods = 0;
        uint vk   = 0;

        foreach (var part in parts)
        {
            switch (part.ToUpperInvariant())
            {
                case "CTRL":  case "CONTROL": mods |= MOD_CTRL;  break;
                case "ALT":                   mods |= MOD_ALT;   break;
                case "SHIFT":                 mods |= MOD_SHIFT; break;
                case "WIN":                   mods |= MOD_WIN;   break;
                default:
                    vk = ParseVk(part);
                    break;
            }
        }

        if (vk == 0) return null;
        return new HotkeyConfig(vk, mods, raw.Trim());
    }

    public static HotkeyConfig FromKeyDown(Keys keyData)
    {
        uint mods = 0;
        if ((keyData & Keys.Control) != 0) mods |= MOD_CTRL;
        if ((keyData & Keys.Alt)     != 0) mods |= MOD_ALT;
        if ((keyData & Keys.Shift)   != 0) mods |= MOD_SHIFT;

        var key  = keyData & Keys.KeyCode;
        var vk   = (uint)key;
        var display = BuildDisplay(mods, key);
        return new HotkeyConfig(vk, mods, display);
    }

    private static string BuildDisplay(uint mods, Keys key)
    {
        var parts = new List<string>();
        if ((mods & MOD_CTRL)  != 0) parts.Add("Ctrl");
        if ((mods & MOD_ALT)   != 0) parts.Add("Alt");
        if ((mods & MOD_SHIFT) != 0) parts.Add("Shift");
        parts.Add(KeyToName(key));
        return string.Join("+", parts);
    }

    private static string KeyToName(Keys key) => key switch
    {
        Keys.Space       => "Space",
        Keys.F1          => "F1",  Keys.F2  => "F2",  Keys.F3  => "F3",  Keys.F4  => "F4",
        Keys.F5          => "F5",  Keys.F6  => "F6",  Keys.F7  => "F7",  Keys.F8  => "F8",
        Keys.F9          => "F9",  Keys.F10 => "F10", Keys.F11 => "F11", Keys.F12 => "F12",
        Keys.OemQuestion => "/",   Keys.Oemtilde => "`",
        _                => key.ToString()
    };

    private static uint ParseVk(string key) => key.ToUpperInvariant() switch
    {
        "SPACE"  => 0x20,
        "F1"     => 0x70, "F2"  => 0x71, "F3"  => 0x72, "F4"  => 0x73,
        "F5"     => 0x74, "F6"  => 0x75, "F7"  => 0x76, "F8"  => 0x77,
        "F9"     => 0x78, "F10" => 0x79, "F11" => 0x7A, "F12" => 0x7B,
        "A" => 0x41, "B" => 0x42, "C" => 0x43, "D" => 0x44, "E" => 0x45,
        "F" => 0x46, "G" => 0x47, "H" => 0x48, "I" => 0x49, "J" => 0x4A,
        "K" => 0x4B, "L" => 0x4C, "M" => 0x4D, "N" => 0x4E, "O" => 0x4F,
        "P" => 0x50, "Q" => 0x51, "R" => 0x52, "S" => 0x53, "T" => 0x54,
        "U" => 0x55, "V" => 0x56, "W" => 0x57, "X" => 0x58, "Y" => 0x59,
        "Z" => 0x5A,
        _   => 0
    };

    private static HotkeyConfig ParseFallback() => new(0x20, MOD_CTRL | MOD_SHIFT, "Ctrl+Shift+Space");
}
