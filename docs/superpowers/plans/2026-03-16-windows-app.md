# CantoFlow Windows App Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows C# .NET 8 app with feature parity to the macOS CantoFlow app, plus an embedded HTTP transcription server for Android/iOS thin clients over Tailscale.

**Architecture:** Three projects in one solution. `CantoFlow.Core` holds all portable business logic (LLM polish, env file, telemetry). `CantoFlow.Server` is the ASP.NET HTTP server (portable). `CantoFlow.App` is the Windows-only tray app wiring everything together (Win32 hotkey, NAudio recording, SendInput paste). Core and Server are fully testable on macOS; App layer is scaffolded with stubs and must be built/run on Windows.

**Tech Stack:** C# 12 / .NET 8, xUnit, ASP.NET Core minimal API, NAudio (audio capture), Windows Forms (tray icon), Win32 P/Invoke (hotkey + paste)

**Spec:** `docs/superpowers/specs/2026-03-16-multiplatform-design.md`

---

## Chunk 1: Project Scaffold + CantoFlow.Core

### Task 1: Install .NET SDK and scaffold solution

**Files:**
- Create: `windows/CantoFlow.Windows.sln`
- Create: `windows/src/CantoFlow.Core/CantoFlow.Core.csproj`
- Create: `windows/src/CantoFlow.Server/CantoFlow.Server.csproj`
- Create: `windows/src/CantoFlow.App/CantoFlow.App.csproj`
- Create: `windows/tests/CantoFlow.Core.Tests/CantoFlow.Core.Tests.csproj`
- Create: `windows/tests/CantoFlow.Server.Tests/CantoFlow.Server.Tests.csproj`

- [ ] **Step 1: Install .NET 8 SDK**

```bash
brew install dotnet
export PATH="$PATH:/opt/homebrew/share/dotnet"
dotnet --version
```
Expected: `8.x.x`

- [ ] **Step 2: Scaffold solution and projects**

```bash
cd /Volumes/JTDev/CantoFlow/windows
dotnet new sln -n CantoFlow.Windows

# Core (portable class library)
dotnet new classlib -n CantoFlow.Core -o src/CantoFlow.Core --framework net8.0
dotnet sln add src/CantoFlow.Core/CantoFlow.Core.csproj

# Server (portable ASP.NET)
dotnet new web -n CantoFlow.Server -o src/CantoFlow.Server --framework net8.0
dotnet sln add src/CantoFlow.Server/CantoFlow.Server.csproj

# App (Windows-specific, scaffolded as console for now)
dotnet new console -n CantoFlow.App -o src/CantoFlow.App --framework net8.0-windows
dotnet sln add src/CantoFlow.App/CantoFlow.App.csproj

# Tests
dotnet new xunit -n CantoFlow.Core.Tests -o tests/CantoFlow.Core.Tests --framework net8.0
dotnet sln add tests/CantoFlow.Core.Tests/CantoFlow.Core.Tests.csproj
dotnet new xunit -n CantoFlow.Server.Tests -o tests/CantoFlow.Server.Tests --framework net8.0
dotnet sln add tests/CantoFlow.Server.Tests/CantoFlow.Server.Tests.csproj

# Add project references
dotnet add tests/CantoFlow.Core.Tests/CantoFlow.Core.Tests.csproj reference src/CantoFlow.Core/CantoFlow.Core.csproj
dotnet add tests/CantoFlow.Server.Tests/CantoFlow.Server.Tests.csproj reference src/CantoFlow.Server/CantoFlow.Server.csproj
dotnet add src/CantoFlow.Server/CantoFlow.Server.csproj reference src/CantoFlow.Core/CantoFlow.Core.csproj
dotnet add src/CantoFlow.App/CantoFlow.App.csproj reference src/CantoFlow.Core/CantoFlow.Core.csproj
dotnet add src/CantoFlow.App/CantoFlow.App.csproj reference src/CantoFlow.Server/CantoFlow.Server.csproj
```

- [ ] **Step 3: Add NuGet packages**

```bash
# Server test utilities
dotnet add tests/CantoFlow.Server.Tests/CantoFlow.Server.Tests.csproj package Microsoft.AspNetCore.Mvc.Testing
dotnet add tests/CantoFlow.Server.Tests/CantoFlow.Server.Tests.csproj package Microsoft.NET.Test.Sdk

# HTTP client for LLM polish
dotnet add src/CantoFlow.Core/CantoFlow.Core.csproj package Microsoft.Extensions.Http

# Delete generated boilerplate
rm -f src/CantoFlow.Core/Class1.cs
rm -f tests/CantoFlow.Core.Tests/UnitTest1.cs
rm -f tests/CantoFlow.Server.Tests/UnitTest1.cs
```

- [ ] **Step 4: Verify solution builds**

```bash
cd /Volumes/JTDev/CantoFlow/windows
dotnet build
```
Expected: `Build succeeded. 0 Error(s)`

- [ ] **Step 5: Commit scaffold**

```bash
git add windows/
git commit -m "feat(windows): scaffold C# solution structure (Core + Server + App)"
```

---

### Task 2: EnvFileManager (port of ~/.cantoflow.env logic)

**Files:**
- Create: `windows/src/CantoFlow.Core/EnvFileManager.cs`
- Create: `windows/tests/CantoFlow.Core.Tests/EnvFileManagerTests.cs`

- [ ] **Step 1: Write failing tests**

