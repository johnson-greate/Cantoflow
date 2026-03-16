using CantoFlow.Core;

namespace CantoFlow.Server;

public class TranscriptionServer
{
    private readonly TextPolisher _polisher;
    private readonly TelemetryLogger _telemetry;
    private readonly SemaphoreSlim _semaphore = new(1, 1); // one job at a time
    private readonly string _version;
    private readonly string _outDir;

    public TranscriptionServer(TextPolisher polisher, TelemetryLogger telemetry,
        string version, string outDir)
    {
        _polisher = polisher;
        _telemetry = telemetry;
        _version = version;
        _outDir = outDir;
        Directory.CreateDirectory(outDir);
    }

    public object GetHealth() => new
    {
        status = "ok",
        version = _version,
        polish_available = _polisher.IsAvailable()
    };

    public async Task<(int statusCode, object body)> TranscribeAsync(
        Stream audioStream, string fileName, CancellationToken ct)
    {
        // Validate WAV header (RIFF magic bytes)
        var header = new byte[4];
        var bytesRead = await audioStream.ReadAsync(header.AsMemory(0, 4), ct);
        if (bytesRead < 4 || header[0] != 'R' || header[1] != 'I' || header[2] != 'F' || header[3] != 'F')
            return (400, new { error = "invalid_audio", message = "Expected WAV file with RIFF header" });

        // Reset stream and save to temp file
        audioStream.Seek(0, SeekOrigin.Begin);
        var stamp = TelemetryLogger.FileTimestamp();
        var wavPath = Path.Combine(_outDir, $"mobile_{stamp}.wav");
        await using (var fs = File.Create(wavPath))
            await audioStream.CopyToAsync(fs, ct);

        // Acquire transcription slot — reject if busy
        if (!await _semaphore.WaitAsync(0, ct))
            return (503, new { error = "server_busy" });

        try
        {
            // TODO(windows-only): Run whisper.cpp CLI and get rawText
            // For now, return a stub so the server layer can be tested end-to-end
            var rawText = $"[whisper stub: {Path.GetFileName(wavPath)}]";
            var finalText = rawText;
            var polishStatus = "not_run";
            var polishMs = 0;
            var provider = "none";

            if (_polisher.IsAvailable())
            {
                try
                {
                    var result = await _polisher.PolishAsync(rawText, ct: ct);
                    finalText = result.Text;
                    polishMs = result.DurationMs;
                    provider = result.Provider.ToString().ToLower();
                    polishStatus = "ok";
                }
                catch (Exception ex)
                {
                    polishStatus = $"failed: {ex.Message}";
                }
            }

            _telemetry.Log(new TelemetryEntry
            {
                Timestamp = TelemetryLogger.IsoTimestamp(),
                Provider = provider,
                PolishStatus = polishStatus,
                RawText = rawText,
                FinalText = finalText,
                LatencyMs = new LatencyMs { Polish = polishMs }
            });

            return (200, new
            {
                text = finalText,
                raw = rawText,
                provider,
                polish_ms = polishMs,
                stt_ms = 0 // filled in when whisper stub is replaced
            });
        }
        finally
        {
            _semaphore.Release();
        }
    }
}
