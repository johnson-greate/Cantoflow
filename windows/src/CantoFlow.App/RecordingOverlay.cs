using System.Drawing.Drawing2D;

namespace CantoFlow.App;

/// <summary>
/// Small always-on-top floating capsule shown during recording and transcription.
/// Mirrors the macOS menu-bar recording indicator with mic icon + status + volume bar.
/// Positioned bottom-right of the primary display (above taskbar).
/// </summary>
public sealed class RecordingOverlay : Form
{
    private readonly Label  _statusLabel;
    private readonly Panel  _levelBar;
    private readonly Panel  _levelFill;
    private float           _targetLevel;
    private readonly System.Windows.Forms.Timer _animTimer;

    private const int W = 230;
    private const int H = 60;
    private const int Radius = 14;

    public RecordingOverlay()
    {
        // ── Window chrome ──────────────────────────────────────────────────────
        FormBorderStyle = FormBorderStyle.None;
        TopMost         = true;
        ShowInTaskbar   = false;
        BackColor       = Color.FromArgb(28, 28, 28);
        Opacity         = 0.93;
        Size            = new Size(W, H);
        StartPosition   = FormStartPosition.Manual;

        // Rounded region
        var path = RoundedRect(new Rectangle(0, 0, W, H), Radius);
        Region = new Region(path);

        // Bottom-right of working area
        RepositionToScreen();

        // ── Mic icon + status text ─────────────────────────────────────────────
        _statusLabel = new Label
        {
            Text      = "🎙  Recording…",
            ForeColor = Color.White,
            BackColor = Color.Transparent,
            Font      = new Font("Segoe UI", 10f),
            AutoSize  = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds    = new Rectangle(0, 6, W, 26)
        };
        Controls.Add(_statusLabel);

        // ── Volume level bar ───────────────────────────────────────────────────
        _levelBar = new Panel
        {
            BackColor   = Color.FromArgb(65, 65, 65),
            Bounds      = new Rectangle(18, 38, W - 36, 10),
            BorderStyle = BorderStyle.None
        };
        Controls.Add(_levelBar);

        _levelFill = new Panel
        {
            BackColor = Color.FromArgb(48, 209, 88), // macOS green
            Bounds    = new Rectangle(0, 0, 0, 10)
        };
        _levelBar.Controls.Add(_levelFill);

        // Smooth animation at 40 fps
        _animTimer = new System.Windows.Forms.Timer { Interval = 25 };
        _animTimer.Tick += AnimateLevelBar;
        _animTimer.Start();
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    /// <summary>RMS level 0..1 from AudioCapture. Call from any thread.</summary>
    public void SetLevel(float level)
    {
        _targetLevel = Math.Clamp(level, 0f, 1f);
    }

    /// <summary>Switch label to "Transcribing…" and freeze level bar at 0.</summary>
    public void SetTranscribing()
    {
        if (InvokeRequired) { Invoke(SetTranscribing); return; }
        _statusLabel.Text = "⏳  Transcribing…";
        _targetLevel      = 0f;
    }

    /// <summary>Reset to recording state.</summary>
    public void SetRecording()
    {
        if (InvokeRequired) { Invoke(SetRecording); return; }
        _statusLabel.Text = "🎙  Recording…";
    }

    // ── Show / hide helpers ────────────────────────────────────────────────────

    public new void Show()
    {
        if (InvokeRequired) { Invoke(base.Show); return; }
        RepositionToScreen();
        base.Show();
    }

    public new void Hide()
    {
        if (InvokeRequired) { Invoke(base.Hide); return; }
        base.Hide();
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    private void RepositionToScreen()
    {
        var workArea = Screen.PrimaryScreen?.WorkingArea ?? Screen.AllScreens[0].WorkingArea;
        Location = new Point(workArea.Right - W - 20, workArea.Bottom - H - 20);
    }

    private void AnimateLevelBar(object? sender, EventArgs e)
    {
        var barWidth    = _levelBar.Width;
        var targetWidth = (int)(_targetLevel * barWidth);
        var current     = _levelFill.Width;
        // Ease toward target (attack fast, decay slower)
        var speed = targetWidth > current ? 0.5f : 0.25f;
        var next  = current + (int)Math.Ceiling((targetWidth - current) * speed);
        _levelFill.Width = Math.Clamp(next, 0, barWidth);
    }

    private static GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        int d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.Left,          r.Top,           d, d, 180, 90);
        path.AddArc(r.Right - d,     r.Top,           d, d, 270, 90);
        path.AddArc(r.Right - d,     r.Bottom - d,    d, d, 0,   90);
        path.AddArc(r.Left,          r.Bottom - d,    d, d, 90,  90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _animTimer.Dispose();
        base.Dispose(disposing);
    }
}
