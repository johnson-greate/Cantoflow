# Corporate STT Server Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy CantoFlow as a shared corporate STT service on an 8× Intel Arc A770 Linux server, so all 5 users (LAN + VPN) get ~1–2s transcription without local Whisper setup.

**Architecture:** Extend the existing `CantoFlow.Server` (.NET ASP.NET Core) to run real whisper-cli with a GPU worker pool (one slot per A770), add Bearer-token auth, and extend `TextPolisher` with a local LLM fallback (Ollama/vLLM). Both macOS and Windows clients gain an optional `--stt-server` mode that sends recorded WAV to the server and inserts the returned final text, bypassing local Whisper entirely.

**Tech Stack:** .NET 10 ASP.NET Core (server), Swift (macOS client), C# WinForms (Windows client), whisper-cli with Vulkan on Linux (Intel Arc A770), Ollama for local LLM, systemd for process management.

---

## Context: Existing Codebase

| File | Current state |
|------|--------------|
| `windows/src/CantoFlow.Server/TranscriptionServer.cs` | Has Whisper **stub** — returns placeholder text. Auth = none. Single semaphore. |
| `windows/src/CantoFlow.Server/Program.cs` | Minimal ASP.NET app, no auth middleware, HTTP only. |
| `windows/src/CantoFlow.Core/TextPolisher.cs` | Supports Gemini / Qwen / OpenAI / Anthropic. No local LLM. |
| `windows/src/CantoFlow.Core/PolishProvider.cs` | `enum PolishProvider { Auto, Gemini, Qwen, OpenAI, Anthropic, None }` |
| `app/Sources/CantoFlowApp/AppConfig.swift` | No `serverUrl` / `serverToken` fields. |
| `app/Sources/CantoFlowApp/Core/STTPipeline.swift` | Always runs local Whisper. |

**Server hardware:** 8× Intel Arc A770 (16 GB each), 512 GB RAM, dual 10 GbE, Linux OS.
**Users:** 5 (LAN + VPN). Polish priority: Qwen API → local Ollama endpoint → raw text.

---

## File Map

### New files (server)
| Path | Responsibility |
|------|---------------|
| `windows/src/CantoFlow.Server/TokenStore.cs` | Load valid Bearer tokens from `/etc/cantoflow/tokens.conf` |
| `windows/src/CantoFlow.Server/AuthMiddleware.cs` | Reject requests without valid `Authorization: Bearer <token>` |
| `windows/src/CantoFlow.Server/GpuWorkerPool.cs` | Pool of N GPU slots; assigns `GGML_VK_VISIBLE_DEVICES=N` per job |
| `docs/server-deployment.md` | Step-by-step Linux setup guide (whisper-cli, HTTPS, systemd) |

### Modified files (server)
| Path | Change |
|------|--------|
| `windows/src/CantoFlow.Core/WhisperRunner.cs` | **Move here from App project** (it only uses Core types + `System.Diagnostics`). Server needs it and only references Core. |
| `windows/src/CantoFlow.Server/TranscriptionServer.cs` | Replace stub with real `WhisperRunner` via `GpuWorkerPool`; queue instead of 503 |
| `windows/src/CantoFlow.Server/Program.cs` | Add `AuthMiddleware`; read server config from env; HTTPS config |
| `windows/src/CantoFlow.Core/PolishProvider.cs` | Add `LocalLlm` enum value |
| `windows/src/CantoFlow.Core/TextPolisher.cs` | Add `LocalLlm` provider (OpenAI-compatible `/v1/chat/completions`); auto-priority: Qwen → LocalLlm → None |

### New files (clients)
| Path | Responsibility |
|------|---------------|
| `windows/src/CantoFlow.Core/RemoteSTTClient.cs` | POST WAV to server, return `RemoteSTTResult` |
| `app/Sources/CantoFlowApp/Core/RemoteSTTClient.swift` | Same for macOS (URLSession async) |