```csharp
// windows/tests/CantoFlow.Core.Tests/EnvFileManagerTests.cs
using Xunit;
using CantoFlow.Core;

namespace CantoFlow.Core.Tests;

public class EnvFileManagerTests
{
    [Fact]
    public void ParseEnvFile_QuotedValues_ReturnsUnquotedValues()
    {
        var content = """
            # comment
            QWEN_API_KEY="sk-abc123"
            OPENAI_API_KEY=''
            DASHSCOPE_API_KEY=
            """;
        var result = EnvFileManager.ParseEnvFile(content);
        Assert.Equal("sk-abc123", result["QWEN_API_KEY"]);
        Assert.Equal("", result["OPENAI_API_KEY"]);
        Assert.Equal("", result["DASHSCOPE_API_KEY"]);
        Assert.False(result.ContainsKey("# comment"));
    }

    [Fact]
    public void ResolveApiKey_EnvVarTakesPrecedence()
    {
        // Env var should beat env file value
        var envVars = new Dictionary<string, string> { ["QWEN_API_KEY"] = "from-env" };
        var fileValues = new Dictionary<string, string> { ["QWEN_API_KEY"] = "from-file" };
        var result = EnvFileManager.ResolveApiKey(
            envVarNames: ["QWEN_API_KEY"],
            fileKeys: ["QWEN_API_KEY"],
            envVars: envVars,
            fileValues: fileValues);
        Assert.Equal("from-env", result);
    }

    [Fact]
    public void ResolveApiKey_FallsBackToFile_WhenEnvVarMissing()
    {
        var envVars = new Dictionary<string, string>();
        var fileValues = new Dictionary<string, string> { ["QWEN_API_KEY"] = "sk-from-file" };
        var result = EnvFileManager.ResolveApiKey(
            envVarNames: ["QWEN_API_KEY"],
            fileKeys: ["QWEN_API_KEY"],
            envVars: envVars,
            fileValues: fileValues);
        Assert.Equal("sk-from-file", result);
    }

    [Fact]
    public void ResolveApiKey_ReturnsNull_WhenBothMissing()
    {
        var result = EnvFileManager.ResolveApiKey(
            envVarNames: ["MISSING_KEY"],
            fileKeys: ["MISSING_KEY"],
            envVars: [],
            fileValues: []);
        Assert.Null(result);
    }

    [Fact]
    public void UpdateEnvFile_WritesKeyAndPreservesOthers()
    {
        var tmpFile = Path.GetTempFileName();
        File.WriteAllText(tmpFile, "# CantoFlow\nQWEN_API_KEY=\"old\"\nOPENAI_API_KEY=\"keep\"\n");
        EnvFileManager.UpdateEnvFile(tmpFile, "QWEN_API_KEY", "new-value");
        var result = EnvFileManager.ParseEnvFile(File.ReadAllText(tmpFile));
        Assert.Equal("new-value", result["QWEN_API_KEY"]);
        Assert.Equal("keep", result["OPENAI_API_KEY"]);
        File.Delete(tmpFile);
    }

    [Fact]
    public void UpdateEnvFile_AppendsKey_WhenNotPresent()
    {
        var tmpFile = Path.GetTempFileName();
        File.WriteAllText(tmpFile, "# CantoFlow\n");
        EnvFileManager.UpdateEnvFile(tmpFile, "GEMINI_API_KEY", "gemini-key");
        var result = EnvFileManager.ParseEnvFile(File.ReadAllText(tmpFile));
        Assert.Equal("gemini-key", result["GEMINI_API_KEY"]);
        File.Delete(tmpFile);
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Volumes/JTDev/CantoFlow/windows
dotnet test tests/CantoFlow.Core.Tests/ --filter "EnvFileManager"
```
Expected: compilation error (type not found)

- [ ] **Step 3: Implement EnvFileManager**

```csharp
// windows/src/CantoFlow.Core/EnvFileManager.cs
namespace CantoFlow.Core;

public static class EnvFileManager
{
    public static readonly string DefaultPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CantoFlow", "cantoflow.env");

    private static readonly string DefaultTemplate =
        "# CantoFlow API 密鑰設定\n" +
        "GEMINI_API_KEY=\"\"\n" +
        "DASHSCOPE_API_KEY=\"\"\n" +
        "QWEN_API_KEY=\"\"\n" +
        "OPENAI_API_KEY=\"\"\n" +
        "ANTHROPIC_API_KEY=\"\"\n";

    /// <summary>
    /// Parse KEY="value" / KEY=value env file format.
    /// Skips blank lines and comments.
    /// </summary>
    public static Dictionary<string, string> ParseEnvFile(string content)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in content.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith('#')) continue;
            var eqIdx = trimmed.IndexOf('=');
            if (eqIdx < 0) continue;
            var key = trimmed[..eqIdx].Trim();
            var val = trimmed[(eqIdx + 1)..].Trim();
            if (val.Length >= 2 &&
                ((val[0] == '"' && val[^1] == '"') || (val[0] == '\'' && val[^1] == '\'')))
            {
                val = val[1..^1];
            }
            result[key] = val;
        }
        return result;
    }

    /// <summary>
    /// Resolve an API key: check env vars first, then file values. Returns null if not found.
    /// </summary>
    public static string? ResolveApiKey(
        IEnumerable<string> envVarNames,
        IEnumerable<string> fileKeys,
        IReadOnlyDictionary<string, string>? envVars = null,
        IReadOnlyDictionary<string, string>? fileValues = null)
    {
        var env = envVars ?? Environment.GetEnvironmentVariables()
            .Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString() ?? "");

        foreach (var name in envVarNames)
        {
            if (env.TryGetValue(name, out var v) && !string.IsNullOrWhiteSpace(v))
                return v.Trim();
        }

        if (fileValues != null)
        {
            foreach (var key in fileKeys)
            {
                if (fileValues.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v))
                    return v.Trim();
            }
        }
        return null;
    }

    /// <summary>
    /// Write a single key into the env file, preserving all other lines.
    /// Creates the file with a default template if it does not exist.
    /// </summary>
    public static void UpdateEnvFile(string path, string envVar, string value)
    {
        if (!File.Exists(path))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, DefaultTemplate);
        }

        var lines = File.ReadAllLines(path).ToList();
        var newLine = $"{envVar}=\"{value}\"";
        var found = false;
        for (var i = 0; i < lines.Count; i++)
        {
            if (lines[i].TrimStart().StartsWith(envVar + "="))
            {
                lines[i] = newLine;
                found = true;
                break;
            }
        }
        if (!found) lines.Add(newLine);
        File.WriteAllText(path, string.Join("\n", lines) + "\n");
    }

    /// <summary>Load env file from default path, creating it with template if absent.</summary>
    public static Dictionary<string, string> LoadDefaults()
    {
        if (!File.Exists(DefaultPath))
            UpdateEnvFile(DefaultPath, "GEMINI_API_KEY", "");
        return ParseEnvFile(File.ReadAllText(DefaultPath));
    }
}
```

