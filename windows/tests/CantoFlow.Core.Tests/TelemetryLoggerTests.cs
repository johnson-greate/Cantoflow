// windows/tests/CantoFlow.Core.Tests/TelemetryLoggerTests.cs
using Xunit;
using CantoFlow.Core;

namespace CantoFlow.Core.Tests;

public class TelemetryLoggerTests
{
    [Fact]
    public void Log_WritesValidJsonEntryToFile()
    {
        var tmpFile = Path.GetTempFileName();
        var logger = new TelemetryLogger(tmpFile);
        var entry = new TelemetryEntry
        {
            Timestamp = "2026-03-16T05:00:00Z",
            Provider = "qwen",
            PolishStatus = "ok",
            RawText = "raw",
            FinalText = "polished",
            LatencyMs = new LatencyMs { Stt = 3000, Polish = 1500, Record = 5000 }
        };
        logger.Log(entry);
        var lines = File.ReadAllLines(tmpFile).Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
        Assert.Single(lines);
        var opts = new System.Text.Json.JsonSerializerOptions
        {
            PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower,
            PropertyNameCaseInsensitive = true
        };
        var parsed = System.Text.Json.JsonSerializer.Deserialize<TelemetryEntry>(lines[0], opts);
        Assert.NotNull(parsed);
        Assert.Equal("qwen", parsed.Provider);
        Assert.Equal("polished", parsed.FinalText);
        File.Delete(tmpFile);
    }
}