### Modified files (clients)
| Path | Change |
|------|--------|
| `windows/src/CantoFlow.App/AppConfig.cs` | Add `ServerUrl`, `ServerToken` from env |
| `windows/src/CantoFlow.App/PushToTalkController.cs` | If `ServerUrl` set → use `RemoteSTTClient`, skip local Whisper + polish |
| `app/Sources/CantoFlowApp/AppConfig.swift` | Add `serverUrl`, `serverToken` from env / CLI args |
| `app/Sources/CantoFlowApp/Core/STTPipeline.swift` | If `serverUrl` set → delegate to `RemoteSTTClient`, skip local pipeline |

---

## Chunk 1: Server — Auth

### Task 1: TokenStore

**Files:**
- Create: `windows/src/CantoFlow.Server/TokenStore.cs`

- [ ] Create `TokenStore.cs`:

```csharp
namespace CantoFlow.Server;

/// <summary>
/// Loads valid Bearer tokens from a newline-delimited file.
/// One token per line; blank lines and # comments ignored.
/// Reloads on each call to IsValid() to support token rotation without restart.
/// </summary>
public class TokenStore(string filePath)
{
    public bool IsValid(string token)
    {
        if (!File.Exists(filePath)) return false;
        return File.ReadLines(filePath)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('#'))
            .Contains(token, StringComparer.Ordinal);
    }
}
```

- [ ] Create `/etc/cantoflow/tokens.conf` on the server (NOT committed to repo — contains secrets):

```
# CantoFlow server tokens — one per user
# Generated with: python3 -c "import secrets; print(secrets.token_urlsafe(32))"
aBcDeFgH...  # Calvin
xYzW1234...  # User 2
...
```

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Server/TokenStore.cs
git commit -m "feat(server): add TokenStore for Bearer token auth"
```

---

### Task 2: AuthMiddleware

**Files:**
- Create: `windows/src/CantoFlow.Server/AuthMiddleware.cs`
- Modify: `windows/src/CantoFlow.Server/Program.cs`

- [ ] Create `AuthMiddleware.cs`:

```csharp
namespace CantoFlow.Server;

public class AuthMiddleware(RequestDelegate next, TokenStore tokens)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        // /health is public — allows monitoring without token
        if (ctx.Request.Path.StartsWithSegments("/health"))
        {
            await next(ctx);
            return;
        }

        var auth = ctx.Request.Headers.Authorization.FirstOrDefault();
        if (auth == null || !auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            ctx.Response.StatusCode = 401;
            await ctx.Response.WriteAsJsonAsync(new { error = "missing_token" });
            return;
        }

        var token = auth["Bearer ".Length..].Trim();
        if (!tokens.IsValid(token))
        {
            ctx.Response.StatusCode = 401;
            await ctx.Response.WriteAsJsonAsync(new { error = "invalid_token" });
            return;
        }

        await next(ctx);
    }
}
```

- [ ] In `Program.cs`, add after `var app = builder.Build();`:

```csharp
var tokenStore = new TokenStore(
    Environment.GetEnvironmentVariable("CANTOFLOW_TOKENS_FILE")
    ?? "/etc/cantoflow/tokens.conf");
app.UseMiddleware<AuthMiddleware>(tokenStore);
```

- [ ] Test with curl on local machine:

```bash
# Should return 401
curl -s http://localhost:5000/transcribe -X POST | jq .

# Should return 200 (health is public)
curl -s http://localhost:5000/health | jq .
```

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Server/AuthMiddleware.cs \
        windows/src/CantoFlow.Server/Program.cs
git commit -m "feat(server): Bearer token auth middleware; /health exempt"
```

---

## Chunk 2: Server — Move WhisperRunner + GPU Worker Pool + Real Whisper

### Task 3: Move WhisperRunner to CantoFlow.Core

**Why:** `CantoFlow.Server` only references `CantoFlow.Core` (not App). WhisperRunner only uses `AppConfig` and `System.Diagnostics.Process` — both available in Core. Moving it lets Server use real Whisper without a circular dependency.

