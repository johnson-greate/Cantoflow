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

    IFormCollection form;
    try { form = await request.ReadFormAsync(ct); }
    catch (InvalidDataException) { return Results.BadRequest(new { error = "missing_audio_file" }); }
    var file = form.Files.GetFile("audio");
    if (file == null)
        return Results.BadRequest(new { error = "missing_audio_file" });

    await using var stream = file.OpenReadStream();
    var (statusCode, body) = await server.TranscribeAsync(stream, file.FileName, ct);
    return statusCode == 200 ? Results.Ok(body)
         : statusCode == 503 ? Results.StatusCode(503)
         : Results.BadRequest(body);
});

app.Run();

// Make Program visible to test project
public partial class Program { }
