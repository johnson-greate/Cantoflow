using NAudio.Wave;

namespace CantoFlow.App;

/// <summary>
/// Records from the default microphone using NAudio WASAPI.
/// Mirrors macOS AudioCapture.swift.
/// Fires LevelChanged with RMS 0..1 so the recording overlay can show a level bar.
/// </summary>
public class AudioCapture : IDisposable
{
    private WaveInEvent?   _waveIn;
    private WaveFileWriter? _writer;
    private string?        _outputPath;

    public bool IsRecording => _waveIn != null;

    /// <summary>Fired ~16 times/sec with RMS amplitude 0..1 while recording.</summary>
    public event Action<float>? LevelChanged;

    public void StartRecording(string wavOutputPath)
    {
        _outputPath = wavOutputPath;
        _waveIn = new WaveInEvent
        {
            WaveFormat    = new WaveFormat(16000, 1), // 16kHz mono — whisper requirement
            BufferMilliseconds = 60
        };
        _writer = new WaveFileWriter(wavOutputPath, _waveIn.WaveFormat);
        _waveIn.DataAvailable += (_, e) =>
        {
            _writer.Write(e.Buffer, 0, e.BytesRecorded);
            LevelChanged?.Invoke(ComputeRms(e.Buffer, e.BytesRecorded));
        };
        _waveIn.StartRecording();
    }

    private static float ComputeRms(byte[] buffer, int count)
    {
        if (count < 2) return 0f;
        double sum = 0;
        int samples = count / 2;
        for (int i = 0; i < count - 1; i += 2)
        {
            short s = (short)(buffer[i] | (buffer[i + 1] << 8));
            sum += (double)s * s;
        }
        double rms = Math.Sqrt(sum / samples) / 32768.0;
        // Boost slightly and clamp — typical speech peaks ~0.05–0.3 raw
        return (float)Math.Min(rms * 4.0, 1.0);
    }

    public void StopRecording()
    {
        _waveIn?.StopRecording();
        _writer?.Flush();
        _writer?.Dispose();
        _writer = null;
        _waveIn?.Dispose();
        _waveIn = null;
    }

    public void Dispose()
    {
        StopRecording();
    }
}