**Files:**
- Move: `windows/src/CantoFlow.App/WhisperRunner.cs` → `windows/src/CantoFlow.Core/WhisperRunner.cs`
- Modify: `windows/src/CantoFlow.App/WhisperRunner.cs` — delete after move

- [ ] Copy the file:
```bash
cp windows/src/CantoFlow.App/WhisperRunner.cs windows/src/CantoFlow.Core/WhisperRunner.cs
```

- [ ] Change the namespace in the new file from `CantoFlow.App` to `CantoFlow.Core`:
```csharp
// Line 3: change
namespace CantoFlow.App;
// to
namespace CantoFlow.Core;
```

- [ ] Remove the `using CantoFlow.Core;` import (no longer needed — same namespace):
```csharp
// Delete line 1: using CantoFlow.Core;
```

- [ ] Delete the original from App:
```bash
rm windows/src/CantoFlow.App/WhisperRunner.cs
```

- [ ] Build both projects to verify no breakage:
```bash
cd windows && dotnet build src/CantoFlow.App && dotnet build src/CantoFlow.Server
```
Expected: `Build succeeded. 0 Error(s)` for both.

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Core/WhisperRunner.cs
git rm windows/src/CantoFlow.App/WhisperRunner.cs
git commit -m "refactor: move WhisperRunner to CantoFlow.Core (needed by Server)"
```

---

### Task 4: GpuWorkerPool

**Files:**
- Create: `windows/src/CantoFlow.Server/GpuWorkerPool.cs`

- [ ] Create `GpuWorkerPool.cs`:

```csharp
namespace CantoFlow.Server;

/// <summary>
/// Manages N GPU slots. Each acquired slot carries a GPU index (0..N-1).
/// Callers await AcquireAsync(), use the slot, then call Release().
/// On a machine with 8× A770, N=8 lets 8 jobs run concurrently.
/// </summary>
public sealed class GpuWorkerPool : IDisposable
{
    private readonly SemaphoreSlim _sem;
    private readonly Queue<int> _freeSlots;
    private readonly Lock _lock = new();

    public GpuWorkerPool(int gpuCount)
    {
        _sem = new SemaphoreSlim(gpuCount, gpuCount);
        _freeSlots = new Queue<int>(Enumerable.Range(0, gpuCount));
    }

    public async Task<int> AcquireAsync(CancellationToken ct)
    {
        await _sem.WaitAsync(ct);
        lock (_lock) return _freeSlots.Dequeue();
    }

    public void Release(int gpuIndex)
    {
        lock (_lock) _freeSlots.Enqueue(gpuIndex);
        _sem.Release();
    }

    public void Dispose() => _sem.Dispose();
}
```

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Server/GpuWorkerPool.cs
git commit -m "feat(server): GpuWorkerPool — N-slot GPU assignment for concurrent STT"
```

---

### Task 5: Wire real Whisper into TranscriptionServer

**Files:**
- Modify: `windows/src/CantoFlow.Server/TranscriptionServer.cs`
- Modify: `windows/src/CantoFlow.Server/Program.cs`

- [ ] Add `GpuWorkerPool` and `AppConfig` to `TranscriptionServer` constructor, remove the `SemaphoreSlim`:

```csharp
// Remove: private readonly SemaphoreSlim _semaphore = new(1, 1);
// Add fields:
private readonly GpuWorkerPool _pool;
private readonly AppConfig _appConfig;
```

- [ ] Replace the stub block in `TranscribeAsync` with real Whisper call:

```csharp
// Acquire a GPU slot (queues if all busy — no 503 for 5 users)
var gpuIndex = await _pool.AcquireAsync(ct);
try
{
    // Pin this process to one A770
    Environment.SetEnvironmentVariable("GGML_VK_VISIBLE_DEVICES", gpuIndex.ToString());

    var sttStart = Stopwatch.GetTimestamp();
    var runner   = new WhisperRunner(_appConfig);
    var rawText  = await runner.TranscribeAsync(wavPath, VocabularyStore.GenerateWhisperPrompt(), ct);
    var sttMs    = (int)Stopwatch.GetElapsedTime(sttStart).TotalMilliseconds;
    // ... rest of polish logic unchanged ...
    return (200, new { text = finalText, raw = rawText, provider, stt_ms = sttMs, polish_ms = polishMs });
}
finally
{
    _pool.Release(gpuIndex);
}
```

