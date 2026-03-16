namespace CantoFlow.App;

/// <summary>
/// Build version derived from the exe's last-write timestamp at runtime.
/// Format matches macOS AppVersion.swift: yyyyMMdd.HHmm
/// No build script required.
/// </summary>
public static class BuildVersion
{
    public static string Version
    {
        get
        {
            try
            {
                var exe = System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
                if (exe != null)
                    return File.GetLastWriteTime(exe).ToString("yyyyMMdd.HHmm");
            }
            catch { }
            return "00000000.0000";
        }
    }
}
