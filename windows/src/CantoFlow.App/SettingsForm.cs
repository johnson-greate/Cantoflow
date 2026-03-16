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

    // Vocabulary tab controls
    private ListView         _vocabList   = null!;
    private ComboBox         _catFilter   = null!;
    private TextBox          _vocabSearch = null!;
    private Label            _vocabCount  = null!;
    private Button           _editBtn     = null!;
    private Button           _removeBtn   = null!;

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

    // ── Vocabulary helpers ────────────────────────────────────────────────────

    private void RefreshVocabList()
    {
        _vocabList.BeginUpdate();
        _vocabList.Items.Clear();

        var search   = _vocabSearch.Text.Trim().ToLowerInvariant();
        var catIndex = _catFilter.SelectedIndex; // 0=All, 1..7=categories
        VocabCategory? catFilter = catIndex > 0 ? (VocabCategory)(catIndex - 1) : null;

        foreach (var entry in VocabularyStore.Personal.Entries)
        {
            if (catFilter.HasValue && entry.Category != catFilter.Value) continue;
            if (!string.IsNullOrEmpty(search) &&
                !entry.Term.ToLowerInvariant().Contains(search) &&
                !entry.Category.DisplayName().ToLowerInvariant().Contains(search))
                continue;

            var item = new ListViewItem(entry.Term) { Tag = entry.Id };
            item.SubItems.Add(entry.Category.DisplayName());
            _vocabList.Items.Add(item);
        }

        _vocabList.EndUpdate();
        _vocabCount.Text = $"{VocabularyStore.Personal.Entries.Count} 個詞彙";
        UpdateSelectionButtons();
    }

    private void UpdateSelectionButtons()
    {
        var hasSelection = _vocabList.SelectedItems.Count > 0;
        _editBtn.Enabled   = hasSelection;
        _removeBtn.Enabled = hasSelection;
    }

    private void AddVocabEntry()
    {
        using var dlg = new TermEditDialog();
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        VocabularyStore.Personal.Add(new PersonalVocabEntry { Term = dlg.Term, Category = dlg.Category });
        RefreshVocabList();
    }

    private void EditSelectedEntry()
    {
        if (_vocabList.SelectedItems.Count == 0) return;
        var id    = (string)_vocabList.SelectedItems[0].Tag!;
        var entry = VocabularyStore.Personal.Entries.FirstOrDefault(e => e.Id == id);
        if (entry == null) return;

        using var dlg = new TermEditDialog(entry.Term, entry.Category);
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        VocabularyStore.Personal.Update(new PersonalVocabEntry { Id = id, Term = dlg.Term, Category = dlg.Category });
        RefreshVocabList();
    }

    private void RemoveSelectedEntry()
    {
        if (_vocabList.SelectedItems.Count == 0) return;
        var id   = (string)_vocabList.SelectedItems[0].Tag!;
        var term = _vocabList.SelectedItems[0].Text;
        if (MessageBox.Show($"移除詞彙「{term}」？", "CantoFlow",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
            return;
        VocabularyStore.Personal.Remove(id);
        RefreshVocabList();
    }

    // ── UI ────────────────────────────────────────────────────────────────────

    private void InitializeComponent()
    {
        Text            = "CantoFlow Settings";
        Size            = new Size(560, 480);
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

        generalPage.Controls.Add(generalLayout);

        // ── Vocabulary tab ────────────────────────────────────────────────────
        var vocabPage   = new TabPage("Vocabulary");
        var vocabLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Padding = new Padding(8)
        };
        vocabLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));  // filter bar
        vocabLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));  // list
        vocabLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));  // bottom bar

        // Filter bar: category combo + search box
        var filterBar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        _catFilter = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 100 };
        _catFilter.Items.Add("全部");
        foreach (VocabCategory cat in Enum.GetValues<VocabCategory>())
            _catFilter.Items.Add(cat.DisplayName());
        _catFilter.SelectedIndex = 0;
        _catFilter.SelectedIndexChanged += (_, _) => RefreshVocabList();

        _vocabSearch = new TextBox { Width = 160, PlaceholderText = "搜尋…" };
        _vocabSearch.TextChanged += (_, _) => RefreshVocabList();

        filterBar.Controls.Add(_catFilter);
        filterBar.Controls.Add(new Label { Text = " ", AutoSize = true });
        filterBar.Controls.Add(_vocabSearch);
        vocabLayout.Controls.Add(filterBar, 0, 0);

        // Vocabulary list
        _vocabList = new ListView
        {
            Dock        = DockStyle.Fill,
            View        = View.Details,
            FullRowSelect = true,
            GridLines   = true,
            MultiSelect = false
        };
        _vocabList.Columns.Add("詞彙", 280);
        _vocabList.Columns.Add("類別", 110);
        _vocabList.SelectedIndexChanged += (_, _) => UpdateSelectionButtons();
        _vocabList.DoubleClick          += (_, _) => EditSelectedEntry();
        vocabLayout.Controls.Add(_vocabList, 0, 1);

        // Bottom bar
        var bottomBar = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false, Padding = new Padding(0, 4, 0, 0)
        };

        var addBtn = new Button { Text = "+ 新增", AutoSize = true, Height = 26 };
        addBtn.Click += (_, _) => AddVocabEntry();

        _editBtn   = new Button { Text = "編輯", AutoSize = true, Height = 26, Enabled = false };
        _editBtn.Click += (_, _) => EditSelectedEntry();

        _removeBtn = new Button { Text = "- 移除", AutoSize = true, Height = 26, Enabled = false };
        _removeBtn.Click += (_, _) => RemoveSelectedEntry();

        _vocabCount = new Label { Text = "0 個詞彙", AutoSize = true, Padding = new Padding(6, 6, 0, 0) };

        var pack1Btn = new Button { Text = "入門詞庫 #1", AutoSize = true, Height = 26 };
        pack1Btn.Click += (_, _) =>
        {
            var n = VocabularyStore.ImportStarterPack1();
            MessageBox.Show(n > 0 ? $"已匯入 {n} 個詞彙（入門詞庫 #1）。" : "入門詞庫 #1 已全部匯入，無新詞。",
                "CantoFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            RefreshVocabList();
        };

        var pack2Btn = new Button { Text = "入門詞庫 #2", AutoSize = true, Height = 26 };
        pack2Btn.Click += (_, _) =>
        {
            var n = VocabularyStore.ImportStarterPack2();
            MessageBox.Show(n > 0 ? $"已匯入 {n} 個詞彙（入門詞庫 #2）。" : "入門詞庫 #2 已全部匯入，無新詞。",
                "CantoFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            RefreshVocabList();
        };

        bottomBar.Controls.AddRange([addBtn, _editBtn, _removeBtn, _vocabCount, pack1Btn, pack2Btn]);
        vocabLayout.Controls.Add(bottomBar, 0, 2);

        vocabPage.Controls.Add(vocabLayout);

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
        tabs.TabPages.Add(vocabPage);
        tabs.TabPages.Add(apiPage);

        // Refresh vocab when tab becomes visible
        tabs.SelectedIndexChanged += (_, _) =>
        {
            if (tabs.SelectedTab == vocabPage) RefreshVocabList();
        };

        var saveBtn = new Button { Text = "Save & Close", Dock = DockStyle.Bottom, Height = 32 };
        saveBtn.Click += (_, _) => { SaveValues(); Close(); };

        Controls.Add(tabs);
        Controls.Add(saveBtn);
    }
}