- [ ] **Step 4: Run tests**

```bash
dotnet test tests/CantoFlow.Core.Tests/ --filter "EnvFileManager" -v normal
```
Expected: `5 passed`

- [ ] **Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows/core): EnvFileManager with env-var-first key resolution"
```

---

### Task 3: TextPolisher (port from Swift TextPolisher.swift)

**Files:**
- Create: `windows/src/CantoFlow.Core/TextPolisher.cs`
- Create: `windows/src/CantoFlow.Core/PolishProvider.cs`
- Create: `windows/tests/CantoFlow.Core.Tests/TextPolisherTests.cs`

- [ ] **Step 1: Write failing tests**

```csharp
// windows/tests/CantoFlow.Core.Tests/TextPolisherTests.cs
using Xunit;
using CantoFlow.Core;

namespace CantoFlow.Core.Tests;

public class TextPolisherTests
{
    [Fact]
    public void ResolveProvider_ReturnsNone_WhenNoKeysPresent()
    {
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: []);
        Assert.Equal(PolishProvider.None, polisher.ResolveProvider());
    }

    [Fact]
    public void ResolveProvider_PrefersGemini_InAutoMode()
    {
        var fileValues = new Dictionary<string, string>
        {
            ["GEMINI_API_KEY"] = "gemini-key",
            ["QWEN_API_KEY"] = "qwen-key"
        };
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: fileValues);
        Assert.Equal(PolishProvider.Gemini, polisher.ResolveProvider());
    }

    [Fact]
    public void ResolveProvider_FallsBackToQwen_WhenGeminiMissing()
    {
        var fileValues = new Dictionary<string, string> { ["QWEN_API_KEY"] = "sk-qwen" };
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: fileValues);
        Assert.Equal(PolishProvider.Qwen, polisher.ResolveProvider());
    }

    [Fact]
    public void ResolveProvider_ReturnsNone_WhenProviderExplicitButNoKey()
    {
        var polisher = new TextPolisher(PolishProvider.Qwen, fileValues: []);
        Assert.Equal(PolishProvider.None, polisher.ResolveProvider());
    }

    [Fact]
    public void IsAvailable_ReturnsFalse_WhenNoKeys()
    {
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: []);
        Assert.False(polisher.IsAvailable());
    }

    [Fact]
    public void IsAvailable_ReturnsTrue_WhenKeyPresent()
    {
        var fileValues = new Dictionary<string, string> { ["OPENAI_API_KEY"] = "sk-test" };
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: fileValues);
        Assert.True(polisher.IsAvailable());
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
dotnet test tests/CantoFlow.Core.Tests/ --filter "TextPolisher"
```
Expected: compilation error

- [ ] **Step 3: Implement PolishProvider enum**

```csharp
// windows/src/CantoFlow.Core/PolishProvider.cs
namespace CantoFlow.Core;

public enum PolishProvider { Auto, Gemini, Qwen, OpenAI, Anthropic, None }
```

- [ ] **Step 4: Implement TextPolisher**

```csharp
// windows/src/CantoFlow.Core/TextPolisher.cs
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace CantoFlow.Core;

public class TextPolisher
{
    private readonly PolishProvider _configuredProvider;
    private readonly IReadOnlyDictionary<string, string> _fileValues;
    private static readonly HttpClient Http = new();

    public TextPolisher(PolishProvider provider, IReadOnlyDictionary<string, string>? fileValues = null)
    {
        _configuredProvider = provider;
        _fileValues = fileValues ?? EnvFileManager.LoadDefaults();
    }

    public bool IsAvailable() => ResolveProvider() != PolishProvider.None;

    /// <summary>
    /// Resolve which provider to use. Priority (auto): Gemini > Qwen > OpenAI > Anthropic.
    /// Mirrors TextPolisher.swift resolveProvider().
    /// </summary>
    public PolishProvider ResolveProvider() => _configuredProvider switch
    {
        PolishProvider.Gemini    => ResolveKey("GEMINI_API_KEY") != null ? PolishProvider.Gemini : PolishProvider.None,
        PolishProvider.Qwen      => ResolveQwenKey() != null ? PolishProvider.Qwen : PolishProvider.None,
        PolishProvider.OpenAI    => ResolveKey("OPENAI_API_KEY") != null ? PolishProvider.OpenAI : PolishProvider.None,
        PolishProvider.Anthropic => ResolveKey("ANTHROPIC_API_KEY") != null ? PolishProvider.Anthropic : PolishProvider.None,
        PolishProvider.None      => PolishProvider.None,
        _ /* Auto */             => ResolveAuto()
    };

    private PolishProvider ResolveAuto()
    {
        if (ResolveKey("GEMINI_API_KEY") != null) return PolishProvider.Gemini;
        if (ResolveQwenKey() != null) return PolishProvider.Qwen;
        if (ResolveKey("OPENAI_API_KEY") != null) return PolishProvider.OpenAI;
        if (ResolveKey("ANTHROPIC_API_KEY") != null) return PolishProvider.Anthropic;
        return PolishProvider.None;
    }

    private string? ResolveKey(string envVar) =>
        EnvFileManager.ResolveApiKey([envVar], [envVar], fileValues: _fileValues);

    private string? ResolveQwenKey() =>
        EnvFileManager.ResolveApiKey(
            ["DASHSCOPE_API_KEY", "QWEN_API_KEY"],
            ["dashscopeAPIKey", "qwenAPIKey"],
            fileValues: _fileValues);

