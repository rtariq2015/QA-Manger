using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http.Features;

// This process serves only a local interface. Windows PowerShell remains the file/QA adapter.
var settings = HostOptions.Parse(args);
var root = Path.GetFullPath(settings.Root);
SafeFiles.RequireDirect(root);
if (!File.Exists(Path.Combine(root, "App", "WebWorker.ps1")) || !File.Exists(Path.Combine(root, "App", "Web", "index.html")))
    throw new InvalidOperationException("Extract the complete portable program before starting it.");
Directory.CreateDirectory(Path.Combine(root, "Data"));
SafeFiles.RequireDirect(Path.Combine(root, "Data"));
SafeFiles.RequireDirect(Path.Combine(root, "Data", "application.lock"));
using var instance = new FileStream(Path.Combine(root, "Data", "application.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = Array.Empty<string>(), ContentRootPath = root });
builder.Logging.ClearProviders();
builder.Configuration.Sources.Clear(); // Do not inherit external Kestrel endpoints or remote configuration.
builder.WebHost.ConfigureKestrel(options => {
    options.Listen(IPAddress.Loopback, settings.Port);
    options.AddServerHeader = false;
    options.Limits.MaxRequestBodySize = 268_435_456 + 1_048_576;
    options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
});
builder.Services.Configure<FormOptions>(options => options.MultipartBodyLengthLimit = 268_435_456);
var app = builder.Build();
var bridge = new WorkerBridge(root, settings.PowerShell);
var state = new HostState(bridge, root);
var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
string origin = "";
var readyPath = Path.Combine(root, "Data", "web-ready.json");
SafeFiles.RequireDirect(readyPath);

bool HeaderAuthorized(HttpRequest request) => SafeFiles.EqualToken(request.Headers["X-Qa-Session"].ToString(), token);
bool Authorized(HttpRequest request) => HeaderAuthorized(request) || SafeFiles.EqualToken(request.Cookies["ctqa-session"], token);
bool SameOrigin(HttpRequest request) {
    if ($"http://{request.Host.Value}" != origin) return false;
    var supplied = request.Headers.Origin.ToString();
    if (supplied.Length > 0 && supplied != origin) return false;
    var site = request.Headers["Sec-Fetch-Site"].ToString();
    return site != "cross-site";
}

app.Use(async (context, next) => {
    if (!SameOrigin(context.Request)) { context.Response.StatusCode = 403; await context.Response.WriteAsJsonAsync(new { error = "Open the local CT QA Manager window to use this action." }); return; }
    context.Response.Headers.CacheControl = "no-store";
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors " + (context.Request.Path.StartsWithSegments("/api/pdf") ? "'self'" : "'none'");
    if (context.Request.Path.StartsWithSegments("/api") && !HeaderAuthorized(context.Request) && !Authorized(context.Request)) {
        context.Response.StatusCode = 401; await context.Response.WriteAsJsonAsync(new { error = "The local session expired. Reopen CT QA Manager." }); return;
    }
    if (context.Request.Path.StartsWithSegments("/api")) state.Touch();
    try { await next(context); }
    catch (BadHttpRequestException) { if (!context.Response.HasStarted) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "The request is incomplete or exceeds its size limit." }); } }
    catch (WorkerException ex) { if (!context.Response.HasStarted) { context.Response.StatusCode = 409; await context.Response.WriteAsJsonAsync(new { error = ex.Message }); } }
    catch (JsonException) { if (!context.Response.HasStarted) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "The application request is not valid JSON." }); } }
    catch (OperationCanceledException) { if (!context.Response.HasStarted) context.Response.StatusCode = 499; }
    catch (Exception) { if (!context.Response.HasStarted) { context.Response.StatusCode = 500; await context.Response.WriteAsJsonAsync(new { error = "The local action could not finish. Your saved reports remain available; export support logs if this repeats." }); } }
});

