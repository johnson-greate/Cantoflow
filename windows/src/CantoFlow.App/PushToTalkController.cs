using System.Runtime.InteropServices;
using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Hidden message-only window that handles WM_HOTKEY for push-to-talk (toggle mode).
/// Press F9 to start recording; press F9 again to stop and transcribe.
/// Mirrors macOS PushToTalkManager.swift.
/// </summary>
public sealed class PushToTalkController : NativeWindow, IDisposable
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const int HotkeyId  = 9001;
    private const uint VK_F12   = 0x7B;

    private readonly AppConfig       _config;
    private readonly TextPolisher    _polisher;
    private readonly TelemetryLogger _telemetry;
    private readonly AudioCapture    _audio  = new();
    private readonly WhisperRunner   _whisper;
    private readonly SynchronizationContext _ui;

    private bool     _recording;
    private bool     _processing;                    // true while whisper/polish running
    private DateTime _lastToggle = DateTime.MinValue;
    private const int DebounceMs = 600;              // ignore key-repeat within 600ms
    private string?  _currentWavPath;

    public PushToTalkController(AppConfig config, TextPolisher polisher, TelemetryLogger telemetry)
    {
        _config    = config;
        _polisher  = polisher;
        _telemetry = telemetry;
        _whisper   = new WhisperRunner(config);
        _ui        = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

        // Create a message-only window (no visible UI) to receive WM_HOTKEY
        CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
        RegisterHotKey(Handle, HotkeyId, 0, VK_F12);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HotkeyId)
            _ = ToggleAsync();
        base.WndProc(ref m);
    }

    private async Task ToggleAsync()
    {
        if (_processing) return;  // whisper/polish still running, ignore

        var now = DateTime.UtcNow;
        if ((now - _lastToggle).TotalMilliseconds < DebounceMs) return;  // key-repeat
        _lastToggle = now;

        if (!_recording)
        {
            _recording = true;
            _currentWavPath = Path.Combine(_config.OutDir,
                $"ptt_{TelemetryLogger.FileTimestamp()}.wav");
            _audio.StartRecording(_currentWavPath);
        }
        else
        {
            _recording = false;
            _audio.StopRecording();
            if (_currentWavPath is { } wavPath)
            {
                _currentWavPath = null;
                _processing = true;
                try   { await ProcessAsync(wavPath); }
                finally { _processing = false; }
            }
        }
    }

    private async Task ProcessAsync(string wavPath)
    {
        using var cts = new CancellationTokenSource();
        var ct = cts.Token;
        try
        {
            var sttStart      = DateTimeOffset.UtcNow;
            var whisperPrompt = VocabularyStore.GenerateWhisperPrompt();
            var rawText       = await _whisper.TranscribeAsync(wavPath, whisperPrompt, ct);
            var sttMs    = (int)(DateTimeOffset.UtcNow - sttStart).TotalMilliseconds;

            var finalText    = rawText;
            var polishMs     = 0;
            var provider     = "none";
            var polishStatus = "not_run";

            if (_polisher.IsAvailable())
            {
                try
                {
                    var vocabSection = VocabularyStore.GeneratePolishPromptSection();
                    var r    = await _polisher.PolishAsync(rawText, vocabularySection: vocabSection, ct: ct);
                    finalText    = r.Text;
                    polishMs     = r.DurationMs;
                    provider     = r.Provider.ToString().ToLower();
                    polishStatus = "ok";
                }
                catch (Exception ex) { polishStatus = $"failed: {ex.Message}"; }
            }

            _telemetry.Log(new TelemetryEntry
            {
                Timestamp    = TelemetryLogger.IsoTimestamp(),
                Provider     = provider,
                PolishStatus = polishStatus,
                RawText      = rawText,
                FinalText    = finalText,
                LatencyMs    = new LatencyMs { Stt = sttMs, Polish = polishMs }
            });

            if (!string.IsNullOrWhiteSpace(finalText))
                _ui.Post(_ => TextInserter.InsertViaClipboard(finalText), null);
        }
        catch (Exception ex)
        {
            _ui.Post(_ => MessageBox.Show(
                $"Transcription failed:\n{ex.Message}", "CantoFlow",
                MessageBoxButtons.OK, MessageBoxIcon.Warning), null);
        }
    }

    public void Dispose()
    {
        UnregisterHotKey(Handle, HotkeyId);
        _audio.Dispose();
        DestroyHandle();
    }
}