    public async Task<PolishResult> PolishAsync(string rawText, string polishStyle = "cantonese",
        string? vocabularySection = null, CancellationToken ct = default)
    {
        var provider = ResolveProvider();
        if (provider == PolishProvider.None)
            throw new InvalidOperationException("No API key available.");

        var systemPrompt = PromptBuilder.BuildSystemPrompt(polishStyle, vocabularySection);
        var userPrompt = PromptBuilder.BuildUserPrompt(rawText, polishStyle);
        var start = DateTimeOffset.UtcNow;

        var polished = provider switch
        {
            PolishProvider.Gemini    => await CallGeminiAsync(systemPrompt, userPrompt, ct),
            PolishProvider.Qwen      => await CallQwenAsync(systemPrompt, userPrompt, ct),
            PolishProvider.OpenAI    => await CallOpenAIAsync(systemPrompt, userPrompt, ct),
            PolishProvider.Anthropic => await CallAnthropicAsync(systemPrompt, userPrompt, ct),
            _ => throw new InvalidOperationException("Unexpected provider state.")
        };

        return new PolishResult(polished, provider,
            (int)(DateTimeOffset.UtcNow - start).TotalMilliseconds);
    }

    private async Task<string> CallQwenAsync(string system, string user, CancellationToken ct)
    {
        var apiKey = ResolveQwenKey()!;
        var model = Environment.GetEnvironmentVariable("QWEN_MODEL") ?? "qwen3.5-plus";
        var body = JsonSerializer.Serialize(new
        {
            model,
            temperature = 0.2,
            max_tokens = 1024,
            enable_thinking = false,
            messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user",   content = user }
            }
        });
        var req = new HttpRequestMessage(HttpMethod.Post,
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        var resp = await Http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        return ParseOpenAICompatibleResponse(await resp.Content.ReadAsStringAsync(ct));
    }

    private async Task<string> CallOpenAIAsync(string system, string user, CancellationToken ct)
    {
        var apiKey = ResolveKey("OPENAI_API_KEY")!;
        var model = Environment.GetEnvironmentVariable("OPENAI_MODEL") ?? "gpt-4o-mini";
        var body = JsonSerializer.Serialize(new
        {
            model,
            temperature = 0.2,
            max_completion_tokens = 1024,
            messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user",   content = user }
            }
        });
        var req = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/chat/completions");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        var resp = await Http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        return ParseOpenAICompatibleResponse(await resp.Content.ReadAsStringAsync(ct));
    }

    private async Task<string> CallGeminiAsync(string system, string user, CancellationToken ct)
    {
        var apiKey = ResolveKey("GEMINI_API_KEY")!;
        var model = Environment.GetEnvironmentVariable("GEMINI_MODEL") ?? "gemini-2.5-flash";
        var body = JsonSerializer.Serialize(new
        {
            system_instruction = new { parts = new[] { new { text = system } } },
            contents = new[] { new { role = "user", parts = new[] { new { text = user } } } },
            generationConfig = new { temperature = 0.2, maxOutputTokens = 1024 }
        });
        var url = $"https://generativelanguage.googleapis.com/v1beta/models/{Uri.EscapeDataString(model)}:generateContent";
        var req = new HttpRequestMessage(HttpMethod.Post, url);
        req.Headers.Add("x-goog-api-key", apiKey);
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        var resp = await Http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        return doc.RootElement
            .GetProperty("candidates")[0]
            .GetProperty("content")
            .GetProperty("parts")[0]
            .GetProperty("text")
            .GetString()?.Trim() ?? throw new InvalidOperationException("Empty Gemini response");
    }

    private async Task<string> CallAnthropicAsync(string system, string user, CancellationToken ct)
    {
        var apiKey = ResolveKey("ANTHROPIC_API_KEY")!;
        var model = Environment.GetEnvironmentVariable("ANTHROPIC_MODEL") ?? "claude-sonnet-4-6";
        var body = JsonSerializer.Serialize(new
        {
            model,
            max_tokens = 1024,
            temperature = 0.2,
            system,
            messages = new[] { new { role = "user", content = new[] { new { type = "text", text = user } } } }
        });
        var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2023-06-01");
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        var resp = await Http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        foreach (var item in doc.RootElement.GetProperty("content").EnumerateArray())
            if (item.GetProperty("type").GetString() == "text")
                return item.GetProperty("text").GetString()?.Trim()
                    ?? throw new InvalidOperationException("Empty Anthropic response");
        throw new InvalidOperationException("No text content in Anthropic response");
    }

    private static string ParseOpenAICompatibleResponse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement
            .GetProperty("choices")[0]
            .GetProperty("message")
            .GetProperty("content")
            .GetString()?.Trim()
            ?? throw new InvalidOperationException("Empty response from API");
    }
}

public record PolishResult(string Text, PolishProvider Provider, int DurationMs);
```

- [ ] **Step 5: Add PromptBuilder (port of PolishStyle.systemPrompt from Swift)**

```csharp
// windows/src/CantoFlow.Core/PromptBuilder.cs
namespace CantoFlow.Core;

public static class PromptBuilder
{
    public static string BuildSystemPrompt(string style, string? vocabularySection)
    {
        var prompt = style == "formal" ? FormalPrompt : CantonesePrompt;
        if (!string.IsNullOrWhiteSpace(vocabularySection))
            prompt += "\n" + vocabularySection;
        return prompt;
    }

    public static string BuildUserPrompt(string rawText, string style) => style == "formal"
        ? rawText
        : $"以下是 Whisper 轉錄粗稿。請按「香港廣東話口語模式」做最小必要修正，並優先跟從詞庫用字。\n\n粗稿：\n{rawText}";

