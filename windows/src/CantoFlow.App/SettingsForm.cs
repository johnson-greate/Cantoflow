using CantoFlow.Core;

namespace CantoFlow.App;

public partial class SettingsForm : Form
{
    private readonly AppConfig _config;
    private readonly Dictionary<string, string> _fileValues;

    // Hotkey recorder
    private readonly TextBox _hotkeyBox  = new() { ReadOnly = true, BackColor = SystemColors.Window, Cursor = Cursors.Hand };
    private HotkeyConfig?    _pendingHotkey;

    // API key textboxes (plain text — user types new key or leaves blank to keep existing)
    private readonly TextBox _geminiKey    = new() { UseSystemPasswordChar = false };
    private readonly TextBox _dashscopeKey = new() { UseSystemPasswordChar = false };
    private readonly TextBox _qwenKey      = new() { UseSystemPasswordChar = false };
    private readonly TextBox _openaiKey    = new() { UseSystemPasswordChar = false };

    public SettingsForm(AppConfig config, Dictionary<string, string> fileValues)
    {
        _config     = config;
        _fileValues = fileValues;
        InitializeComponent();
        LoadValues();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string MaskKey(string key)
    {
        if (string.IsNullOrWhiteSpace(key)) return "";
        if (key.Length <= 8) return new string('*', key.Length);
        return key[..4] + new string('*', Math.Max(4, key.Length - 8)) + key[^4..];
    }

    private void LoadValues()
    {
        _hotkeyBox.Text = _config.Hotkey.Display;
        _hotkeyBox.GotFocus  += (_, _) => _hotkeyBox.Text = "Press a key combination...";
        _hotkeyBox.LostFocus += (_, _) => { if (_pendingHotkey == null) _hotkeyBox.Text = _config.Hotkey.Display; };
        _hotkeyBox.KeyDown   += (_, e) =>
        {
            e.SuppressKeyPress = true;
            var key = e.KeyData & Keys.KeyCode;
            // Ignore bare modifiers
            if (key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu || key == Keys.LWin || key == Keys.RWin)
                return;
            _pendingHotkey    = HotkeyConfig.FromKeyDown(e.KeyData);
            _hotkeyBox.Text   = _pendingHotkey.Display;
        };

        var fresh = EnvFileManager.LoadDefaults();
        _geminiKey.Text    = MaskKey(fresh.GetValueOrDefault("GEMINI_API_KEY",    ""));
        _dashscopeKey.Text = MaskKey(fresh.GetValueOrDefault("DASHSCOPE_API_KEY", ""));
        _qwenKey.Text      = MaskKey(fresh.GetValueOrDefault("QWEN_API_KEY",      ""));
        _openaiKey.Text    = MaskKey(fresh.GetValueOrDefault("OPENAI_API_KEY",    ""));

        // Clear placeholder on focus so user can type a new key
        void ClearOnFocus(TextBox tb, string envKey)
        {
            tb.Tag = fresh.GetValueOrDefault(envKey, ""); // store real value
            tb.GotFocus  += (_, _) => { if (tb.Text == MaskKey((string)tb.Tag!)) tb.Text = ""; };
            tb.LostFocus += (_, _) => { if (string.IsNullOrEmpty(tb.Text)) tb.Text = MaskKey((string)tb.Tag!); };
        }
        ClearOnFocus(_geminiKey,    "GEMINI_API_KEY");
        ClearOnFocus(_dashscopeKey, "DASHSCOPE_API_KEY");
        ClearOnFocus(_qwenKey,      "QWEN_API_KEY");
        ClearOnFocus(_openaiKey,    "OPENAI_API_KEY");
    }

    private void SaveValues()
    {
        if (_pendingHotkey != null)
            EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, "CANTOFLOW_HOTKEY", _pendingHotkey.Display);

        void SaveIfChanged(TextBox tb, string envKey)
        {
            var existing = (string)(tb.Tag ?? "");
            var entered  = tb.Text.Trim();
            // Only write if user typed something new (not the masked placeholder)
            if (!string.IsNullOrEmpty(entered) && entered != MaskKey(existing))
                EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, envKey, entered);
        }
        SaveIfChanged(_geminiKey,    "GEMINI_API_KEY");
        SaveIfChanged(_dashscopeKey, "DASHSCOPE_API_KEY");
        SaveIfChanged(_qwenKey,      "QWEN_API_KEY");
        SaveIfChanged(_openaiKey,    "OPENAI_API_KEY");