- [ ] In `Program.cs`, create pool and pass to server:

```csharp
var gpuCount = int.TryParse(
    Environment.GetEnvironmentVariable("GPU_COUNT"), out var n) ? n : 8;
var pool = new GpuWorkerPool(gpuCount);
// pass pool + appConfig to TranscriptionServer constructor
```

- [ ] Build to verify:
```bash
cd windows && dotnet build src/CantoFlow.Server
```
Expected: `Build succeeded. 0 Error(s)`

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Server/TranscriptionServer.cs \
        windows/src/CantoFlow.Server/Program.cs
git commit -m "feat(server): replace Whisper stub with real GPU worker pool execution"
```

---

## Chunk 3: Server — Local LLM Polish

### Task 6: Add LocalLlm provider to TextPolisher

**Files:**
- Modify: `windows/src/CantoFlow.Core/PolishProvider.cs`
- Modify: `windows/src/CantoFlow.Core/TextPolisher.cs`

- [ ] Add to `PolishProvider.cs`:

```csharp
public enum PolishProvider { Auto, Gemini, Qwen, OpenAI, Anthropic, LocalLlm, None }
```

- [ ] Add `ResolveLocalLlm()` to `TextPolisher.cs`:

```csharp
private string? ResolveLocalLlmEndpoint() =>
    EnvFileManager.ResolveApiKey(
        ["LOCAL_LLM_ENDPOINT"], ["LOCAL_LLM_ENDPOINT"], fileValues: _fileValues);