// ── Add/Edit term dialog ───────────────────────────────────────────────────────

internal class TermEditDialog : Form
{
    private readonly TextBox _termBox;
    private readonly ComboBox _catBox;

    public string       Term     => _termBox.Text.Trim();
    public VocabCategory Category => (VocabCategory)(_catBox.SelectedIndex);

    public TermEditDialog(string term = "", VocabCategory category = VocabCategory.Other)
    {
        Text            = string.IsNullOrEmpty(term) ? "新增詞彙" : "編輯詞彙";
        Size            = new Size(320, 160);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = false;
        MinimizeBox     = false;
        StartPosition   = FormStartPosition.CenterParent;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 2,
            Padding = new Padding(12), AutoSize = true
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        _termBox = new TextBox { Text = term, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label { Text = "詞彙", Anchor = AnchorStyles.Right, AutoSize = true });
        layout.Controls.Add(_termBox);

        _catBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
        foreach (VocabCategory cat in Enum.GetValues<VocabCategory>())
            _catBox.Items.Add(cat.DisplayName());
        _catBox.SelectedIndex = (int)category;
        layout.Controls.Add(new Label { Text = "類別", Anchor = AnchorStyles.Right, AutoSize = true });
        layout.Controls.Add(_catBox);

        var okBtn = new Button { Text = "確定", DialogResult = DialogResult.OK, Width = 80 };
        okBtn.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(Term))
            {
                MessageBox.Show("請輸入詞彙。", "CantoFlow", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                DialogResult = DialogResult.None;
            }
        };
        var cancelBtn = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Width = 80 };

        var btnPanel = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        btnPanel.Controls.AddRange([cancelBtn, okBtn]);
        layout.SetColumnSpan(btnPanel, 2);
        layout.Controls.Add(btnPanel);

        AcceptButton = okBtn;
        CancelButton = cancelBtn;
        Controls.Add(layout);
    }
}