    private const string CantonesePrompt = """
        你是一位精通香港廣東話口語的資深編輯。你的工作是把 Whisper 語音轉錄粗稿輕度修正，整理成地道、自然、貼近香港人日常打字的廣東話文字。

        請嚴格遵守以下規則：
        1. 保持原意，不要擴寫，不要總結，不要自行補充資訊。
        2. 這是「廣東話口語模式」，必須優先保留口語說法，不可擅自改成正式書面語。
        3. 只修正明顯的語音識別錯字、同音字、近音字、英文音譯拼音，以及不自然的斷句與標點。
        4. 必須輸出繁體中文；若輸入出現簡體字，請轉為繁體字。
        5. 只輸出整理後文字，不要加引號、不要解釋、不要列點、不要輸出「修正後：」。
        """;

    private const string FormalPrompt = """
        你是一位精通中國大陸標準書面語的資深編輯。請將用戶輸入的語音識別粗文字潤飾為嚴謹、規範的正式書面語。
        1. 保持用戶原意，不要過度改寫
        2. 修正語音識別錯字（按上下文）
        3. 去除語氣詞、口頭禪及方言用詞，改為標準書面語表達
        4. 整理句式及標點
        5. 只輸出整理後文字，不要解釋
        6. 必須以繁體中文輸出，將所有簡體字轉換為繁體字
        """;
}
```

- [ ] **Step 6: Run all Core tests**

```bash
dotnet test tests/CantoFlow.Core.Tests/ -v normal
```
Expected: `6 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
git add windows/
git commit -m "feat(windows/core): TextPolisher + PromptBuilder (port from Swift)"
```

---

### Task 4: TelemetryLogger (port from Swift TelemetryLogger.swift)

**Files:**
- Create: `windows/src/CantoFlow.Core/TelemetryLogger.cs`
- Create: `windows/tests/CantoFlow.Core.Tests/TelemetryLoggerTests.cs`

- [ ] **Step 1: Write failing tests**

```csharp
// windows/tests/CantoFlow.Core.Tests/TelemetryLoggerTests.cs
using Xunit;
using CantoFlow.Core;

namespace CantoFlow.Core.Tests;

public class TelemetryLoggerTests
{
    [Fact]
    public void Log_WritesValidJsonEntryToFile()
    {
        var tmpFile = Path.GetTempFileName();
        var logger = new TelemetryLogger(tmpFile);
        var entry = new TelemetryEntry
        {
            Timestamp = "2026-03-16T05:00:00Z",
            Provider = "qwen",
            PolishStatus = "ok",
            RawText = "raw",
            FinalText = "polished",
            LatencyMs = new LatencyMs { Stt = 3000, Polish = 1500, Record = 5000 }
        };
        logger.Log(entry);
        var lines = File.ReadAllLines(tmpFile).Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
        Assert.Single(lines);
        var parsed = System.Text.Json.JsonSerializer.Deserialize<TelemetryEntry>(lines[0]);
        Assert.NotNull(parsed);
        Assert.Equal("qwen", parsed.Provider);
        Assert.Equal("polished", parsed.FinalText);
        File.Delete(tmpFile);
    }
}
```

- [ ] **Step 2: Implement TelemetryLogger**

```csharp
// windows/src/CantoFlow.Core/TelemetryLogger.cs
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CantoFlow.Core;

public class TelemetryLogger(string filePath)
{
    private readonly object _lock = new();
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public void Log(TelemetryEntry entry)
    {
        var json = JsonSerializer.Serialize(entry, JsonOpts);
        lock (_lock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
            File.AppendAllText(filePath, json + "\n\n"); // double newline matches macOS format
        }
    }

    public static string IsoTimestamp() =>
        DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

    public static string FileTimestamp() =>
        DateTimeOffset.UtcNow.ToString("yyyyMMdd_HHmmss");
}

public class TelemetryEntry
{
    public string Timestamp { get; set; } = "";
    public string Provider { get; set; } = "none";
    public string PolishStatus { get; set; } = "not_run";
    public string RawText { get; set; } = "";
    public string FinalText { get; set; } = "";
    public string SttProfile { get; set; } = "fast";
    public LatencyMs LatencyMs { get; set; } = new();
}

public class LatencyMs
{
    public int Record { get; set; }
    public int Stt { get; set; }
    public int Polish { get; set; }
    public int Total => Record + Stt + Polish;
}
```

- [ ] **Step 3: Run tests**

```bash
dotnet test tests/CantoFlow.Core.Tests/ -v normal
```
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add windows/
git commit -m "feat(windows/core): TelemetryLogger (double-newline JSONL, matches macOS format)"
```

---

## Chunk 2: CantoFlow.Server (HTTP Transcription Server)

### Task 5: TranscribeEndpoint — `/health` and `/transcribe`

**Files:**
- Create: `windows/src/CantoFlow.Server/TranscriptionServer.cs`
- Create: `windows/src/CantoFlow.Server/Program.cs` (replace generated)
- Create: `windows/tests/CantoFlow.Server.Tests/TranscribeEndpointTests.cs`

- [ ] **Step 1: Write failing integration tests**

```csharp
// windows/tests/CantoFlow.Server.Tests/TranscribeEndpointTests.cs
using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using System.Net.Http.Headers;
using Xunit;

namespace CantoFlow.Server.Tests;

public class TranscribeEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public TranscribeEndpointTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Health_Returns200WithStatus()
    {
        var resp = await _client.GetAsync("/health");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("\"status\"", body);
        Assert.Contains("ok", body);
    }

    [Fact]
    public async Task Transcribe_NoFile_Returns400()
    {
        var content = new MultipartFormDataContent();
        var resp = await _client.PostAsync("/transcribe", content);
        Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
    }

    [Fact]
    public async Task Transcribe_InvalidFile_Returns400()
    {
        var content = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent([0x00, 0x01, 0x02]); // not a valid WAV
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(fileContent, "audio", "test.wav");
        var resp = await _client.PostAsync("/transcribe", content);
        // Server should reject non-WAV or return error, not 500
        Assert.True((int)resp.StatusCode < 500, $"Expected <500, got {resp.StatusCode}");
    }
}
```

- [ ] **Step 2: Implement TranscriptionServer**

