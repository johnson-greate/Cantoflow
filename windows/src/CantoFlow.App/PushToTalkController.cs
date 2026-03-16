using System.Runtime.InteropServices;
using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Hidden message-only window that handles WM_HOTKEY for push-to-talk (toggle mode).
/// Press hotkey to start recording; press again to stop and transcribe.
/// Mirrors macOS PushToTalkManager.swift.
/// Shows RecordingOverlay during recording/transcription and updates the tray menu.
/// </summary>
public sealed class PushToTalkController : NativeWindow, IDisposable
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const int HotkeyId  = 9001;

    private readonly AppConfig            _config;
    private readonly TextPolisher         _polisher;
    private readonly TelemetryLogger      _telemetry;
    private readonly TrayIconController   _tray;
    private readonly AudioCapture         _audio    = new();
    private readonly WhisperRunner        _whisper;
    private readonly RecordingOverlay     _overlay;
    private readonly SynchronizationContext _ui;

    private bool     _recording;
    private bool     _processing;
    private DateTime _lastToggle = DateTime.MinValue;
    private const int DebounceMs = 600;
    private string?  _currentWavPath;

    public PushToTalkController(AppConfig config, TextPolisher polisher,
                                TelemetryLogger telemetry, TrayIconController tray)
    {
        _config    = config;
        _polisher  = polisher;
        _telemetry = telemetry;
        _tray      = tray;
        _whisper   = new WhisperRunner(config);
        _ui        = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

        // Recording overlay (created on UI thread)
        _overlay = new RecordingOverlay();

        // Forward microphone level to overlay
        _audio.LevelChanged += level => _overlay.SetLevel(level);

        // Create a message-only window (no visible UI) to receive WM_HOTKEY
        CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
        RegisterHotKey(Handle, HotkeyId, config.Hotkey.Modifiers, config.Hotkey.Vk);
    }

    /// <summary>Can be called from the tray menu "Start/Stop Recording" item.</summary>
    public void TriggerToggle() => _ = ToggleAsync();

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HotkeyId)
            _ = ToggleAsync();
        base.WndProc(ref m);
    }

    private async Task ToggleAsync()
    {
        if (_processing) return;

        var now = DateTime.UtcNow;
        if ((now - _lastToggle).TotalMilliseconds < DebounceMs) return;
        _lastToggle = now;

        if (!_recording)
        {
            _recording      = true;
            _currentWavPath = Path.Combine(_config.OutDir,
                $"ptt_{TelemetryLogger.FileTimestamp()}.wav");
            _audio.StartRecording(_currentWavPath);

            _tray.UpdateRecordingState(true);
            _ui.Post(_ =>
            {
                _overlay.SetRecording();
                _overlay.Show();
            }, null);
        }
        else
        {
            _recording = false;
            _audio.StopRecording();

            _ui.Post(_ => _overlay.SetTranscribing(), null);
            _tray.UpdateRecordingState(false);

            if (_currentWavPath is { } wavPath)
            {
                _currentWavPath = null;
                _processing = true;
                try   { await ProcessAsync(wavPath); }
                finally { _processing = false; }
            }

            _ui.Post(_ => _overlay.Hide(), null);
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
            var sttMs         = (int)(DateTimeOffset.UtcNow - sttStart).TotalMilliseconds;

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

            // Update tray with last-result stats
            _tray.UpdateLastResult(finalText, finalText.Length, sttMs, polishMs);

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
        _overlay.Dispose();
        DestroyHandle();
    }
}