app.MapGet("/", () => Results.File(Path.Combine(root, "App", "Web", "index.html"), "text/html; charset=utf-8"));
app.MapGet("/app.css", () => Results.File(Path.Combine(root, "App", "Web", "app.css"), "text/css; charset=utf-8"));
app.MapGet("/app.js", () => Results.File(Path.Combine(root, "App", "Web", "app.js"), "application/javascript; charset=utf-8"));
app.MapGet("/favicon.ico", () => Results.NoContent());
app.MapPost("/api/session", (HttpContext context) => {
    if (!HeaderAuthorized(context.Request)) return Results.Unauthorized();
    context.Response.Cookies.Append("ctqa-session", token, new CookieOptions { HttpOnly = true, SameSite = SameSiteMode.Strict, IsEssential = true, Path = "/api", MaxAge = TimeSpan.FromHours(24) });
    return Results.Json(new { connected = true, version = "5.0.0" });
});
app.MapPost("/api/heartbeat", () => { state.Heartbeat(); return Results.Json(new { alive = true }); });
app.MapGet("/api/snapshot", () => state.Snapshot is JsonNode snapshot ? Results.Json(snapshot) : Results.Json(new { error = state.StartupError ?? "The saved library is loading. Please wait a moment." }, statusCode: 503));
app.MapGet("/api/jobs", () => Results.Json(new { jobs = state.Jobs.Values.OrderByDescending(j => j.StartedUtc).Take(100).Select(j => j.PublicView()) }));
app.MapPost("/api/actions", async (HttpContext context) => {
    context.Features.Get<IHttpMaxRequestBodySizeFeature>()!.MaxRequestBodySize = 2_097_152;
    var request = await JsonNode.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted) as JsonObject;
    var action = request?["action"] is JsonValue actionValue && actionValue.TryGetValue<string>(out var actionText) ? actionText : "";
    if (!HostState.AllowedActions.Contains(action)) return Results.BadRequest(new { error = "Choose a supported CT QA Manager action." });
    if (action is "Shutdown" or "OpenClassic") {
        if (state.Busy) return Results.Conflict(new { error = "Wait for the current action to finish before closing the program." });
        if (action == "OpenClassic") { if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "The original Windows interface requires Windows." }); LaunchClassic(root); }
        _ = Task.Run(async () => { await Task.Delay(1200); app.Lifetime.StopApplication(); });
        return Results.Json(new { shutdown = true });
    }
    if (action == "InstallPreparedUpdate" && state.Busy) return Results.Conflict(new { error = "Finish other actions before installing an update." });
    var job = state.Queue(request!, app.Lifetime.ApplicationStopping, result => {
        if (action != "InstallPreparedUpdate") return;
        var plan = result?["installUpdate"] as JsonObject ?? throw new InvalidOperationException("The checked update plan is missing.");
        LaunchUpdate(root, plan);
        _ = Task.Run(async () => { await Task.Delay(3000); app.Lifetime.StopApplication(); });
    });
    return Results.Json(new { id = job.Id }, statusCode: 202);
});
app.MapPost("/api/jobs/{id}/cancel", (string id) => {
    if (!state.Jobs.TryGetValue(id, out var job)) return Results.NotFound();
    job.Cancel.Cancel();
    return Results.Json(new { requested = true });
});
app.MapPost("/api/update", async (HttpContext context) => {
    if (!context.Request.HasFormContentType) return Results.BadRequest(new { error = "Choose one update ZIP file." });
    var form = await context.Request.ReadFormAsync(context.RequestAborted);
    var file = form.Files.GetFile("file");
    if (form.Files.Count != 1 || file is null || !file.FileName.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || file.Length < 1 || file.Length > 268_435_456)
        return Results.BadRequest(new { error = "Choose one update ZIP smaller than 256 MB." });
    var folder = SafeFiles.PrivateDirectory(Path.Combine(root, "Data", ".web-uploads"));
    var path = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".zip");
    try {
        await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) await file.CopyToAsync(output, context.RequestAborted);
        var job = state.Queue(new JsonObject { ["action"] = "PrepareUpdate", ["path"] = path, ["zipPath"] = path }, app.Lifetime.ApplicationStopping, null, path);
        return Results.Json(new { id = job.Id }, statusCode: 202);
    } catch { File.Delete(path); throw; }
});
app.MapGet("/api/pdf/{id}", async (string id, HttpContext context) => {
    if (!SafeFiles.ValidRecordId(id)) return Results.BadRequest(new { error = "Select a saved report." });
    var value = await bridge.Run(new JsonObject { ["action"] = "Pdf", ["id"] = id }, 90, context.RequestAborted);
    var path = value?["path"]?.GetValue<string>();
    if (path is null || !File.Exists(path) || Path.GetExtension(path) != ".pdf") return Results.NotFound(new { error = "The saved PDF is unavailable." });
    SafeFiles.RequireDirect(path);
    var archiveRoot = state.Snapshot?["archiveRoot"]?.GetValue<string>();
    if (archiveRoot is null || !SafeFiles.IsWithin(path, archiveRoot)) throw new InvalidOperationException("The PDF is outside the saved archive.");
    var name = value?["filename"]?.GetValue<string>() ?? "QA-report.pdf";
    name = Path.GetFileName(name.Replace('\\', '/'));
    name = new string(name.Where(c => !char.IsControl(c)).Take(180).ToArray());
    if (string.IsNullOrWhiteSpace(name)) name = "QA-report.pdf";
    context.Response.Headers["Content-Disposition"] = "inline; filename*=UTF-8''" + Uri.EscapeDataString(name);
    return Results.File(path, "application/pdf", enableRangeProcessing: true);
});
app.MapGet("/api/preview/{id}", async (string id, HttpContext context) => {
    if (!SafeFiles.ValidRecordId(id)) return Results.BadRequest(new { error = "Select a saved report." });
    var text = context.Request.Query["page"].ToString();
    if (!int.TryParse(text.Length == 0 ? "0" : text, out var page) || page is < 0 or > 99999)
        return Results.BadRequest(new { error = "Choose a valid PDF page." });
    var value = await bridge.Run(new JsonObject { ["action"] = "PreviewPdf", ["id"] = id, ["page"] = page }, 60, context.RequestAborted);
    return Results.Json(value);
});
app.MapGet("/api/download/{id}", (string id) => {
    if (!state.Downloads.TryGetValue(id, out var artifact) || !File.Exists(artifact.Path)) return Results.NotFound(new { error = "The saved download is no longer available." });
    SafeFiles.RequireDirect(artifact.Path);
    return Results.File(artifact.Path, "application/octet-stream", Path.GetFileName(artifact.Path), enableRangeProcessing: true);
});

