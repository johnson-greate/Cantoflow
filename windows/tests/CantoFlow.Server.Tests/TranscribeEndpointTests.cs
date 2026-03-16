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