```

- [ ] Extend `ResolveAuto()` — insert LocalLlm between Qwen and OpenAI in priority:

```csharp
private PolishProvider ResolveAuto()
{
    if (ResolveQwenKey() != null)            return PolishProvider.Qwen;
    if (ResolveLocalLlmEndpoint() != null)   return PolishProvider.LocalLlm;
    if (ResolveKey("OPENAI_API_KEY") != null) return PolishProvider.OpenAI;
    if (ResolveKey("ANTHROPIC_API_KEY") != null) return PolishProvider.Anthropic;
    if (ResolveKey("GEMINI_API_KEY") != null) return PolishProvider.Gemini;
    return PolishProvider.None;
}
```

- [ ] Add `LocalLlm` case to `PolishAsync()` switch. The server (e.g., Ollama) exposes an OpenAI-compatible `/v1/chat/completions` endpoint:

```csharp
PolishProvider.LocalLlm => await PolishViaLocalLlmAsync(rawText, polishStyle, ct),
```

- [ ] Add `PolishViaLocalLlmAsync`:

```csharp
private async Task<PolishResult> PolishViaLocalLlmAsync(
    string rawText, string polishStyle, CancellationToken ct)
{
    var endpoint = ResolveLocalLlmEndpoint()!;   // e.g. http://localhost:11434/v1/chat/completions
    var model    = _fileValues.GetValueOrDefault("LOCAL_LLM_MODEL", "qwen2.5:72b");

    var payload = new
    {
        model,
        messages = new[]
        {
            new { role = "system", content = PromptBuilder.BuildSystemPrompt(polishStyle, VocabularyStore.GeneratePolishPromptSection()) },
            new { role = "user",   content = PromptBuilder.BuildUserPrompt(rawText, polishStyle) }
        },
        temperature = 0.3,
        stream = false
    };

    var sw  = Stopwatch.StartNew();
    var req = new HttpRequestMessage(HttpMethod.Post, endpoint)
    {
        Content = new StringContent(
            JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
    };
    var resp = await Http.SendAsync(req, ct);
    resp.EnsureSuccessStatusCode();

    var json    = await resp.Content.ReadAsStringAsync(ct);
    var doc     = JsonDocument.Parse(json);
    var text    = doc.RootElement
                     .GetProperty("choices")[0]
                     .GetProperty("message")
                     .GetProperty("content")
                     .GetString() ?? rawText;
    return new PolishResult(text.Trim(), PolishProvider.LocalLlm, (int)sw.Elapsed.TotalMilliseconds);
}
```

- [ ] Build:
```bash
cd windows && dotnet build src/CantoFlow.Core
```
Expected: `Build succeeded. 0 Error(s)`

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Core/PolishProvider.cs \
        windows/src/CantoFlow.Core/TextPolisher.cs
git commit -m "feat(core): LocalLlm polish provider — Ollama/vLLM OpenAI-compatible endpoint"
```

---

## Chunk 4: Server — Linux Deployment

### Task 7: Server config env file

**Files:**
- Create on server (NOT in repo): `/etc/cantoflow/server.env`
- Create on server (NOT in repo): `/etc/cantoflow/tokens.conf`

- [ ] On the Linux server, create config (replace values):

```bash
sudo mkdir -p /etc/cantoflow
sudo tee /etc/cantoflow/server.env <<'EOF'
# Whisper
WHISPER_CLI=/usr/local/bin/whisper-cli
WHISPER_MODEL=/var/lib/cantoflow/models/ggml-large-v3-turbo-q5_0.bin
GPU_COUNT=8

# Auth
CANTOFLOW_TOKENS_FILE=/etc/cantoflow/tokens.conf

# Polish (priority: Qwen API → local Ollama → raw)
QWEN_API_KEY=sk-xxxxxxxx
LOCAL_LLM_ENDPOINT=http://localhost:11434/v1/chat/completions
LOCAL_LLM_MODEL=qwen2.5:72b
EOF
sudo chmod 600 /etc/cantoflow/server.env
```

- [ ] Generate one token per user:
```bash
for user in calvin user2 user3 user4 user5; do
  echo "$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')  # $user"
done | sudo tee /etc/cantoflow/tokens.conf
sudo chmod 600 /etc/cantoflow/tokens.conf
```

---

### Task 8: Build whisper-cli with Vulkan on Linux (A770)

- [ ] Install prerequisites:
```bash
sudo apt update
sudo apt install -y cmake build-essential git
# Intel Vulkan driver for Arc A770
sudo apt install -y intel-media-va-driver-non-free libvulkan1 vulkan-tools
```

- [ ] Verify Vulkan sees A770:
```bash
vulkaninfo --summary | grep -i "intel\|arc\|a770"
```
Expected: device listed with `Intel(R) Arc(TM) A770`

- [ ] Clone and build whisper.cpp with Vulkan:
```bash
git clone https://github.com/ggml-org/whisper.cpp /opt/whisper-src
cd /opt/whisper-src
cmake -B build_vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build_vulkan --config Release -j$(nproc)
sudo cp build_vulkan/bin/whisper-cli /usr/local/bin/
```

- [ ] Download model:
```bash
sudo mkdir -p /var/lib/cantoflow/models
cd /var/lib/cantoflow/models
sudo wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

- [ ] Verify Vulkan STT works:
```bash
GGML_VK_VISIBLE_DEVICES=0 whisper-cli \
  -m /var/lib/cantoflow/models/ggml-large-v3-turbo-q5_0.bin \
  -f /path/to/test.wav \
  -l auto --no-timestamps -t 8 -ac 768 -bo 1 -bs 1 2>&1 | \
  grep -E "ggml_vulkan|encode time|total time"
```
Expected: `ggml_vulkan: 0 = Intel(R) Arc(TM) A770`, encode time < 3000ms

---

### Task 9: Publish .NET server + systemd

- [ ] Publish server binary:
```bash
# On dev machine or CI:
cd /path/to/CantoFlow/windows
dotnet publish src/CantoFlow.Server -c Release -r linux-x64 --self-contained \
  -o /tmp/cantoflow-server-publish
# scp to server
scp -r /tmp/cantoflow-server-publish/* user@server:/opt/cantoflow-server/
```

- [ ] Create systemd unit on server at `/etc/systemd/system/cantoflow-server.service`:

```ini
[Unit]
Description=CantoFlow Corporate STT Server
After=network.target

[Service]
Type=simple
User=cantoflow
WorkingDirectory=/opt/cantoflow-server
EnvironmentFile=/etc/cantoflow/server.env
ExecStart=/opt/cantoflow-server/CantoFlow.Server --urls http://0.0.0.0:5100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] Enable and start:
```bash
sudo useradd -r -s /bin/false cantoflow
sudo systemctl daemon-reload
sudo systemctl enable cantoflow-server
sudo systemctl start cantoflow-server
sudo systemctl status cantoflow-server
```

Expected: `Active: active (running)`

- [ ] Smoke test auth + transcription:
```bash
TOKEN=$(head -1 /etc/cantoflow/tokens.conf | awk '{print $1}')

# Health (no token required)
curl http://localhost:5100/health | jq .

# Transcribe (with token)
curl -X POST http://localhost:5100/transcribe \
  -H "Authorization: Bearer $TOKEN" \
  -F "audio=@/path/to/test.wav" | jq .
```
Expected response:
```json
{
  "text": "最終潤飾文字",
  "raw": "Whisper 原始輸出",
  "stt_ms": 1800,
  "polish_ms": 2100,
  "polish_provider": "qwen"
}
```

---

### Task 10: HTTPS with self-signed cert (for VPN users)

VPN users connect over internet — need TLS.

- [ ] Generate self-signed cert (valid 3 years):
```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 1095 -nodes \
  -keyout /etc/cantoflow/server.key \
  -out /etc/cantoflow/server.crt \
  -subj "/CN=cantoflow-server" \
  -addext "subjectAltName=IP:192.168.x.x,DNS:cantoflow-server"
sudo chmod 600 /etc/cantoflow/server.key
```

- [ ] Convert to PKCS12 for .NET:
```bash
sudo openssl pkcs12 -export -out /etc/cantoflow/server.pfx \
  -inkey /etc/cantoflow/server.key \
  -in /etc/cantoflow/server.crt \
  -passout pass:cantoflow
```

- [ ] Add to `server.env`:
```
ASPNETCORE_Kestrel__Certificates__Default__Path=/etc/cantoflow/server.pfx
ASPNETCORE_Kestrel__Certificates__Default__Password=cantoflow
```

- [ ] Update systemd `ExecStart` to HTTPS:
```
ExecStart=/opt/cantoflow-server/CantoFlow.Server --urls https://0.0.0.0:5100
```

- [ ] Distribute `server.crt` to each client machine for trust.

- [ ] Commit deployment docs:
```bash
git add docs/server-deployment.md
git commit -m "docs: Linux deployment guide for corporate STT server"
```

---

## Chunk 5: Client — Windows Remote STT

### Task 11: RemoteSTTClient (Windows / Core)

**Files:**
- Create: `windows/src/CantoFlow.Core/RemoteSTTClient.cs`

- [ ] Create `RemoteSTTClient.cs`:

```csharp
using System.Net.Http.Headers;
using System.Text.Json;

namespace CantoFlow.Core;

public record RemoteSTTResult(string Text, string Raw, int SttMs, int PolishMs, string Provider);

public class RemoteSTTClient
{
    private readonly HttpClient _http;
    private readonly string _serverUrl;
    private readonly string _token;

    public RemoteSTTClient(string serverUrl, string token, bool acceptSelfSigned = false)
    {
        _serverUrl = serverUrl.TrimEnd('/');
        _token     = token;

        var handler = new HttpClientHandler();
        if (acceptSelfSigned)
            handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;

        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(60) };
        _http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);
    }

    public async Task<RemoteSTTResult> TranscribeAsync(string wavPath, CancellationToken ct = default)
    {
        await using var fs = File.OpenRead(wavPath);
        using var content  = new MultipartFormDataContent();
        var fileContent    = new StreamContent(fs);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(fileContent, "audio", Path.GetFileName(wavPath));

        var resp = await _http.PostAsync($"{_serverUrl}/transcribe", content, ct);
        if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            throw new UnauthorizedAccessException("Server returned 401 — check CANTOFLOW_SERVER_TOKEN");
        resp.EnsureSuccessStatusCode();

        var json = await resp.Content.ReadAsStringAsync(ct);
        var doc  = JsonDocument.Parse(json).RootElement;
        return new RemoteSTTResult(
            Text:     doc.GetProperty("text").GetString() ?? "",
            Raw:      doc.TryGetProperty("raw", out var r) ? r.GetString() ?? "" : "",
            SttMs:    doc.TryGetProperty("stt_ms", out var s) ? s.GetInt32() : 0,
            PolishMs: doc.TryGetProperty("polish_ms", out var p) ? p.GetInt32() : 0,
            Provider: doc.TryGetProperty("polish_provider", out var pr) ? pr.GetString() ?? "" : ""
        );
    }
}
```

- [ ] Add `ServerUrl` and `ServerToken` to Windows `AppConfig.cs`.
Note: `AppConfig` has no `_fileValues` field — use `EnvFileManager.LoadDefaults()` directly,
same pattern as other callers in the codebase:

```csharp
// Add near bottom of AppConfig.cs, alongside WhisperModel / WhisperCli
public string ServerUrl =>
    EnvFileManager.LoadDefaults().GetValueOrDefault("CANTOFLOW_SERVER_URL", "");
public string ServerToken =>
    EnvFileManager.LoadDefaults().GetValueOrDefault("CANTOFLOW_SERVER_TOKEN", "");
public bool UseServer => !string.IsNullOrWhiteSpace(ServerUrl);
```

- [ ] In `PushToTalkController.cs`, replace the local `WhisperRunner` call with:

```csharp
string finalText;
int sttMs = 0, polishMs = 0;

if (_config.UseServer)
{
    var client = new RemoteSTTClient(_config.ServerUrl, _config.ServerToken, acceptSelfSigned: true);
    var result = await client.TranscribeAsync(wavPath, ct);
    finalText = result.Text;
    sttMs     = result.SttMs;
    polishMs  = result.PolishMs;
}
else
{
    // existing local Whisper + polish path (unchanged)
}
```

- [ ] Add to client's `%APPDATA%\CantoFlow\cantoflow.env` (per user — contains their personal token):
```
CANTOFLOW_SERVER_URL=https://192.168.x.x:5100
CANTOFLOW_SERVER_TOKEN=<user-specific-token>
```

- [ ] Build:
```bash
cd windows && dotnet build src/CantoFlow.App
```
Expected: `Build succeeded. 0 Error(s)`

- [ ] Commit:
```bash
git add windows/src/CantoFlow.Core/RemoteSTTClient.cs \
        windows/src/CantoFlow.App/AppConfig.cs \
        windows/src/CantoFlow.App/PushToTalkController.cs
git commit -m "feat(windows): remote STT client — use corporate server when SERVER_URL set"
```

---

## Chunk 6: Client — macOS Remote STT

### Task 12: RemoteSTTClient (macOS Swift)

**Files:**
- Create: `app/Sources/CantoFlowApp/Core/RemoteSTTClient.swift`
- Modify: `app/Sources/CantoFlowApp/AppConfig.swift`
- Modify: `app/Sources/CantoFlowApp/Core/STTPipeline.swift`

- [ ] Create `RemoteSTTClient.swift`:

```swift
import Foundation

struct RemoteSTTResult {
    let text: String
    let raw: String
    let sttMs: Int
    let polishMs: Int
    let provider: String
}

/// Sends a WAV file to the corporate CantoFlow server and returns the result.
/// Accepts self-signed TLS certificates (corporate internal server).
actor RemoteSTTClient: NSObject, URLSessionDelegate {

    private let serverURL: URL
    private let token: String
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    func transcribe(wavURL: URL) async throws -> RemoteSTTResult {
        let endpoint = serverURL.appendingPathComponent("transcribe")
        var request  = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let wavData   = try Data(contentsOf: wavURL)
        var body      = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(wavURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 {
            throw NSError(domain: "CantoFlow", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Server returned 401 — check CANTOFLOW_SERVER_TOKEN"])
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return RemoteSTTResult(
            text:     json["text"]         as? String ?? "",
            raw:      json["raw"]          as? String ?? "",
            sttMs:    json["stt_ms"]       as? Int    ?? 0,
            polishMs: json["polish_ms"]    as? Int    ?? 0,
            provider: json["polish_provider"] as? String ?? ""
        )
    }

    // Accept self-signed cert for internal server
    nonisolated func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
```

- [ ] Add to the `AppConfig` struct in `AppConfig.swift` (after the existing `useMetalGPU` field):

```swift
// Corporate STT server — optional, read from process environment or ~/.cantoflow.env
var serverURLString: String = ""   // set during CLI argument parsing
var serverToken:     String = ""   // set during CLI argument parsing

var serverURL: URL? {
    guard !serverURLString.isEmpty else { return nil }
    return URL(string: serverURLString)
}
var useServer: Bool { serverURL != nil }
```

- [ ] In the CLI argument parser (same file or `main.swift`), add parsing for `--stt-server` and `--server-token`, falling back to env vars:

```swift
// After existing argument parsing, add:
config.serverURLString = args["--stt-server"]
    ?? ProcessInfo.processInfo.environment["CANTOFLOW_SERVER_URL"] ?? ""
config.serverToken     = args["--server-token"]
    ?? ProcessInfo.processInfo.environment["CANTOFLOW_SERVER_TOKEN"] ?? ""
```

- [ ] In `STTPipeline.swift`, at the top of `stopAndProcess()`, add server branch:

```swift
if config.useServer, let url = config.serverURL {
    let client = RemoteSTTClient(serverURL: url, token: config.serverToken)
    let result = try await client.transcribe(wavURL: wavFileURL)
    await textInserter.insert(result.text)
    // update overlay / tray stats using result.sttMs, result.polishMs
    return
}
// ... rest of existing local pipeline unchanged ...
```

- [ ] Build:
```bash
cd /path/to/CantoFlow/app
swift build
```
Expected: `Build complete!`

- [ ] Add to `~/.cantoflow.env` on each macOS client:
```
CANTOFLOW_SERVER_URL=https://192.168.x.x:5100
CANTOFLOW_SERVER_TOKEN=<user-specific-token>
```

- [ ] Commit:
```bash
git add app/Sources/CantoFlowApp/Core/RemoteSTTClient.swift \
        app/Sources/CantoFlowApp/AppConfig.swift \
        app/Sources/CantoFlowApp/Core/STTPipeline.swift
git commit -m "feat(macos): remote STT client — use corporate server when SERVER_URL set"
```

---

## Deployment Checklist (when server arrives)

- [ ] **Linux setup**: Install .NET 10 runtime, Vulkan drivers, whisper-cli (Tasks 7–8)
- [ ] **Config**: Create `/etc/cantoflow/server.env` and `tokens.conf` (Task 6)
- [ ] **TLS**: Generate self-signed cert, distribute `server.crt` to clients (Task 9)
- [ ] **Server**: `systemctl start cantoflow-server`, smoke test with curl (Task 8)
- [ ] **Optional — Ollama**: `curl -fsSL https://ollama.ai/install.sh | sh && ollama pull qwen2.5:72b`
- [ ] **Clients**: Add `CANTOFLOW_SERVER_URL` + `CANTOFLOW_SERVER_TOKEN` to each user's env file (Tasks 10–11)
- [ ] **Test**: Record on client → verify round-trip < 5s on LAN

---

## Performance Expectations (A770 + Vulkan)

| Audio length | Expected STT | Expected Polish | Total |
|---|---|---|---|
| 5s | ~0.8s | ~1.5s | ~2.5s |
| 10s | ~1.5s | ~1.5s | ~3s |
| 20s | ~2.5s | ~1.5s | ~4s |

*Based on Windows A770 Vulkan benchmark (6.7s for 11s audio). Linux with Intel Arc driver should be similar.*