        MessageBox.Show("API keys saved.\nRestart CantoFlow to apply changes.",
            "CantoFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    // ── UI ────────────────────────────────────────────────────────────────────

    private void InitializeComponent()
    {
        Text            = "CantoFlow Settings";
        Size            = new Size(500, 380);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = false;

        var tabs = new TabControl { Dock = DockStyle.Fill };

        // ── General tab ──────────────────────────────────────────────────────
        var generalPage = new TabPage("General");
        var generalLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12), AutoSize = true
        };
        generalLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 40));
        generalLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 60));

        generalLayout.Controls.Add(new Label { Text = "Press-to-Talk Key", Anchor = AnchorStyles.Right, AutoSize = true });
        _hotkeyBox.Dock = DockStyle.Fill;
        generalLayout.Controls.Add(_hotkeyBox);

        generalLayout.Controls.Add(new Label { Text = "", AutoSize = true });
        generalLayout.Controls.Add(new Label
        {
            Text = "Click the box above, then press any key combination (e.g. Ctrl+Shift+Space, Alt+F8).",
            ForeColor = Color.Gray, Font = new Font(Font.FontFamily, 7.5f), AutoSize = true, MaximumSize = new Size(300, 0)
        });

        generalLayout.Controls.Add(new Label { Text = "Mode", Anchor = AnchorStyles.Right, AutoSize = true });
        generalLayout.Controls.Add(new Label { Text = "Toggle: press once to start, press again to stop", Anchor = AnchorStyles.Left, AutoSize = true });

        generalLayout.Controls.Add(new Label { Text = "Polish Style", Anchor = AnchorStyles.Right, AutoSize = true });
        generalLayout.Controls.Add(new Label { Text = _config.PolishStyle, Anchor = AnchorStyles.Left, AutoSize = true });

        generalLayout.Controls.Add(new Label { Text = "Vocabulary", Anchor = AnchorStyles.Right, AutoSize = true });
        generalLayout.Controls.Add(new Label { Text = "HK Starter Pack 1 + 2 loaded", Anchor = AnchorStyles.Left, AutoSize = true, ForeColor = Color.DarkGreen });

        generalPage.Controls.Add(generalLayout);

        // ── API Keys tab ─────────────────────────────────────────────────────
        var apiPage   = new TabPage("API Keys");
        var apiLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12)
        };
        apiLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        apiLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62));

        void AddRow(string label, TextBox field)
        {
            apiLayout.Controls.Add(new Label { Text = label, Anchor = AnchorStyles.Right, AutoSize = true });
            field.Dock = DockStyle.Fill;
            apiLayout.Controls.Add(field);
        }

        AddRow("Gemini API Key",    _geminiKey);
        AddRow("DashScope API Key", _dashscopeKey);
        AddRow("Qwen API Key",      _qwenKey);
        AddRow("OpenAI API Key",    _openaiKey);

        apiLayout.Controls.Add(new Label
        {
            Text = "Leave blank to keep existing key. Keys are saved to %APPDATA%\\CantoFlow\\cantoflow.env",
            ForeColor  = Color.Gray, Font = new Font(Font.FontFamily, 7.5f),
            AutoSize   = true, Anchor = AnchorStyles.Left,
            MaximumSize = new Size(320, 0)
        });
        apiLayout.Controls.Add(new Label());

        apiPage.Controls.Add(apiLayout);

        tabs.TabPages.Add(generalPage);
        tabs.TabPages.Add(apiPage);

        var saveBtn = new Button { Text = "Save & Close", Dock = DockStyle.Bottom, Height = 32 };
        saveBtn.Click += (_, _) => { SaveValues(); Close(); };

        Controls.Add(tabs);
        Controls.Add(saveBtn);
    }
}
