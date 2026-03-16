// windows/tests/CantoFlow.Core.Tests/TextPolisherTests.cs
using Xunit;
using CantoFlow.Core;

namespace CantoFlow.Core.Tests;

public class TextPolisherTests
{
    [Fact]
    public void ResolveProvider_ReturnsNone_WhenNoKeysPresent()
    {
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: new Dictionary<string, string>());
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
        var polisher = new TextPolisher(PolishProvider.Qwen, fileValues: new Dictionary<string, string>());
        Assert.Equal(PolishProvider.None, polisher.ResolveProvider());
    }

    [Fact]
    public void IsAvailable_ReturnsFalse_WhenNoKeys()
    {
        var polisher = new TextPolisher(PolishProvider.Auto, fileValues: new Dictionary<string, string>());
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