await app.StartAsync();
origin = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single().TrimEnd('/');
// Kestrel starts on an OS-selected loopback port. No URL ACL, service or firewall rule is created.
var ready = JsonSerializer.Serialize(new { url = origin, token, pid = Environment.ProcessId, version = "5.0.0" });
SafeFiles.WritePrivate(readyPath, ready);
var browserStartup = Stopwatch.StartNew();
var startupFailed = 0;
Console.WriteLine("CT QA Manager is running locally. Close it using Settings when finished.");
if (!settings.NoBrowser) {
    try { Process.Start(new ProcessStartInfo(origin + "/#session=" + token) { UseShellExecute = true })?.Dispose(); }
    catch {
        await app.StopAsync();
        try { File.Delete(readyPath); } catch { }
        await app.DisposeAsync();
        throw new InvalidOperationException("The browser could not open. Check the workstation default browser or use Start CT QA Manager.cmd classic. No background session was left running.");
    }
}
_ = Task.Run(async () => {
    try {
        await state.LoadSnapshot(app.Lifetime.ApplicationStopping);
        if (state.Snapshot?["setupComplete"]?.GetValue<bool>() == true && state.Snapshot?["settings"]?["autoUpdateOnOpen"]?.GetValue<bool>() == true)
            state.Queue(new JsonObject { ["action"] = "Refresh" }, app.Lifetime.ApplicationStopping);
    }
    catch (Exception ex) { state.StartupError = ex is WorkerException ? ex.Message : "The saved workspace could not be opened. Check folder permissions or use the previous Windows interface."; }
});
_ = Task.Run(async () => {
    try {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
        while (await timer.WaitForNextTickAsync(app.Lifetime.ApplicationStopping)) {
            if (!settings.NoBrowser && state.LastHeartbeat == DateTimeOffset.MinValue && browserStartup.Elapsed > TimeSpan.FromSeconds(90)) {
                Interlocked.Exchange(ref startupFailed, 1);
                app.Lifetime.StopApplication();
                break;
            }
            var saved = state.Snapshot;
            if (!state.Busy && DateTimeOffset.UtcNow - state.LastHeartbeat < TimeSpan.FromSeconds(90) && saved?["setupComplete"]?.GetValue<bool>() == true) {
                var monitor = saved?["settings"]?["monitorMinutes"]?.GetValue<int>() ?? 0;
                if (monitor > 0 && DateTimeOffset.UtcNow - state.LastRefresh > TimeSpan.FromMinutes(monitor))
                    state.Queue(new JsonObject { ["action"] = "Refresh" }, app.Lifetime.ApplicationStopping);
                else if (saved?["settings"]?["autoAnalyze"]?.GetValue<bool>() == true && (saved?["analysis"]?["pending"]?.GetValue<int>() ?? 0) > 0 && DateTimeOffset.UtcNow - state.LastAnalysis > TimeSpan.FromMinutes(5))
                    state.Queue(new JsonObject { ["action"] = "Analyze" }, app.Lifetime.ApplicationStopping);
            }
            if (!state.Busy && DateTimeOffset.UtcNow - state.LastActivity > TimeSpan.FromMinutes(settings.IdleMinutes)) { app.Lifetime.StopApplication(); break; }
        }
    } catch (OperationCanceledException) { }
});
try { await app.WaitForShutdownAsync(); }
finally { state.Stop(); try { File.Delete(readyPath); } catch { } await app.DisposeAsync(); }
if (Volatile.Read(ref startupFailed) != 0)
    throw new InvalidOperationException("The browser did not connect to the local interface within 90 seconds. Check the default browser and workstation local-access policy, or use Start CT QA Manager.cmd classic. The background session was stopped.");

