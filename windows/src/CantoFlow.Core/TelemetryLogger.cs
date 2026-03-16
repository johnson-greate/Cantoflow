using System.Text.Json;
using System.Text.Json.Serialization;

namespace CantoFlow.Core;

public class TelemetryLogger(string filePath)
{
    private readonly object _lock = new();
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public void Log(TelemetryEntry entry)
    {
        var json = JsonSerializer.Serialize(entry, JsonOpts);
        lock (_lock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
            File.AppendAllText(filePath, json + "\n\n"); // double newline matches macOS format
        }
    }

    public static string IsoTimestamp() =>
        DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

    public static string FileTimestamp() =>
        DateTimeOffset.UtcNow.ToString("yyyyMMdd_HHmmss");
}

public class TelemetryEntry
{
    public string Timestamp { get; set; } = "";
    public string Provider { get; set; } = "none";
    public string PolishStatus { get; set; } = "not_run";
    public string RawText { get; set; } = "";
    public string FinalText { get; set; } = "";
    public string SttProfile { get; set; } = "fast";
    public LatencyMs LatencyMs { get; set; } = new();
}

public class LatencyMs
{
    public int Record { get; set; }
    public int Stt { get; set; }
    public int Polish { get; set; }
    public int Total => Record + Stt + Polish;
}
