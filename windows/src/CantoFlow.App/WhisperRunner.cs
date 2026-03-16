using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Runs whisper-cli.exe and parses output.
/// Mirrors macOS WhisperRunner.swift.
/// </summary>
public class WhisperRunner(AppConfig config)
{
    public async Task<string> TranscribeAsync(string wavPath, CancellationToken ct = default)
    {
        if (!File.Exists(config.WhisperCli))
            throw new FileNotFoundException($"whisper-cli.exe not found at {config.WhisperCli}");
        if (!File.Exists(config.WhisperModel))
            throw new FileNotFoundException($"Whisper model not found at {config.WhisperModel}");

        var outputPrefix = Path.Combine(config.OutDir,
            "raw_" + TelemetryLogger.FileTimestamp());

        var proc = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = config.WhisperCli,
                Arguments = $"-m \"{config.WhisperModel}\" -f \"{wavPath}\" -of \"{outputPrefix}\" -otxt -l zh --no-timestamps",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };

        proc.Start();
        await proc.WaitForExitAsync(ct);

        if (proc.ExitCode != 0)
        {
            var stderr = await proc.StandardError.ReadToEndAsync(ct);
            throw new InvalidOperationException($"whisper-cli exited {proc.ExitCode}: {stderr}");
        }

        var txtFile = outputPrefix + ".txt";
        return File.Exists(txtFile)
            ? (await File.ReadAllTextAsync(txtFile, ct)).Trim()
            : throw new FileNotFoundException("whisper-cli did not produce output .txt file");
    }
}