static void LaunchClassic(string root) {
    var classic = Path.Combine(root, "App", "Start.ps1"); SafeFiles.RequireDirect(classic);
    var script = "$ErrorActionPreference='Stop';$p=Get-Process -Id " + Environment.ProcessId + " -ErrorAction SilentlyContinue;if($null -ne $p){$p.WaitForExit()}; & '" + classic.Replace("'", "''") + "' -PortableLaunch";
    var info = new ProcessStartInfo(HostOptions.DefaultPowerShell()) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root };
    foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-STA", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) info.ArgumentList.Add(argument);
    Process.Start(info)?.Dispose();
}

static void LaunchUpdate(string root, JsonObject plan) {
    var source = Path.GetFullPath(plan["sourceFolder"]?.GetValue<string>() ?? "");
    var target = Path.GetFullPath(plan["targetFolder"]?.GetValue<string>() ?? "");
    var stage = Path.GetFullPath(plan["stageRoot"]?.GetValue<string>() ?? "");
    if (!SafeFiles.SamePath(target, root) || !SafeFiles.SamePath(Path.GetDirectoryName(stage)!, root) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(stage), @"^\.pending-update-[0-9a-f]{32}$") || !SafeFiles.SamePath(source, Path.Combine(stage, "Package")))
        throw new InvalidOperationException("The checked update does not belong to this program folder.");
    SafeFiles.RequireDirect(source);
    if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Installing an update requires Windows.");
    string Quote(string value) => "'" + value.Replace("'", "''") + "'";
    var script = "$ErrorActionPreference='Stop';$p=Get-Process -Id " + Environment.ProcessId + " -ErrorAction SilentlyContinue;if($null -ne $p){$p.WaitForExit()}; & " + Quote(Path.Combine(root, "App", "Upgrade.ps1")) + " -SourceFolder " + Quote(source) + " -TargetFolder " + Quote(root) + " -WaitForApp -LaunchAfter -StageRoot " + Quote(stage);
    var info = new ProcessStartInfo(HostOptions.DefaultPowerShell()) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root };
    foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-STA", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) info.ArgumentList.Add(argument);
    Process.Start(info)?.Dispose();
}

