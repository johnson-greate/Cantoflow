using NAudio.Wave;

namespace CantoFlow.App;

/// <summary>
/// Records from the default microphone using NAudio WASAPI.
/// Mirrors macOS AudioCapture.swift.
/// </summary>
public class AudioCapture : IDisposable
{
    private WaveInEvent? _waveIn;
    private WaveFileWriter? _writer;
    private string? _outputPath;

    public bool IsRecording => _waveIn != null;

    public void StartRecording(string wavOutputPath)
    {
        _outputPath = wavOutputPath;
        _waveIn = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16000, 1) // 16kHz mono — whisper requirement
        };
        _writer = new WaveFileWriter(wavOutputPath, _waveIn.WaveFormat);
        _waveIn.DataAvailable += (_, e) => _writer.Write(e.Buffer, 0, e.BytesRecorded);
        _waveIn.StartRecording();
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