```csharp
// windows/src/CantoFlow.Server/TranscriptionServer.cs
using CantoFlow.Core;

namespace CantoFlow.Server;

public class TranscriptionServer
{
    private readonly TextPolisher _polisher;
    private readonly TelemetryLogger _telemetry;
    private readonly SemaphoreSlim _semaphore = new(1, 1); // one job at a time
    private readonly string _version;
    private readonly string _outDir;

    public TranscriptionServer(TextPolisher polisher, TelemetryLogger telemetry,
        string version, string outDir)
    {
        _polisher = polisher;
        _telemetry = telemetry;
        _version = version;
        _outDir = outDir;
        Directory.CreateDirectory(outDir);
    }

    public object GetHealth() => new
    {
        status = "ok",
        version = _version,
        polish_available = _polisher.IsAvailable()
    };

    public async Task<(int statusCode, object body)> TranscribeAsync(
        Stream audioStream, string fileName, CancellationToken ct)
    {
        // Validate WAV header (RIFF magic bytes)
        var header = new byte[4];
        var bytesRead = await audioStream.ReadAsync(header.AsMemory(0, 4), ct);
        if (bytesRead < 4 || header[0] != 'R' || header[1] != 'I' || header[2] != 'F' || header[3] != 'F')
            return (400, new { error = "invalid_audio", message = "Expected WAV file with RIFF header" });

        // Reset stream and save to temp file
        audioStream.Seek(0, SeekOrigin.Begin);
        var stamp = TelemetryLogger.FileTimestamp();
        var wavPath = Path.Combine(_outDir, $"mobile_{stamp}.wav");
        await using (var fs = File.Create(wavPath))
            await audioStream.CopyToAsync(fs, ct);

        // Acquire transcription slot — reject if busy
        if (!await _semaphore.WaitAsync(0, ct))
            return (503, new { error = "server_busy" });

        try
        {
            // TODO(windows-only): Run whisper.cpp CLI and get rawText
            // For now, return a stub so the server layer can be tested end-to-end
            var rawText = $"[whisper stub: {Path.GetFileName(wavPath)}]";
            var finalText = rawText;
            var polishStatus = "not_run";
            var polishMs = 0;
            var provider = "none";

            if (_polisher.IsAvailable())
            {
                try
                {
                    var result = await _polisher.PolishAsync(rawText, ct: ct);
                    finalText = result.Text;
                    polishMs = result.DurationMs;
                    provider = result.Provider.ToString().ToLower();
                    polishStatus = "ok";
                }
                catch (Exception ex)
                {
                    polishStatus = $"failed: {ex.Message}";
                }
            }

            _telemetry.Log(new TelemetryEntry
            {
                Timestamp = TelemetryLogger.IsoTimestamp(),
                Provider = provider,
                PolishStatus = polishStatus,
                RawText = rawText,
                FinalText = finalText,
                LatencyMs = new LatencyMs { Polish = polishMs }
            });

            return (200, new
            {
                text = finalText,
                raw = rawText,
                provider,
                polish_ms = polishMs,
                stt_ms = 0 // filled in when whisper stub is replaced
            });
        }
        finally
        {
            _semaphore.Release();
        }
    }
}
```

- [ ] **Step 3: Wire up Program.cs**

```csharp
// windows/src/CantoFlow.Server/Program.cs
using CantoFlow.Core;
using CantoFlow.Server;

var version = typeof(Program).Assembly
    .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
    .Cast<System.Reflection.AssemblyInformationalVersionAttribute>()
    .FirstOrDefault()?.InformationalVersion ?? "dev";

var outDir = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
    "CantoFlow", ".out");

var fileValues = EnvFileManager.LoadDefaults();
var polisher = new TextPolisher(PolishProvider.Auto, fileValues);
var logger = new TelemetryLogger(Path.Combine(outDir, "telemetry.jsonl"));
var server = new TranscriptionServer(polisher, logger, version, outDir);

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(server.GetHealth()));

app.MapPost("/transcribe", async (HttpRequest request, CancellationToken ct) =>
{
    if (!request.HasFormContentType)
        return Results.BadRequest(new { error = "invalid_content_type" });

    var form = await request.ReadFormAsync(ct);
    var file = form.Files.GetFile("audio");
    if (file == null)
        return Results.BadRequest(new { error = "missing_audio_file" });

    await using var stream = file.OpenReadStream();
    var (statusCode, body) = await server.TranscribeAsync(stream, file.FileName, ct);
    return statusCode == 200 ? Results.Ok(body)
         : statusCode == 503 ? Results.StatusCode(503)
         : Results.BadRequest(body);
});

// Make Program visible to test project
public partial class Program { }
```

- [ ] **Step 4: Run server tests**

```bash
dotnet test tests/CantoFlow.Server.Tests/ -v normal
```
Expected: `3 passed`

- [ ] **Step 5: Commit**

```bash
git add windows/
git commit -m "feat(windows/server): ASP.NET transcription server with /health and /transcribe"
```

---

## Chunk 3: CantoFlow.App — Windows Tray App Scaffold

> **Note:** This chunk scaffolds the Windows-specific layer. The code compiles as `net8.0-windows` but cannot be run on macOS. Final testing must be done on a Windows machine.

### Task 6: Windows App skeleton (tray icon + hotkey + audio stubs)

**Files:**
- Create: `windows/src/CantoFlow.App/Program.cs`
- Create: `windows/src/CantoFlow.App/TrayIconController.cs`
- Create: `windows/src/CantoFlow.App/HotkeyManager.cs`
- Create: `windows/src/CantoFlow.App/AudioCapture.cs`
- Create: `windows/src/CantoFlow.App/WhisperRunner.cs`
- Create: `windows/src/CantoFlow.App/TextInserter.cs`
- Create: `windows/src/CantoFlow.App/AppConfig.cs`
- Create: `windows/src/CantoFlow.App/SettingsForm.cs`
- Create: `windows/src/CantoFlow.App/BuildVersion.cs`

