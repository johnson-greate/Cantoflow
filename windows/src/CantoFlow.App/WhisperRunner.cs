using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Runs whisper-cli.exe and parses output.
/// Uses ProcessStartInfo.ArgumentList (not raw Arguments string) so that
/// Chinese characters in --prompt are passed as proper UTF-8 on Windows.
/// Mirrors macOS WhisperRunner.swift.
/// </summary>
public class WhisperRunner(AppConfig config)
{
    public async Task<string> TranscribeAsync(string wavPath, string? whisperPrompt = null, CancellationToken ct = default)
    {
        if (!File.Exists(config.WhisperCli))
            throw new FileNotFoundException($"whisper-cli.exe not found at {config.WhisperCli}");
        if (!File.Exists(config.WhisperModel))
            throw new FileNotFoundException($"Whisper model not found at {config.WhisperModel}");

        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName               = config.WhisperCli,
            RedirectStandardOutput = true,
            RedirectStandardError  = true,
            UseShellExecute        = false,
            CreateNoWindow         = true,
            // ArgumentList avoids Windows ANSI encoding corruption of CJK chars
            // (raw Arguments string mangles UTF-8 Chinese in --prompt on Windows)
        };

        startInfo.ArgumentList.Add("-m");
        startInfo.ArgumentList.Add(config.WhisperModel);
        startInfo.ArgumentList.Add("-f");
        startInfo.ArgumentList.Add(wavPath);
        startInfo.ArgumentList.Add("-otxt");
        startInfo.ArgumentList.Add("-l");
        startInfo.ArgumentList.Add("yue");  // Cantonese
        startInfo.ArgumentList.Add("--no-timestamps");

        if (!string.IsNullOrWhiteSpace(whisperPrompt))
        {
            startInfo.ArgumentList.Add("--prompt");
            startInfo.ArgumentList.Add(whisperPrompt);
        }

        var proc = new System.Diagnostics.Process { StartInfo = startInfo };
        proc.Start();
        await proc.WaitForExitAsync(ct);

        if (proc.ExitCode != 0)
        {
            var stderr = await proc.StandardError.ReadToEndAsync(ct);
            throw new InvalidOperationException($"whisper-cli exited {proc.ExitCode}: {stderr}");
        }

        var txtFile = wavPath + ".txt";
        return File.Exists(txtFile)
            ? (await File.ReadAllTextAsync(txtFile, ct)).Trim()
            : throw new FileNotFoundException("whisper-cli did not produce output .txt file");
    }
}
