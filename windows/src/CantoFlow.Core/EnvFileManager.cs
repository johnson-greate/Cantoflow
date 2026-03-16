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
                val = val[1..^1];
            result[key] = val;
        }
        return result;
    }

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
            if (env.TryGetValue(name, out var v) && !string.IsNullOrWhiteSpace(v))
                return v.Trim();

        if (fileValues != null)
            foreach (var key in fileKeys)
                if (fileValues.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v))
                    return v.Trim();

        return null;
    }

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

    public static Dictionary<string, string> LoadDefaults()
    {
        if (!File.Exists(DefaultPath))
            UpdateEnvFile(DefaultPath, "GEMINI_API_KEY", "");
        return ParseEnvFile(File.ReadAllText(DefaultPath));
    }
}