- [ ] **Step 1: Update CantoFlow.App.csproj for Windows Forms + server hosting**

```xml
<!-- windows/src/CantoFlow.App/CantoFlow.App.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <ApplicationIcon>Resources\icon.ico</ApplicationIcon>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="NAudio" Version="2.2.1" />
    <PackageReference Include="Microsoft.AspNetCore.App" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\CantoFlow.Core\CantoFlow.Core.csproj" />
    <ProjectReference Include="..\CantoFlow.Server\CantoFlow.Server.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: Implement AppConfig**

```csharp
// windows/src/CantoFlow.App/AppConfig.cs
using CantoFlow.Core;

namespace CantoFlow.App;

public class AppConfig
{
    // Defaults mirror macOS AppConfig.swift
    public bool FastIME { get; set; } = true;
    public bool AutoPaste { get; set; } = true;
    public bool AutoReplace { get; set; } = false; // conservative default (same as macOS)
    public PolishProvider PolishProvider { get; set; } = PolishProvider.Auto;
    public string PolishStyle { get; set; } = "cantonese";
    public bool ServerEnabled { get; set; } = true;
    public int ServerPort { get; set; } = 8765;
    public string HotkeyDescription { get; set; } = "F15";

    public string OutDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", ".out");
    public string WhisperCli => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", "whisper", "whisper-cli.exe");
    public string WhisperModel => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CantoFlow", "whisper", "models", "ggml-large-v3-turbo.bin");
}
```

- [ ] **Step 3: Implement BuildVersion**

```csharp
// windows/src/CantoFlow.App/BuildVersion.cs
namespace CantoFlow.App;

/// <summary>
/// Build timestamp embedded at compile time via MSBuild.
/// Format matches macOS AppVersion.swift: yyyyMMdd.HHmm
/// </summary>
public static class BuildVersion
{
    // This constant is rewritten by the pre-build script (see Directory.Build.targets)
    public const string Version = "00000000.0000";
}
```

- [ ] **Step 4: Implement TextInserter (Windows terminal detection + SendInput)**

```csharp
// windows/src/CantoFlow.App/TextInserter.cs
using System.Runtime.InteropServices;
using System.Text;

namespace CantoFlow.App;

/// <summary>
/// Inserts text into the focused application via clipboard + Ctrl+V.
/// Detects terminal applications and applies safety rules (no raw paste in terminals).
/// Mirrors macOS TextInserter.swift.
/// </summary>
public static class TextInserter
{
    // Terminal process names — same safety rule as macOS bundle-ID list
    private static readonly HashSet<string> TerminalProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "cmd", "powershell", "pwsh", "wt",
        "ConEmu64", "mintty", "alacritty", "Code" // VSCode integrated terminal
    };

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static bool IsForegroundAppTerminal()
    {
        var hwnd = GetForegroundWindow();
        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            var proc = System.Diagnostics.Process.GetProcessById((int)pid);
            return TerminalProcessNames.Contains(proc.ProcessName);
        }
        catch { return false; }
    }

    /// <summary>
    /// Copy text to clipboard and simulate Ctrl+V paste.
    /// Restores the previous clipboard content after paste.
    /// </summary>
    public static void InsertViaClipboard(string text)
    {
        var previous = Clipboard.GetText();
        Clipboard.SetText(text);
        SendCtrlV();
        Task.Delay(100).ContinueWith(_ =>
        {
            if (!string.IsNullOrEmpty(previous))
                Clipboard.SetText(previous);
        });
    }

    /// <summary>Undo last paste (Ctrl+Z), wait 50ms, then paste new text.</summary>
    public static void UndoAndReplace(string newText)
    {
        SendKeys.Send("^z");
        Thread.Sleep(50); // same 50ms delay as macOS STTPipeline.swift line 207
        InsertViaClipboard(newText);
    }

    private static void SendCtrlV() => SendKeys.Send("^v");
}
```

- [ ] **Step 5: Implement HotkeyManager stub**

```csharp
// windows/src/CantoFlow.App/HotkeyManager.cs
using System.Runtime.InteropServices;

namespace CantoFlow.App;

/// <summary>
/// Registers a global hotkey via Win32 RegisterHotKey.
/// Mirrors macOS HotkeyManager.swift / PushToTalkManager.swift.
/// </summary>
public class HotkeyManager : IDisposable
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int HotkeyId = 9001;
    private readonly IntPtr _hwnd;

    public event Action? KeyPressed;
    public event Action? KeyReleased;

    public HotkeyManager(IntPtr windowHandle)
    {
        _hwnd = windowHandle;
    }

    /// <param name="vk">Virtual key code (e.g. 0x7E = F15)</param>
    /// <param name="modifiers">Modifier flags (0 = none)</param>
    public bool Register(uint vk, uint modifiers = 0)
    {
        return RegisterHotKey(_hwnd, HotkeyId, modifiers, vk);
    }

    public void Dispose() => UnregisterHotKey(_hwnd, HotkeyId);
}
```

- [ ] **Step 6: Implement AudioCapture stub (NAudio WASAPI)**

```csharp
// windows/src/CantoFlow.App/AudioCapture.cs
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
```

- [ ] **Step 7: Implement WhisperRunner stub**

```csharp
// windows/src/CantoFlow.App/WhisperRunner.cs
using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// Runs whisper-cli.exe and parses output.
/// Mirrors macOS WhisperRunner.swift.
/// </summary>
public class WhisperRunner(AppConfig config)
{
    public async Task<string> TranscribeAsync(string wavPath, CancellationToken ct = default)
    {
        if (!File.Exists(config.WhisperCli))
            throw new FileNotFoundException($"whisper-cli.exe not found at {config.WhisperCli}");
        if (!File.Exists(config.WhisperModel))
            throw new FileNotFoundException($"Whisper model not found at {config.WhisperModel}");

        var outputPrefix = Path.Combine(config.OutDir,
            "raw_" + TelemetryLogger.FileTimestamp());

        var proc = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = config.WhisperCli,
                Arguments = $"-m \"{config.WhisperModel}\" -f \"{wavPath}\" -of \"{outputPrefix}\" -otxt -l zh --no-timestamps",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };

