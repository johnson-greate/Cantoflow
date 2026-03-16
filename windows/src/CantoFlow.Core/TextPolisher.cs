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

    public PolishProvider ResolveProvider() => _configuredProvider switch
    {
        PolishProvider.Gemini    => ResolveKey("GEMINI_API_KEY") != null ? PolishProvider.Gemini : PolishProvider.None,
        PolishProvider.Qwen      => ResolveQwenKey() != null ? PolishProvider.Qwen : PolishProvider.None,
        PolishProvider.OpenAI    => ResolveKey("OPENAI_API_KEY") != null ? PolishProvider.OpenAI : PolishProvider.None,
        PolishProvider.Anthropic => ResolveKey("ANTHROPIC_API_KEY") != null ? PolishProvider.Anthropic : PolishProvider.None,
        PolishProvider.None      => PolishProvider.None,
        _                        => ResolveAuto()
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

    // Windows env file uses uppercase env-var names (not macOS UserDefaults camelCase)
    private string? ResolveQwenKey() =>
        EnvFileManager.ResolveApiKey(
            ["DASHSCOPE_API_KEY", "QWEN_API_KEY"],
            ["DASHSCOPE_API_KEY", "QWEN_API_KEY"],
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
            model, temperature = 0.2, max_tokens = 1024, enable_thinking = false,
            messages = new[] { new { role = "system", content = system }, new { role = "user", content = user } }
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
            model, temperature = 0.2, max_completion_tokens = 1024,
            messages = new[] { new { role = "system", content = system }, new { role = "user", content = user } }
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
            .GetProperty("candidates")[0].GetProperty("content")
            .GetProperty("parts")[0].GetProperty("text")
            .GetString()?.Trim() ?? throw new InvalidOperationException("Empty Gemini response");
    }

    private async Task<string> CallAnthropicAsync(string system, string user, CancellationToken ct)
    {
        var apiKey = ResolveKey("ANTHROPIC_API_KEY")!;
        var model = Environment.GetEnvironmentVariable("ANTHROPIC_MODEL") ?? "claude-sonnet-4-6";
        var body = JsonSerializer.Serialize(new
        {
            model, max_tokens = 1024, temperature = 0.2, system,
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
            .GetProperty("choices")[0].GetProperty("message").GetProperty("content")
            .GetString()?.Trim()
            ?? throw new InvalidOperationException("Empty response from API");
    }
}

public record PolishResult(string Text, PolishProvider Provider, int DurationMs);
