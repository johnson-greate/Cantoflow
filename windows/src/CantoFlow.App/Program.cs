using CantoFlow.App;
using CantoFlow.Core;
using CantoFlow.Server;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
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
            builder.WebHost.UseUrls($"http://0.0.0.0:{config.ServerPort}");
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

        using var ptt = new PushToTalkController(config, polisher, logger);

        Application.Run(); // WinForms message loop
    }
}