        proc.Start();
        await proc.WaitForExitAsync(ct);

        if (proc.ExitCode != 0)
        {
            var stderr = await proc.StandardError.ReadToEndAsync(ct);
            throw new InvalidOperationException($"whisper-cli exited {proc.ExitCode}: {stderr}");
        }

        var txtFile = outputPrefix + ".txt";
        return File.Exists(txtFile)
            ? (await File.ReadAllTextAsync(txtFile, ct)).Trim()
            : throw new FileNotFoundException("whisper-cli did not produce output .txt file");
    }
}
```

- [ ] **Step 8: Implement TrayIconController skeleton**

```csharp
// windows/src/CantoFlow.App/TrayIconController.cs
using CantoFlow.Core;

namespace CantoFlow.App;

/// <summary>
/// System tray icon + context menu. Mirrors macOS MenuBarController.swift.
/// </summary>
public class TrayIconController : IDisposable
{
    private readonly NotifyIcon _tray;
    private readonly AppConfig _config;
    public event Action? SettingsRequested;
    public event Action? QuitRequested;

    public TrayIconController(AppConfig config)
    {
        _config = config;
        _tray = new NotifyIcon
        {
            Text = "CantoFlow",
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        // Icon: use a placeholder until Resources/icon.ico is added
        _tray.Icon = SystemIcons.Application;
    }

    public void SetStatus(string status) => _tray.Text = $"CantoFlow — {status}";

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Settings...", null, (_, _) => SettingsRequested?.Invoke());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add($"Version {BuildVersion.Version}", null, null) { Enabled = false };
        menu.Items.Add("Quit", null, (_, _) => QuitRequested?.Invoke());
        return menu;
    }

    public void Dispose() => _tray.Dispose();
}
```

- [ ] **Step 9: Wire up Program.cs for the App**

```csharp
// windows/src/CantoFlow.App/Program.cs
using CantoFlow.App;
using CantoFlow.Core;
using CantoFlow.Server;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;

[STAThread]
Application.EnableVisualStyles();
Application.SetCompatibleTextRenderingDefault(false);

var config = new AppConfig();
var fileValues = EnvFileManager.LoadDefaults();
var polisher = new TextPolisher(config.PolishProvider, fileValues);
var outDir = config.OutDir;
Directory.CreateDirectory(outDir);
var logger = new TelemetryLogger(Path.Combine(outDir, "telemetry.jsonl"));
var transcriptionServer = new TranscriptionServer(polisher, logger, BuildVersion.Version, outDir);

// Start embedded HTTP server on Tailscale interface if enabled
WebApplication? webApp = null;
if (config.ServerEnabled)
{
    var builder = WebApplication.CreateBuilder();
    // TODO: bind to Tailscale 100.x.x.x interface only (query Tailscale local API)
    builder.WebHost.UseUrls($"http://0.0.0.0:{config.ServerPort}"); // placeholder binding
    webApp = builder.Build();
    webApp.MapGet("/health", () => Results.Ok(transcriptionServer.GetHealth()));
    webApp.MapPost("/transcribe", async (HttpRequest req, CancellationToken ct) =>
    {
        if (!req.HasFormContentType) return Results.BadRequest(new { error = "invalid_content_type" });
        var form = await req.ReadFormAsync(ct);
        var file = form.Files.GetFile("audio");
        if (file == null) return Results.BadRequest(new { error = "missing_audio_file" });
        await using var stream = file.OpenReadStream();
        var (code, body) = await transcriptionServer.TranscribeAsync(stream, file.FileName, ct);
        return code == 200 ? Results.Ok(body) : code == 503 ? Results.StatusCode(503) : Results.BadRequest(body);
    });
    _ = webApp.RunAsync();
}

using var tray = new TrayIconController(config);
tray.SettingsRequested += () => new SettingsForm(config, fileValues).ShowDialog();
tray.QuitRequested += () => { webApp?.StopAsync(); Application.Exit(); };

Application.Run(); // WinForms message loop
```

- [ ] **Step 10: Implement SettingsForm skeleton**

```csharp
// windows/src/CantoFlow.App/SettingsForm.cs
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
```

- [ ] **Step 11: Verify solution builds (including App project)**

```bash
cd /Volumes/JTDev/CantoFlow/windows
dotnet build
```
Expected: `Build succeeded` (App project may warn about Windows-only APIs on macOS — that is expected)

- [ ] **Step 12: Run all portable tests**

```bash
dotnet test tests/ -v normal
```
Expected: `9 passed, 0 failed`

- [ ] **Step 13: Final commit**

```bash
git add windows/
git commit -m "feat(windows/app): tray app scaffold with hotkey, audio, whisper, settings stubs"
```

---

## Integration Verification

- [ ] `dotnet build` — full solution, 0 errors
- [ ] `dotnet test tests/` — all portable tests pass
- [ ] Verify `windows/` directory structure matches spec layout
- [ ] Update `docs/current_status.md` with Windows scaffold status

---

## What Requires Windows to Complete

The following work is intentionally deferred — it requires a physical Windows machine:

1. **Global hotkey**: Register F15 / user-configured key with `RegisterHotKey` Win32 — test by holding key and verifying recording starts
2. **Audio capture**: Verify NAudio WASAPI records at 16kHz mono correctly
3. **WhisperRunner**: Wire up actual whisper-cli.exe Windows build
4. **TextInserter**: Test `SendKeys` clipboard paste in real Windows apps (Word, Teams, Notepad)
5. **Tailscale binding**: Query `localhost:41112/localapi/v0/status` for `100.x.x.x` IP; bind server to that interface
6. **Installer**: Build NSIS/WiX installer with whisper binary
7. **Build timestamp**: Add `Directory.Build.targets` MSBuild task to embed `yyyyMMdd.HHmm` into `BuildVersion.cs`
