namespace CantoFlow.App;

/// <summary>
/// Build timestamp embedded at compile time via MSBuild.
/// Format matches macOS AppVersion.swift: yyyyMMdd.HHmm
/// </summary>
public static class BuildVersion
{
    // This constant is rewritten by the pre-build script (see Directory.Build.targets)
    public const string Version = "00000000.0000";
}