sealed class HostOptions {
    public string Root { get; private set; } = Directory.GetCurrentDirectory();
    public string PowerShell { get; private set; } = DefaultPowerShell();
    public int Port { get; private set; }
    public bool NoBrowser { get; private set; }
    public int IdleMinutes { get; private set; } = 30;
    public static string DefaultPowerShell() => OperatingSystem.IsWindows() ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe") : "pwsh";
    public static HostOptions Parse(string[] args) {
        var options = new HostOptions();
        for (var i = 0; i < args.Length; i++) {
            string Value() => ++i < args.Length ? args[i] : throw new ArgumentException("A launcher option is missing its value.");
            switch (args[i]) {
                case "--root": options.Root = Value(); break;
                case "--powershell": options.PowerShell = Value(); break;
                case "--port": options.Port = int.Parse(Value()); break;
                case "--idle-minutes": options.IdleMinutes = int.Parse(Value()); break;
                case "--no-browser": options.NoBrowser = true; break;
                default: throw new ArgumentException("Unsupported launcher option.");
            }
        }
        if (options.Port is < 0 or > 65535 || options.IdleMinutes is < 1 or > 1440) throw new ArgumentException("Invalid local host limits.");
        return options;
    }
}
sealed class WorkerException(string message) : Exception(message);
sealed class WorkerBridge(string root, string powerShell) {
    public async Task<JsonNode?> Run(JsonObject request, int timeoutSeconds, CancellationToken cancellationToken) {
        var info = new ProcessStartInfo(powerShell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false), WorkingDirectory = root };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile" }) info.ArgumentList.Add(arg);
        if (OperatingSystem.IsWindows()) info.ArgumentList.Add("-STA");
        foreach (var arg in new[] { "-File", Path.Combine(root, "App", "WebWorker.ps1"), "-AppRoot", root, "-InputPath", "stdin", "-OutputPath", "stdout" }) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new WorkerException("Windows could not start the local file helper. Check workstation policy.");
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try {
            await process.StandardInput.WriteAsync(request.ToJsonString().AsMemory(), timeout.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token);
            var output = await outputTask; await errorTask; // Drain error output without storing raw helper text in logs.
            JsonNode? envelope;
            try { envelope = JsonNode.Parse(output.TrimStart('\uFEFF')); }
            catch (JsonException) { throw new WorkerException("The local helper did not return a complete result. Check workstation policy or export support logs."); }
            if (envelope?["success"]?.GetValue<bool>() != true) {
                var error = envelope?["error"];
                throw new WorkerException(error is JsonObject ? error["message"]?.GetValue<string>() ?? "The action could not finish." : error?.ToString() ?? "The action could not finish.");
            }
            return envelope["value"]?.DeepClone();
        } catch (OperationCanceledException) {
            try { process.Kill(entireProcessTree: true); } catch { }
            throw new WorkerException(cancellationToken.IsCancellationRequested ? "The action was cancelled. Saved reports remain preserved." : "The local action timed out. Saved reports remain available; retry when the scanner is accessible.");
        } finally { if (!process.HasExited) { try { process.Kill(entireProcessTree: true); } catch { } } }
    }
}
sealed class Job(string action) {
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string Action { get; } = action;
    public DateTimeOffset StartedUtc { get; } = DateTimeOffset.UtcNow;
    public string Status { get; set; } = "queued";
    public string Message { get; set; } = "Waiting for the current safe step…";
    public JsonNode? Result { get; set; }
    public string? Error { get; set; }
    public CancellationTokenSource Cancel { get; } = new();
    public object PublicView() => new { id = Id, action = Action, status = Status, message = Message, result = Result, error = Error, startedUtc = StartedUtc };
}
sealed record Download(string Path);
sealed class HostState(WorkerBridge bridge, string root) {
    public static readonly HashSet<string> AllowedActions = new(StringComparer.Ordinal) { "Refresh", "Approve", "Disapprove", "Undo", "Reconnect", "Settings", "ApplyProfile", "Export", "Analyze", "Backup", "Restore", "Diagnostics", "Browse", "PickArchive", "ScannerSettings", "Audit", "InstallPreparedUpdate", "Shutdown", "OpenClassic" };
    public readonly ConcurrentDictionary<string, Job> Jobs = new();
    public readonly ConcurrentDictionary<string, Download> Downloads = new();
    private readonly SemaphoreSlim mutation = new(1, 1);
    private readonly CancellationTokenSource shutdown = new();
    private JsonNode? snapshot;
    private long lastActivity = DateTimeOffset.UtcNow.UtcTicks;
    private long lastHeartbeat = DateTimeOffset.MinValue.UtcTicks;
    public JsonNode? Snapshot => Volatile.Read(ref snapshot);
    public string? StartupError { get; set; }
    public DateTimeOffset LastRefresh { get; private set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastAnalysis { get; private set; } = DateTimeOffset.MinValue;
    public DateTimeOffset LastHeartbeat => new(Interlocked.Read(ref lastHeartbeat), TimeSpan.Zero);
    public void Heartbeat() { Interlocked.Exchange(ref lastHeartbeat, DateTimeOffset.UtcNow.UtcTicks); Touch(); }
    public DateTimeOffset LastActivity => new(Interlocked.Read(ref lastActivity), TimeSpan.Zero);
    public bool Busy => Jobs.Values.Any(j => j.Status is "queued" or "running");
    public void Touch() => Interlocked.Exchange(ref lastActivity, DateTimeOffset.UtcNow.UtcTicks);
    public void Stop() => shutdown.Cancel();
    public async Task LoadSnapshot(CancellationToken token) {
        var value = await bridge.Run(new JsonObject { ["action"] = "Snapshot" }, 90, token);
        if (value is null) throw new WorkerException("The saved workspace returned an empty result.");
        Volatile.Write(ref snapshot, (value["snapshot"] ?? value).DeepClone()); StartupError = null;
    }
    public Job Queue(JsonObject request, CancellationToken hostToken, Action<JsonNode?>? completed = null, string? cleanupPath = null) {
        if (Jobs.Values.Count(j => j.Status is "queued" or "running") >= 32) throw new WorkerException("The action queue is full. Wait for existing work to finish.");
        foreach (var old in Jobs.Values.Where(j => j.Status is "completed" or "failed" or "cancelled").OrderByDescending(j => j.StartedUtc).Skip(80)) { if (Jobs.TryRemove(old.Id, out var removed)) removed.Cancel.Dispose(); }
        var action = request["action"]!.GetValue<string>();
        var job = new Job(action); Jobs[job.Id] = job;
        if (action == "Refresh") LastRefresh = DateTimeOffset.UtcNow;
        if (action == "Analyze") LastAnalysis = DateTimeOffset.UtcNow;
        _ = Task.Run(async () => {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(hostToken, shutdown.Token, job.Cancel.Token);
            var entered = false; var timer = Stopwatch.StartNew();
            try {
                await mutation.WaitAsync(linked.Token); entered = true;
                job.Status = "running"; job.Message = MessageFor(action);
                var result = await bridge.Run(request, action is "Refresh" or "Backup" or "Restore" or "Analyze" or "Export" ? 1800 : 120, linked.Token);
                completed?.Invoke(result);
                if (result?["snapshot"] is JsonNode nextSnapshot) Volatile.Write(ref snapshot, nextSnapshot.DeepClone());
                else if (action != "InstallPreparedUpdate") await LoadSnapshot(linked.Token);
                var published = result?.DeepClone();
                if (published is JsonObject obj) {
                    obj.Remove("snapshot"); obj.Remove("installUpdate"); obj.Remove("stageRoot"); obj.Remove("sourceFolder"); obj.Remove("targetFolder");
                    if (obj["path"] is JsonValue pathValue && pathValue.TryGetValue<string>(out var filePath) && File.Exists(filePath)) {
                        SafeFiles.RequireDirect(filePath);
                        if (new[] { "Exports", "Backups", "Logs" }.Any(area => SafeFiles.IsWithin(filePath, Path.Combine(root, area)))) {
                            var artifactId = Guid.NewGuid().ToString("N"); Downloads[artifactId] = new Download(filePath); obj["downloadUrl"] = "/api/download/" + artifactId;
                        }
                        obj.Remove("path");
                    }
                    if (action == "InstallPreparedUpdate") obj["shutdown"] = true;
                }
                job.Result = published; job.Status = "completed"; job.Message = "Finished";
                WriteActivity(action, "Completed", timer.ElapsedMilliseconds);
            } catch (Exception ex) {
                job.Status = job.Cancel.IsCancellationRequested ? "cancelled" : "failed";
                job.Error = ex is WorkerException ? ex.Message : ex is OperationCanceledException ? "The action was cancelled safely." : "The action could not finish. Export support logs if this repeats.";
                job.Message = job.Error; WriteActivity(action, "Failed", timer.ElapsedMilliseconds);
            } finally {
                request.Clear(); // Includes transient password fields. Never retain request payloads in job history.
                if (entered) mutation.Release();
                if (cleanupPath is not null) { try { File.Delete(cleanupPath); } catch { } }
            }
        });
        return job;
    }
    private void WriteActivity(string action, string outcome, long duration) {
        try {
            var path = Path.Combine(root, "Logs", "Web", "activity.jsonl"); Directory.CreateDirectory(Path.GetDirectoryName(path)!); SafeFiles.RequireDirect(path);
            if (File.Exists(path) && new FileInfo(path).Length > 1_048_576) File.Move(path, path + ".previous", true);
            File.AppendAllText(path, JsonSerializer.Serialize(new { timeUtc = DateTimeOffset.UtcNow, action, outcome, durationMs = duration }) + Environment.NewLine, new UTF8Encoding(false));
        } catch { }
    }
    private static string MessageFor(string action) => action switch { "Refresh" => "Checking scanners and collecting new reports…", "Approve" or "Disapprove" => "Saving the file decision…", "Export" => "Preparing the report package…", "Backup" => "Creating a verified backup…", "Restore" => "Choose a backup ZIP and a new destination in the Windows dialogs…", "Analyze" => "Reading new or changed PDF text…", "Reconnect" => "Testing the selected scanner connection…", "PrepareUpdate" => "Checking the update ZIP…", _ => "Working on your request…" };
}
static class SafeFiles {
    public static bool EqualToken(string? supplied, string token) {
        if (supplied is null || supplied.Length != token.Length) return false;
        return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(supplied), Encoding.ASCII.GetBytes(token));
    }
    public static bool ValidRecordId(string value) => value.Length == 64 && value.All(Uri.IsHexDigit);
    public static bool SamePath(string one, string two) => Path.GetFullPath(one).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Equals(Path.GetFullPath(two).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    public static bool IsWithin(string path, string folder) => Path.GetFullPath(path).StartsWith(Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    public static void RequireDirect(string path) {
        for (var current = Path.GetFullPath(path); current.Length > 0; current = Path.GetDirectoryName(current) ?? "")
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Use a direct program folder, without links or junctions.");
    }
    public static string PrivateDirectory(string path) {
        RequireDirect(path); Directory.CreateDirectory(path);
        if (OperatingSystem.IsWindows()) {
            var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(security);
        } else File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }
    public static void WritePrivate(string path, string content) {
        RequireDirect(path);
        using (new FileStream(path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None)) { }
        if (OperatingSystem.IsWindows()) {
            var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl, AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(security);
        } else File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }
}
