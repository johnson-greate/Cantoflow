using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Runs whisper-cli.exe and parses output.
/// Uses ArgumentList (not raw Arguments string) so CJK chars in --prompt
/// are not mangled by Windows ANSI codepage encoding.
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

        // Use all available cores up to 8 — largest single-session gain on CPU
        var threads = Math.Min(Environment.ProcessorCount, 8).ToString();

        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName               = config.WhisperCli,
            RedirectStandardOutput = true,  // must drain to prevent pipe-buffer deadlock
            RedirectStandardError  = true,
            UseShellExecute        = false,
            CreateNoWindow         = true
        };

        startInfo.ArgumentList.Add("-m");  startInfo.ArgumentList.Add(config.WhisperModel);
        startInfo.ArgumentList.Add("-f");  startInfo.ArgumentList.Add(wavPath);
        startInfo.ArgumentList.Add("-otxt");
        startInfo.ArgumentList.Add("-l");  startInfo.ArgumentList.Add("yue");  // Cantonese
        startInfo.ArgumentList.Add("--no-timestamps");
        startInfo.ArgumentList.Add("-t");  startInfo.ArgumentList.Add(threads);
        startInfo.ArgumentList.Add("--best-of"); startInfo.ArgumentList.Add("1"); // greedy — no beam search
        startInfo.ArgumentList.Add("--beam-size"); startInfo.ArgumentList.Add("1");

        if (!string.IsNullOrWhiteSpace(whisperPrompt))
        {
            startInfo.ArgumentList.Add("--prompt");
            startInfo.ArgumentList.Add(whisperPrompt);
        }

        var proc = new System.Diagnostics.Process { StartInfo = startInfo };
        proc.Start();

        // Drain stdout AND stderr concurrently — if either pipe buffer fills
        // (~4KB) without being read, the child process blocks indefinitely.
        // Large models produce verbose stderr (loading bars, compute progress).
        var stdoutTask = proc.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        await Task.WhenAll(stdoutTask, stderrTask);

        if (proc.ExitCode != 0)
            throw new InvalidOperationException($"whisper-cli exited {proc.ExitCode}: {stderrTask.Result}");

        var txtFile = wavPath + ".txt";
        return File.Exists(txtFile)
            ? (await File.ReadAllTextAsync(txtFile, ct)).Trim()
            : throw new FileNotFoundException("whisper-cli did not produce output .txt file");
    }
}
