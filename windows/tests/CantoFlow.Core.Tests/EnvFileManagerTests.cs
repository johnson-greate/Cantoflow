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
            envVars: new Dictionary<string, string>(),
            fileValues: new Dictionary<string, string>());
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
