using CantoFlow.Core;

namespace CantoFlow.App;

public partial class SettingsForm : Form
{
    private readonly AppConfig _config;
    private readonly Dictionary<string, string> _fileValues;

    // API key fields
    private readonly TextBox _geminiKey  = new() { UseSystemPasswordChar = true };
    private readonly TextBox _dashscopeKey = new() { UseSystemPasswordChar = true };
    private readonly TextBox _qwenKey    = new() { UseSystemPasswordChar = true };
    private readonly TextBox _openaiKey  = new() { UseSystemPasswordChar = true };

    public SettingsForm(AppConfig config, Dictionary<string, string> fileValues)
    {
        _config = config;
        _fileValues = fileValues;
        InitializeComponent();
        LoadValues();
    }

    private void LoadValues()
    {
        _geminiKey.Text   = _fileValues.GetValueOrDefault("GEMINI_API_KEY", "");
        _dashscopeKey.Text = _fileValues.GetValueOrDefault("DASHSCOPE_API_KEY", "");
        _qwenKey.Text     = _fileValues.GetValueOrDefault("QWEN_API_KEY", "");
        _openaiKey.Text   = _fileValues.GetValueOrDefault("OPENAI_API_KEY", "");
    }

    private void SaveValues()
    {
        EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, "GEMINI_API_KEY",    _geminiKey.Text.Trim());
        EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, "DASHSCOPE_API_KEY", _dashscopeKey.Text.Trim());
        EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, "QWEN_API_KEY",      _qwenKey.Text.Trim());
        EnvFileManager.UpdateEnvFile(EnvFileManager.DefaultPath, "OPENAI_API_KEY",    _openaiKey.Text.Trim());
        MessageBox.Show("API keys saved. Restart CantoFlow to apply changes.",
            "CantoFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void InitializeComponent()
    {
        Text = "CantoFlow Settings";
        Size = new Size(480, 340);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 35));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 65));

        void AddRow(string label, TextBox field)
        {
            layout.Controls.Add(new Label { Text = label, Anchor = AnchorStyles.Right, AutoSize = true });
            field.Dock = DockStyle.Fill;
            layout.Controls.Add(field);
        }

        AddRow("Gemini API Key",    _geminiKey);
        AddRow("DashScope API Key", _dashscopeKey);
        AddRow("Qwen API Key",      _qwenKey);
        AddRow("OpenAI API Key",    _openaiKey);

        var saveBtn = new Button { Text = "Save & Close", Dock = DockStyle.Bottom };
        saveBtn.Click += (_, _) => { SaveValues(); Close(); };

        Controls.Add(layout);
        Controls.Add(saveBtn);
    }
}
