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
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; frame-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors " + (context.Request.Path.StartsWithSegments("/api/pdf") ? "'self'" : "'none'");
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
app.MapGet("/trends.js", () => Results.File(Path.Combine(root, "App", "Web", "trends.js"), "application/javascript; charset=utf-8"));
app.MapGet("/favicon.ico", () => Results.NoContent());
app.MapPost("/api/session", (HttpContext context) => {
    if (!HeaderAuthorized(context.Request)) return Results.Unauthorized();
    context.Response.Cookies.Append("ctqa-session", token, new CookieOptions { HttpOnly = true, SameSite = SameSiteMode.Strict, IsEssential = true, Path = "/api", MaxAge = TimeSpan.FromHours(24) });
    return Results.Json(new { connected = true, version = "5.7.8" });
});
app.MapPost("/api/heartbeat", () => { state.Heartbeat(); return Results.Json(new { alive = true }); });
app.MapGet("/api/snapshot", () => state.Snapshot is JsonNode snapshot ? Results.Json(snapshot) : Results.Json(new { error = state.StartupError ?? "The saved library is loading. Please wait a moment." }, statusCode: 503));
app.MapGet("/api/jobs", () => Results.Json(new { jobs = state.Jobs.Values.OrderByDescending(j => j.StartedUtc).Take(100).Select(j => j.PublicView()), automaticReadingStopped = state.AutomaticReadingStopped }));
app.MapPost("/api/actions", async (HttpContext context) => {
    context.Features.Get<IHttpMaxRequestBodySizeFeature>()!.MaxRequestBodySize = 2_097_152;
    var request = await JsonNode.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted) as JsonObject;
    var action = request?["action"] is JsonValue actionValue && actionValue.TryGetValue<string>(out var actionText) ? actionText : "";
    if (!HostState.AllowedActions.Contains(action)) return Results.BadRequest(new { error = "Choose a supported CT QA Manager action." });
    if (action is "Shutdown" or "OpenClassic") {
        if (action == "Shutdown" ? !state.TryBeginShutdown() : state.Busy) return Results.Conflict(new { error = "Wait for the current action to finish before closing the program." });
        if (action == "OpenClassic") { if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "The original Windows interface requires Windows." }); LaunchClassic(root); }
        _ = Task.Run(async () => { if (action == "Shutdown") await state.WaitForBackgroundStop(); await Task.Delay(1200); app.Lifetime.StopApplication(); });
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
    if (!state.RequestJobCancellation(job)) return Results.Conflict(new { error = "This step is already finishing or must finish atomically." });
    if (job.Background) state.RecordReadingControl("UserStopped");
    return Results.Json(new { cancelRequested = true });
});
app.MapPost("/api/jobs/{id}/pause", async (string id, HttpContext context) => {
    context.Features.Get<IHttpMaxRequestBodySizeFeature>()!.MaxRequestBodySize = 1024;
    if (!state.Jobs.TryGetValue(id, out var job)) return Results.NotFound();
    var request = await JsonNode.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted) as JsonObject;
    if (request?["paused"] is not JsonValue value || !value.TryGetValue<bool>(out var paused)) return Results.BadRequest(new { error = "Choose Pause or Resume for background reading." });
    if (!job.RequestPause(paused)) return Results.Conflict(new { error = "This background reading job has already finished." });
    state.RecordReadingControl(paused ? "UserPaused" : "UserResumed");
    if (!paused) state.NoteReadingResume();
    return Results.Json(new { pauseRequested = paused, paused = job.Paused });
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
app.MapGet("/api/monthly", async (HttpContext context) => {
    var month = context.Request.Query["month"].ToString();
    if (month.Length != 7 || !DateOnly.TryParseExact(month + "-01", "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out _))
        return Results.BadRequest(new { error = "Choose a valid month in YYYY-MM format." });
    return Results.Json(await bridge.Run(new JsonObject { ["action"] = "Monthly", ["month"] = month }, 90, context.RequestAborted));
});
app.MapGet("/api/trends", async (HttpContext context) => {
    var request = new JsonObject { ["action"] = "Trends" };
    foreach (var name in new[] { "scanner", "metric", "mode", "system", "slice", "start", "end", "series" }) {
        var value = context.Request.Query[name].ToString();
        if (value.Length > 128) return Results.BadRequest(new { error = "Choose a shorter trend filter." });
        if (value.Length > 0) request[name] = value;
    }
    return Results.Json(await bridge.Run(request, 90, context.RequestAborted));
});
app.MapGet("/api/preview/{id}", async (string id, HttpContext context) => {
    if (!SafeFiles.ValidRecordId(id)) return Results.BadRequest(new { error = "Select a saved report." });
    var text = context.Request.Query["page"].ToString();
    if (!int.TryParse(text.Length == 0 ? "0" : text, out var page) || page is < 0 or > 99999)
        return Results.BadRequest(new { error = "Choose a valid PDF page." });
    var value = await bridge.Run(new JsonObject { ["action"] = "PreviewPdf", ["id"] = id, ["page"] = page }, 60, context.RequestAborted);
    return Results.Json(value);
});
app.MapGet("/api/download/{id}", (string id, HttpContext context) => {
    if (!state.Downloads.TryGetValue(id, out var artifact) || !File.Exists(artifact.Path)) return Results.NotFound(new { error = "The saved download is no longer available." });
    SafeFiles.RequireDirect(artifact.Path);
    if (Path.GetExtension(artifact.Path).Equals(".html", StringComparison.OrdinalIgnoreCase) && SafeFiles.IsWithin(artifact.Path, Path.Combine(root, "Logs", "Support"))) {
        context.Response.Headers["Content-Security-Policy"] = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
        context.Response.Headers["Content-Disposition"] = "inline";
        return Results.File(artifact.Path, "text/html; charset=utf-8", enableRangeProcessing: true);
    }
    return Results.File(artifact.Path, "application/octet-stream", Path.GetFileName(artifact.Path), enableRangeProcessing: true);
});

await app.StartAsync();
state.RecordLifecycle("Startup", "Started");
app.Lifetime.ApplicationStopped.Register(() => state.RecordLifecycle("Shutdown", "Completed"));
origin = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single().TrimEnd('/');
// Kestrel starts on an OS-selected loopback port. No URL ACL, service or firewall rule is created.
var ready = JsonSerializer.Serialize(new { url = origin, token, pid = Environment.ProcessId, version = "5.7.8" });
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
            state.QueueWhenIdle(new JsonObject { ["action"] = "Refresh" }, app.Lifetime.ApplicationStopping, automatic: true);
        else state.TryQueueAutomaticAnalysis(app.Lifetime.ApplicationStopping);
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
            if (!state.ForegroundBusy && DateTimeOffset.UtcNow - state.LastHeartbeat < TimeSpan.FromSeconds(90) && saved?["setupComplete"]?.GetValue<bool>() == true) {
                var monitor = saved?["settings"]?["monitorMinutes"]?.GetValue<int>() ?? 0;
                if (monitor > 0 && DateTimeOffset.UtcNow - state.LastRefresh > TimeSpan.FromMinutes(monitor))
                    state.QueueWhenIdle(new JsonObject { ["action"] = "Refresh" }, app.Lifetime.ApplicationStopping);
                else state.TryQueueAutomaticAnalysis(app.Lifetime.ApplicationStopping);
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
sealed class WorkerException(string message, bool pdfReadDeadline = false) : Exception(message) { public bool PdfReadDeadline { get; } = pdfReadDeadline; }
sealed class WorkerBridge(string root, string powerShell) {
    public async Task<JsonNode?> Run(JsonObject request, int timeoutSeconds, CancellationToken cancellationToken, Job? progressJob = null, bool isolatedPdfRead = false) {
        if (isolatedPdfRead) timeoutSeconds = Math.Min(timeoutSeconds, 90);
        var helperClock = Stopwatch.StartNew();
        var info = new ProcessStartInfo(powerShell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false), WorkingDirectory = root };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile" }) info.ArgumentList.Add(arg);
        if (OperatingSystem.IsWindows()) info.ArgumentList.Add("-STA");
        foreach (var arg in new[] { "-File", Path.Combine(root, "App", "WebWorker.ps1"), "-AppRoot", root, "-InputPath", "stdin", "-OutputPath", "stdout" }) info.ArgumentList.Add(arg);
        if (isolatedPdfRead) info.ArgumentList.Add("-IsolatedPdfRead");
        if (progressJob?.ProgressPath is string progressPath) {
            info.ArgumentList.Add("-ProgressPath"); info.ArgumentList.Add(progressPath);
            info.ArgumentList.Add("-CancelPath"); info.ArgumentList.Add(progressJob.CancelPath!);
        }
        using var process = Process.Start(info) ?? throw new WorkerException("Windows could not start the local file helper. Check workstation policy.");
        progressJob?.CountWorkerStart();
        if (progressJob?.Background == true) { try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { /* Policy may deny a priority hint; correctness does not depend on it. */ } }
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
            if (isolatedPdfRead && envelope["value"] is JsonObject response && response["result"] is JsonObject result && result["Performance"] is JsonObject performance && performance["InlinePdfReads"] is JsonValue observed && observed.TryGetValue<long>(out var inlineReads) && inlineReads is >= 0 and <= 1)
                progressJob?.CountInlinePdfReads(inlineReads);
            return envelope["value"]?.DeepClone();
        } catch (OperationCanceledException) {
            if (isolatedPdfRead && !cancellationToken.IsCancellationRequested) {
                progressJob?.RequestCancel();
                try { process.Kill(entireProcessTree: true); } catch { }
                throw new WorkerException("This PDF reached its 90-second reading limit. Its isolated helper was stopped; completed readings remain saved. Automatic reading is paused until you choose to retry.", pdfReadDeadline: true);
            }
            if (!cancellationToken.IsCancellationRequested && progressJob?.Cancellable == true) {
                progressJob.RequestCancel();
                using var grace = new CancellationTokenSource(TimeSpan.FromSeconds(90));
                try {
                    await process.WaitForExitAsync(grace.Token);
                    throw new WorkerException("The local action reached its time limit and stopped at a safe checkpoint. Completed reports remain saved; retry when the scanner is accessible.");
                } catch (OperationCanceledException) { }
            }
            try { process.Kill(entireProcessTree: true); } catch { }
            throw new WorkerException(cancellationToken.IsCancellationRequested ? "The local session stopped. Completed reports remain saved; interrupted staging is checked on the next update." : "The local action timed out while waiting for Windows. The unresponsive helper was stopped; completed reports remain saved and interrupted staging is checked on the next update.");
        } finally { progressJob?.CountWorkerElapsed(helperClock.ElapsedMilliseconds, isolatedPdfRead); if (!process.HasExited) { try { process.Kill(entireProcessTree: true); } catch { } } }
    }
}
sealed class Job(string action, bool background = false, bool automatic = false) {
    private static readonly HashSet<string> CooperativeActions = new(StringComparer.Ordinal) { "Refresh", "Analyze", "AnalyzeBacklog", "Export", "Backup", "Audit", "Browse" };
    private static readonly HashSet<string> Stages = new(StringComparer.Ordinal) { "Preparing", "Connecting", "Scanning", "Copying", "Library", "Analyzing", "Exporting", "BackingUp", "Restoring", "Verifying", "Finishing", "Planning", "Snapshot", "Parsing", "Cache" };
    private readonly object progressLock = new();
    private bool cancelRequested, pauseRequested, paused, atBoundary;
    private string stage = "Preparing";
    private long completed, total, copied, unchanged, failed;
    private double percent = -1;
    private long finishedTicks;
    private long planBuilds, fullSnapshots, librarySyncs, processedReports, cacheSkips;
    private long workerStarts, inlinePdfReads, helperMilliseconds, readWorkerMilliseconds, planningMilliseconds, snapshotMilliseconds;
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string Action { get; } = action;
    public bool Background { get; } = background;
    public bool Automatic { get; } = automatic;
    public void CountPlan(long milliseconds = 0) { Interlocked.Increment(ref planBuilds); Interlocked.Add(ref planningMilliseconds, Math.Max(0, milliseconds)); }
    public void CountSnapshot(long milliseconds = 0) { Interlocked.Increment(ref fullSnapshots); Interlocked.Add(ref snapshotMilliseconds, Math.Max(0, milliseconds)); }
    public void CountLibrarySync() => Interlocked.Increment(ref librarySyncs);
    public void CountProcessed(long count) => Interlocked.Add(ref processedReports, count);
    public void CountSkipped(long count) => Interlocked.Add(ref cacheSkips, count);
    public long PlanBuildCount => Interlocked.Read(ref planBuilds);
    public long FullSnapshotCount => Interlocked.Read(ref fullSnapshots);
    public long LibrarySyncCount => Interlocked.Read(ref librarySyncs);
    public long ProcessedCount => Interlocked.Read(ref processedReports);
    public long CacheSkipCount => Interlocked.Read(ref cacheSkips);
    public void CountWorkerStart() => Interlocked.Increment(ref workerStarts);
    public void CountInlinePdfReads(long count) { if (count is >= 0 and <= 1) Interlocked.Add(ref inlinePdfReads, count); }
    public void CountWorkerElapsed(long milliseconds, bool inlinePdfRead) { Interlocked.Add(ref helperMilliseconds, Math.Max(0, milliseconds)); if (inlinePdfRead) Interlocked.Add(ref readWorkerMilliseconds, Math.Max(0, milliseconds)); }
    public long WorkerStartCount => Interlocked.Read(ref workerStarts);
    public long InlinePdfReadCount => Interlocked.Read(ref inlinePdfReads);
    public long HelperMilliseconds => Interlocked.Read(ref helperMilliseconds);
    public long ReadWorkerMilliseconds => Interlocked.Read(ref readWorkerMilliseconds);
    public long PlanningMilliseconds => Interlocked.Read(ref planningMilliseconds);
    public long SnapshotMilliseconds => Interlocked.Read(ref snapshotMilliseconds);
    public object PerformanceView() => new { planBuilds = Interlocked.Read(ref planBuilds), fullSnapshots = Interlocked.Read(ref fullSnapshots), librarySyncs = Interlocked.Read(ref librarySyncs), processedReports = Interlocked.Read(ref processedReports), cacheSkips = Interlocked.Read(ref cacheSkips), workerStarts = WorkerStartCount, inlinePdfReads = InlinePdfReadCount, helperMilliseconds = HelperMilliseconds, readWorkerMilliseconds = ReadWorkerMilliseconds, planningMilliseconds = PlanningMilliseconds, snapshotMilliseconds = SnapshotMilliseconds };
    public DateTimeOffset StartedUtc { get; } = DateTimeOffset.UtcNow;
    public string Status { get; set; } = "queued";
    public string Message { get; set; } = "Waiting for the current safe step…";
    public JsonNode? Result { get; set; }
    public string? Error { get; set; }
    public CancellationTokenSource Cancel { get; } = new();
    public string? ProgressPath { get; private set; }
    public string? CancelPath { get; private set; }
    public bool CancelRequested { get { lock (progressLock) return cancelRequested; } }
    public bool PauseRequested { get { lock (progressLock) return pauseRequested; } }
    public bool Paused { get { lock (progressLock) return paused; } }
    public bool Cancellable => Status == "queued" || (Status == "running" && CooperativeActions.Contains(Action));
    public void PrepareProgress(string root) {
        lock (progressLock) {
            var directory = SafeFiles.PrivateDirectory(Path.Combine(root, "Data", ".web-jobs", Id));
            ProgressPath = Path.Combine(directory, "progress.json"); CancelPath = Path.Combine(directory, "cancel");
            if (cancelRequested) File.WriteAllText(CancelPath, "", new UTF8Encoding(false));
        }
    }
    public bool RequestPause(bool value) {
        lock (progressLock) {
            if (!Background || Status is not ("queued" or "running") || cancelRequested) return false;
            pauseRequested = value;
            return true;
        }
    }
    public void SetBoundary(bool waiting, bool blockedByForeground = false) {
        lock (progressLock) {
            atBoundary = waiting;
            paused = waiting && (pauseRequested || blockedByForeground);
            if (paused) { stage = "Paused"; Message = pauseRequested ? "Background reading paused. Completed readings are saved." : "Background reading is waiting for your current action…"; }
            else if (waiting) { stage = "Preparing"; Message = "Background reading is yielding between PDFs…"; }
            else {
                stage = "Analyzing"; Message = "Reading PDFs in the background, one at a time…";
                // A previous chunk's final progress must not appear as the next PDF's progress.
                if (ProgressPath is not null) { try { File.Delete(ProgressPath); } catch { } }
            }
        }
    }
    public void SetBackgroundProgress(long analyzed, long errors, long pending, long cached) {
        lock (progressLock) {
            completed = analyzed + errors; failed = errors; unchanged = cached;
            total = Action == "AnalyzeBacklog" ? completed + pending : Math.Min(20, completed + pending);
            percent = total > 0 ? Math.Clamp(100.0 * completed / total, 0, 100) : 100;
        }
    }
    public bool RequestCancel() {
        lock (progressLock) {
            if (!Cancellable) return false;
            cancelRequested = true;
            Cancel.Cancel(); // Waiting slots use the token; a running PDF stops through the safe marker.
            if (CancelPath is not null) File.WriteAllText(CancelPath, "", new UTF8Encoding(false));
            return true;
        }
    }
    public void ReadProgress() {
        lock (progressLock) {
            if (ProgressPath is null || !File.Exists(ProgressPath)) return;
            try {
                SafeFiles.RequireDirect(ProgressPath);
                using var input = new FileStream(ProgressPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (input.Length > 16384) return;
                using var reader = new StreamReader(input);
                var data = JsonNode.Parse(reader.ReadToEnd());
                var nextStage = data?["stage"]?.GetValue<string>();
                if (!atBoundary && nextStage is not null && Stages.Contains(nextStage)) stage = nextStage;
                // Background counters describe the overall job, never the latest 1/1 chunk.
                if (Background) return;
                long Number(string name) => data?[name] is JsonValue v && v.TryGetValue<long>(out var n) && n >= 0 && n <= 100_000_000 ? n : 0;
                completed = Number("completed"); total = Number("total"); copied = Number("copied"); unchanged = Number("unchanged"); failed = Number("failed");
                if (total > 0) completed = Math.Min(completed, total);
                if (data?["percent"] is JsonValue value && value.TryGetValue<double>(out var nextPercent) && double.IsFinite(nextPercent)) percent = Math.Clamp(nextPercent, -1, 100);
            } catch (IOException) { } catch (JsonException) { } catch (InvalidOperationException) { }
        }
    }
    public long ElapsedSeconds { get { var end = Interlocked.Read(ref finishedTicks); if (end <= 0) end = DateTimeOffset.UtcNow.UtcTicks; return (long)Math.Max(0, (new DateTimeOffset(end, TimeSpan.Zero) - StartedUtc).TotalSeconds); } }
    public void MarkFinished() { lock (progressLock) { paused = false; pauseRequested = false; if (Status == "completed") stage = "Finishing"; } Interlocked.Exchange(ref finishedTicks, DateTimeOffset.UtcNow.UtcTicks); }
    public void CleanupProgress() {
        ReadProgress();
        lock (progressLock) {
            if (ProgressPath is not null) { try { Directory.Delete(Path.GetDirectoryName(ProgressPath)!, true); } catch { } }
            ProgressPath = null; CancelPath = null;
        }
    }
    public object SupportView() {
        lock (progressLock) return new { action = Action switch { "Analyze" or "AnalyzeBacklog" => "Analysis", "Refresh" => "Update", "Approve" or "Disapprove" or "Undo" => "Reclassify", "ScannerSettings" or "ApplyProfile" => "Settings", "Browse" => "BrowseRefresh", _ => Action }, status = paused ? "Paused" : char.ToUpperInvariant(Status[0]) + Status[1..], stage, completed, total, failed, background = Background, pauseRequested, cancelRequested };
    }
    public object PublicView() {
        ReadProgress();
        lock (progressLock) return new { id = Id, action = Action, status = Status, message = cancelRequested && Status == "running" ? "Cancel requested. Waiting for the current Windows read or safe checkpoint…" : Message, result = Result, error = Error, startedUtc = StartedUtc, stage = Status == "queued" ? "Queued" : stage, completed, total, copied, unchanged, failed, percent = percent >= 0 ? (double?)percent : null, elapsedSeconds = ElapsedSeconds, cancellable = Cancellable && !cancelRequested, cancelRequested, background = Background, automatic = Automatic, performance = PerformanceView(), pausable = Background && (Status is "queued" or "running") && !cancelRequested, paused, pauseRequested };
    }
}
sealed record Download(string Path);
sealed class HostState(WorkerBridge bridge, string root) {
    public static readonly HashSet<string> AllowedActions = new(StringComparer.Ordinal) { "Refresh", "Approve", "Disapprove", "Undo", "Reconnect", "Settings", "ApplyProfile", "Export", "Analyze", "AnalyzeBacklog", "Backup", "Restore", "Diagnostics", "PrintDiagnostics", "Browse", "PickArchive", "ScannerSettings", "Audit", "InstallPreparedUpdate", "Shutdown", "OpenClassic" };
    public readonly ConcurrentDictionary<string, Job> Jobs = new();
    public readonly ConcurrentDictionary<string, Download> Downloads = new();
    private readonly SemaphoreSlim mutation = new(1, 1);
    private readonly object queueGate = new();
    private readonly CancellationTokenSource shutdown = new();
    private bool closing, automaticReadingStopped;
    private long foregroundRevision, libraryRevision;
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
    public bool AutomaticReadingStopped { get { lock (queueGate) return automaticReadingStopped; } }
    public bool ForegroundBusy => Jobs.Values.Any(j => !j.Background && (j.Status is "queued" or "running"));
    public bool TryBeginShutdown() {
        lock (queueGate) {
            if (ForegroundBusy) return false;
            closing = true;
            foreach (var job in Jobs.Values.Where(j => j.Background && (j.Status is "queued" or "running"))) job.RequestCancel();
            return true;
        }
    }
    public async Task WaitForBackgroundStop() {
        var timer = Stopwatch.StartNew();
        while (Busy && timer.Elapsed < TimeSpan.FromSeconds(185)) await Task.Delay(100);
    }
    public void Touch() => Interlocked.Exchange(ref lastActivity, DateTimeOffset.UtcNow.UtcTicks);
    public void Stop() => shutdown.Cancel();
    public async Task LoadSnapshot(CancellationToken token, Job? progressJob = null) {
        var value = await bridge.Run(new JsonObject { ["action"] = "Snapshot" }, 90, token, progressJob);
        if (value is null) throw new WorkerException("The saved workspace returned an empty result.");
        Volatile.Write(ref snapshot, (value["snapshot"] ?? value).DeepClone()); StartupError = null;
    }
    public bool RequestJobCancellation(Job job) {
        lock (queueGate) {
            var accepted = job.RequestCancel();
            if (accepted && job.Background) automaticReadingStopped = true;
            return accepted;
        }
    }
    public void NoteReadingResume() { lock (queueGate) automaticReadingStopped = false; }
    public void TryQueueAutomaticAnalysis(CancellationToken hostToken) {
        lock (queueGate) {
            if (closing || hostToken.IsCancellationRequested || automaticReadingStopped || Busy) return;
            var saved = Snapshot;
            if (saved?["setupComplete"]?.GetValue<bool>() != true || saved?["settings"]?["autoAnalyze"]?.GetValue<bool>() != true) return;
            var pending = saved?["analysis"]?["backlogPending"]?.GetValue<int>() ?? saved?["analysis"]?["pending"]?.GetValue<int>() ?? 0;
            if (pending <= 0 || DateTimeOffset.UtcNow - LastAnalysis < TimeSpan.FromMinutes(5)) return;
            Queue(new JsonObject { ["action"] = "AnalyzeBacklog", ["scope"] = "all" }, hostToken, automatic: true);
        }
    }
    public Job? QueueWhenIdle(JsonObject request, CancellationToken hostToken, bool automatic = false) {
        lock (queueGate) {
            if (closing || ForegroundBusy || (request["action"]?.GetValue<string>() is "Analyze" or "AnalyzeBacklog") && Busy) { request.Clear(); return null; }
            return Queue(request, hostToken, automatic: automatic);
        }
    }
    public Job Queue(JsonObject request, CancellationToken hostToken, Action<JsonNode?>? completed = null, string? cleanupPath = null, bool automatic = false) {
        Job job;
        var action = request["action"]!.GetValue<string>();
        var background = action == "AnalyzeBacklog" || action == "Analyze" && (request["id"] is null || request["id"] is JsonValue idValue && idValue.TryGetValue<string>(out var id) && string.IsNullOrEmpty(id));
        lock (queueGate) {
            if (closing) { request.Clear(); throw new WorkerException("The program is closing after the current safe checkpoint. Reopen it to continue."); }
            if (action == "AnalyzeBacklog" && (request["scope"] is not JsonValue scopeValue || !scopeValue.TryGetValue<string>(out var scope) || scope is not ("pending" or "all")))
                throw new WorkerException("Choose pending reports or all saved reports for automatic reading.");
            if (action == "Refresh") {
                var existing = Jobs.Values.FirstOrDefault(j => j.Action == action && (j.Status is "queued" or "running"));
                if (existing is not null) { request.Clear(); return existing; }
            }
            if (background && Jobs.Values.Any(j => j.Background && (j.Status is "queued" or "running"))) {
                request.Clear();
                throw new WorkerException("Background reading is already running. Finish or stop its current batch before starting another.");
            }
            if (Jobs.Values.Count(j => j.Status is "queued" or "running") >= 32) throw new WorkerException("The action queue is full. Wait for existing work to finish.");
            foreach (var old in Jobs.Values.Where(j => j.Status is "completed" or "failed" or "cancelled").OrderByDescending(j => j.StartedUtc).Skip(80)) { if (Jobs.TryRemove(old.Id, out var removed)) removed.Cancel.Dispose(); }
            // Only supported reading options survive in a long-running background request.
            // In particular, do not retain unrelated transient credential fields.
            if (background) foreach (var name in request.Select(p => p.Key).Where(n => n is not ("action" or "ids" or "measurements" or "analysisLimit" or "force" or "id" or "scope" or "refreshUnsupported")).ToArray()) request.Remove(name);
            if (background && !automatic) automaticReadingStopped = false;
            job = new Job(action, background, automatic); Jobs[job.Id] = job;
            WriteActivity(action, "Started", 0, "Queued", "Queued");
            if (action == "Refresh") LastRefresh = DateTimeOffset.UtcNow;
            if (action is "Analyze" or "AnalyzeBacklog") LastAnalysis = DateTimeOffset.UtcNow;
        }
        var enableAutomatic = action == "Settings" && request["autoAnalyze"] is JsonValue autoValue && autoValue.TryGetValue<bool>(out var enabled) && enabled;
        _ = Task.Run(async () => {
            using var execution = CancellationTokenSource.CreateLinkedTokenSource(hostToken, shutdown.Token);
            using var waiting = CancellationTokenSource.CreateLinkedTokenSource(execution.Token, job.Cancel.Token);
            var entered = false; var timer = Stopwatch.StartNew();
            try {
                JsonNode? result;
                if (job.Background) {
                    job.PrepareProgress(root); job.Status = "running";
                    result = await RunBackgroundAnalysis(request, job, execution.Token, waiting.Token);
                } else {
                    if (action is not ("Diagnostics" or "PrintDiagnostics")) { await mutation.WaitAsync(waiting.Token); entered = true; }
                    waiting.Token.ThrowIfCancellationRequested();
                    job.PrepareProgress(root);
                    job.Status = "running"; job.Message = MessageFor(action);
                    if (action is "Diagnostics" or "PrintDiagnostics") request["supportWork"] = JsonSerializer.SerializeToNode(Jobs.Values.OrderByDescending(j => j.StartedUtc).Take(32).Select(j => j.SupportView()));
                    var isolatedPdfRead = action == "Analyze" && request["id"] is JsonValue selectedId && selectedId.TryGetValue<string>(out var selectedText) && SafeFiles.ValidRecordId(selectedText);
                    result = await bridge.Run(request, action is "Refresh" or "Backup" or "Restore" or "Analyze" or "Export" or "Diagnostics" or "PrintDiagnostics" ? 1800 : 120, execution.Token, job, isolatedPdfRead: isolatedPdfRead);
                    job.ReadProgress();
                    if (action is not ("Diagnostics" or "PrintDiagnostics")) {
                        var previousArchive = Snapshot?["archiveRoot"]?.GetValue<string>();
                        if (result?["snapshot"] is JsonNode nextSnapshot) Volatile.Write(ref snapshot, nextSnapshot.DeepClone());
                        else if (action != "InstallPreparedUpdate" && !(action == "Browse" && result?["snapshotDeferred"]?.GetValue<bool>() == true)) await LoadSnapshot(execution.Token);
                        Interlocked.Increment(ref foregroundRevision);
                        if (action is "Settings" or "ScannerSettings" or "ApplyProfile" or "Refresh" or "Restore" or "PickArchive") Interlocked.Increment(ref libraryRevision);
                        if (enableAutomatic) { lock (queueGate) { automaticReadingStopped = false; LastAnalysis = DateTimeOffset.MinValue; } }
                        if (Snapshot?["settings"]?["autoAnalyze"]?.GetValue<bool>() == false)
                            foreach (var reading in Jobs.Values.Where(j => j.Background && j.Automatic && (j.Status is "queued" or "running"))) reading.RequestCancel();
                        var nextArchive = Snapshot?["archiveRoot"]?.GetValue<string>();
                        if (previousArchive is not null && nextArchive is not null && !SafeFiles.SamePath(previousArchive, nextArchive))
                            foreach (var reading in Jobs.Values.Where(j => j.Background && (j.Status is "queued" or "running"))) reading.RequestCancel();
                    }
                }
                var wasCancelled = result?["cancelled"]?.GetValue<bool>() == true;
                if (!wasCancelled) completed?.Invoke(result);
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
                job.Result = published; job.Status = wasCancelled ? "cancelled" : "completed";
                job.Message = wasCancelled ? "Stopped safely. Completed verified reports remain saved." : "Finished";
                if (wasCancelled) { LastRefresh = DateTimeOffset.UtcNow; LastAnalysis = DateTimeOffset.UtcNow; }
                WriteActivity(action, wasCancelled ? "Cancelled" : "Completed", timer.ElapsedMilliseconds, performanceJob: job);
            } catch (Exception ex) {
                if (ex is WorkerException { PdfReadDeadline: true }) { lock (queueGate) automaticReadingStopped = true; }
                var stoppedBeforeStarting = ex is OperationCanceledException && job.CancelRequested;
                job.Status = stoppedBeforeStarting ? "cancelled" : "failed";
                job.Error = stoppedBeforeStarting ? (job.Background ? "Background reading stopped safely. Completed readings remain saved." : "Cancelled before starting. Saved reports were not changed.") : ex is WorkerException ? ex.Message : ex is OperationCanceledException ? "The local session stopped." : "The action could not finish. Export support logs if this repeats.";
                if (job.Background) job.Result = new JsonObject { ["performance"] = JsonSerializer.SerializeToNode(job.PerformanceView()) };
                job.Message = job.Error; WriteActivity(action, stoppedBeforeStarting ? "Cancelled" : "Failed", timer.ElapsedMilliseconds, performanceJob: job);
                if (job.CancelRequested) { LastRefresh = DateTimeOffset.UtcNow; LastAnalysis = DateTimeOffset.UtcNow; }
                if (entered && action == "Refresh" && !execution.IsCancellationRequested) { try { await LoadSnapshot(execution.Token); } catch { } }
            } finally {
                request.Clear(); // Includes transient password fields. Never retain request payloads in job history.
                job.CleanupProgress(); job.MarkFinished();
                if (action == "Refresh") LastRefresh = DateTimeOffset.UtcNow;
                if (action is "Analyze" or "AnalyzeBacklog") LastAnalysis = DateTimeOffset.UtcNow;
                if (entered) mutation.Release();
                if (cleanupPath is not null) { try { File.Delete(cleanupPath); } catch { } }
                if (!job.Background && action is not ("Diagnostics" or "PrintDiagnostics" or "InstallPreparedUpdate")) TryQueueAutomaticAnalysis(hostToken);
            }
        });
        return job;
    }
    private async Task<JsonNode?> RunBackgroundAnalysis(JsonObject request, Job job, CancellationToken executionToken, CancellationToken waitingToken) {
        long analyzed = 0, failed = 0, cached = 0, pending = 0;
        var analyzedIds = new JsonArray(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dirty = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Queue<string>? remaining = null;
        long plannedGeneration = -1, syncedLibraryGeneration = Interlocked.Read(ref libraryRevision);
        string? plannedRevision = null;
        var processedSincePlan = false; var needsSnapshot = false; var cancelled = false; var normalExit = false; var finalCheckpointDone = false;
        var checkpoint = Stopwatch.StartNew(); var sinceCheckpoint = 0;
        string? warning = null;
        async Task EnterSlot(CancellationToken token, bool honorPause = true) {
            job.SetBoundary(true, ForegroundBusy);
            while (true) {
                token.ThrowIfCancellationRequested();
                if (honorPause && job.PauseRequested || ForegroundBusy) { job.SetBoundary(true, ForegroundBusy); await Task.Delay(100, token); continue; }
                await mutation.WaitAsync(token);
                lock (queueGate) { if ((!honorPause || !job.PauseRequested) && !ForegroundBusy) return; }
                mutation.Release(); await Task.Delay(100, token);
            }
        }
        async Task Plan() {
            var planRequest = new JsonObject { ["action"] = "AnalysisPlan", ["scope"] = job.Action == "AnalyzeBacklog" ? request["scope"]?.DeepClone() ?? JsonValue.Create("all") : JsonValue.Create("all"),
                ["measurements"] = job.Action == "AnalyzeBacklog" || request["measurements"]?.GetValue<bool>() == true,
                ["refreshUnsupported"] = job.Action == "AnalyzeBacklog" || request["refreshUnsupported"]?.GetValue<bool>() == true };
            if (request["ids"] is JsonNode ids) planRequest["ids"] = ids.DeepClone();
            JsonNode? value; var planClock = Stopwatch.StartNew();
            try { value = await bridge.Run(planRequest, 90, executionToken, job); }
            finally { planRequest.Clear(); }
            job.CountPlan(planClock.ElapsedMilliseconds);
            if (value?["cancelled"]?.GetValue<bool>() == true || job.CancelRequested) { cancelled = true; remaining = new Queue<string>(); return; }
            var plan = value?["plan"] as JsonObject ?? throw new WorkerException("The background reader did not return a complete work plan.");
            var next = new Queue<string>(); var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (plan["recordIds"] is not JsonArray plannedIds || plannedIds.Count > 100_000) throw new WorkerException("The background reading plan is incomplete.");
            foreach (var item in plannedIds) {
                if (item is not JsonValue idValue || !idValue.TryGetValue<string>(out var id) || !SafeFiles.ValidRecordId(id) || !unique.Add(id)) throw new WorkerException("The background reading plan contains an invalid saved report.");
                next.Enqueue(id);
            }
            long Count(string name) => plan[name] is JsonValue v && v.TryGetValue<long>(out var n) && n is >= 0 and <= 100_000_000 ? n : 0;
            if (Count("pending") != next.Count) throw new WorkerException("The background reading plan is incomplete. Completed readings remain saved.");
            remaining = next; pending = next.Count; cached = Math.Max(cached, Math.Max(0, Count("cached") - analyzed - failed));
            plannedRevision = plan["revision"]?.GetValue<string>(); plannedGeneration = Interlocked.Read(ref foregroundRevision); processedSincePlan = false;
            job.SetBackgroundProgress(analyzed, failed, pending, cached);
        }
        async Task PublishCheckpoint(bool fullSync) {
            var ids = new JsonArray(); foreach (var id in dirty) ids.Add(id);
            var sync = new JsonObject { ["action"] = "SyncLibrary", ["ids"] = ids, ["fullSync"] = fullSync };
            JsonNode? value; var snapshotClock = Stopwatch.StartNew();
            try { value = await bridge.Run(sync, 1800, executionToken, job); }
            finally { sync.Clear(); }
            if (dirty.Count > 0 || fullSync) job.CountLibrarySync();
            if (value?["snapshot"] is not JsonNode nextSnapshot) throw new WorkerException("The updated report overview could not be refreshed. Completed readings remain saved.");
            Volatile.Write(ref snapshot, nextSnapshot.DeepClone()); job.CountSnapshot(snapshotClock.ElapsedMilliseconds); needsSnapshot = false;
            cancelled |= value?["cancelled"]?.GetValue<bool>() == true || job.CancelRequested;
            if (!cancelled) { dirty.Clear(); syncedLibraryGeneration = Interlocked.Read(ref libraryRevision); }
            checkpoint.Restart(); sinceCheckpoint = 0;
        }
        try {
            while (true) {
                await EnterSlot(waitingToken);
                var finish = false;
                try {
                    waitingToken.ThrowIfCancellationRequested();
                    if (remaining is null || plannedGeneration != Interlocked.Read(ref foregroundRevision)) await Plan();
                    if (!cancelled && remaining!.Count == 0 && processedSincePlan) await Plan(); // One final trusted eligibility pass, rather than one pass per PDF.
                    if (cancelled || remaining!.Count == 0) finish = true;
                    if (!finish) {
                        var id = remaining!.Dequeue();
                        job.SetBoundary(false);
                        var chunk = new JsonObject { ["action"] = "Analyze", ["ids"] = new JsonArray(id), ["analysisLimit"] = 1,
                            ["analysisStep"] = true, ["deferSnapshot"] = true, ["deferLibrary"] = true,
                            ["measurements"] = job.Action == "AnalyzeBacklog" || request["measurements"]?.GetValue<bool>() == true,
                            ["refreshUnsupported"] = job.Action == "AnalyzeBacklog" || request["refreshUnsupported"]?.GetValue<bool>() == true };
                        JsonNode? value;
                        try { value = await bridge.Run(chunk, 90, executionToken, job, isolatedPdfRead: true); }
                        catch { remaining.Enqueue(id); pending = remaining.Count; job.SetBackgroundProgress(analyzed, failed, pending, cached); throw; }
                        finally { chunk.Clear(); }
                        job.ReadProgress();
                        var result = value?["result"] as JsonObject;
                        var checkedRecord = false;
                        cancelled = value?["cancelled"]?.GetValue<bool>() == true || job.CancelRequested;
                        if (result is null && !cancelled) throw new WorkerException("The background reader did not return a complete PDF checkpoint.");
                        if (result is not null) {
                            long Count(string name) => result[name] is JsonValue v && v.TryGetValue<long>(out var n) && n is >= 0 and <= 100_000_000 ? n : 0;
                            var done = Count("Analyzed"); var errors = Count("Failed"); var skipped = Count("Cached");
                            if (done + errors + skipped > 1) throw new WorkerException("The background reader exceeded its one-PDF checkpoint.");
                            if (!cancelled && done + errors + skipped == 0) throw new WorkerException("The selected background PDF could not be checked. Completed readings remain saved.");
                            checkedRecord = done + errors + skipped > 0;
                            analyzed += done; failed += errors; sinceCheckpoint += (int)(done + errors); processedSincePlan = true;
                            job.CountProcessed(done + errors); job.CountSkipped(skipped);
                            if (result["AnalyzedIds"] is JsonArray ids) foreach (var item in ids) if (item is JsonValue v && v.TryGetValue<string>(out var changed) && SafeFiles.ValidRecordId(changed)) { dirty.Add(changed); if (seen.Add(changed)) analyzedIds.Add(changed); }
                            needsSnapshot |= done + errors > 0;
                        }
                        if (cancelled && !checkedRecord) remaining!.Enqueue(id); // An interrupted read is still waiting, not silently consumed.
                        if (value?["snapshot"] is JsonNode nextSnapshot) { Volatile.Write(ref snapshot, nextSnapshot.DeepClone()); job.CountSnapshot(); needsSnapshot = false; }
                        else if (value?["snapshotDeferred"]?.GetValue<bool>() != true) { await LoadSnapshot(executionToken); job.CountSnapshot(); needsSnapshot = false; }
                        var revision = value?["analysisRevision"]?.GetValue<string>();
                        if (revision is not null && plannedRevision is not null && revision != plannedRevision) plannedGeneration = -1;
                        pending = remaining.Count; job.SetBackgroundProgress(analyzed, failed, pending, cached);
                        finish = cancelled || job.Action != "AnalyzeBacklog" && analyzed + failed >= 20;
                    }
                    if (!cancelled && !ForegroundBusy && (finish || sinceCheckpoint >= 10 || checkpoint.Elapsed >= TimeSpan.FromSeconds(15)) && (needsSnapshot || dirty.Count > 0 || finish && job.Action == "AnalyzeBacklog")) {
                        await PublishCheckpoint(finish && job.Action == "AnalyzeBacklog" || syncedLibraryGeneration != Interlocked.Read(ref libraryRevision));
                        if (finish && !cancelled) finalCheckpointDone = true;
                    }
                } finally { mutation.Release(); }
                if (finish || cancelled) break;
                job.SetBoundary(true, ForegroundBusy); await Task.Delay(200, waitingToken);
            }
            normalExit = true;
        } catch (OperationCanceledException) when (job.CancelRequested && !executionToken.IsCancellationRequested) { cancelled = true; }
        finally {
            // Cancellation/error cleanup refreshes current metadata only. It never forces
            // more PDF copies after Stop, and never overwrites a foreground result out of order.
            if (!executionToken.IsCancellationRequested && (needsSnapshot || !normalExit || cancelled || job.CancelRequested || normalExit && !cancelled && !finalCheckpointDone && job.Action == "AnalyzeBacklog")) {
                await EnterSlot(executionToken, honorPause: false);
                try {
                    if (normalExit && !cancelled && !job.CancelRequested) await PublishCheckpoint(job.Action == "AnalyzeBacklog" || syncedLibraryGeneration != Interlocked.Read(ref libraryRevision));
                    else { await LoadSnapshot(executionToken, job); job.CountSnapshot(); needsSnapshot = false; }
                }
                catch { warning = "Completed readings remain saved. Refresh the overview before continuing."; }
                finally { mutation.Release(); }
            }
        }
        if (dirty.Count > 0) warning = "Completed readings remain saved. Use Update reports or Open report folders to finish readable-folder updates.";
        var description = $"{analyzed} PDFs analyzed; {cached} cached; {failed} need attention.";
        WriteActivity("ReadingScheduler", cancelled ? "Cancelled" : "Completed", 0, "Finishing", cancelled ? "UserStopped" : pending == 0 ? "QueueEmpty" : "BatchLimitReached", analyzed + failed, analyzed + failed + pending, failed, cached);
        if (!cancelled && pending > 0) description += $" {pending} remain for the next reading batch.";
        if (job.Action == "AnalyzeBacklog" && !cancelled) description += $" {Snapshot?["pendingSummary"]?["pending"]?.GetValue<int>() ?? 0} report types still need a filing rule or review.";
        return new JsonObject { ["cancelled"] = cancelled, ["message"] = cancelled ? "Stopped safely. Completed readings remain saved." : description,
            ["result"] = new JsonObject { ["Mode"] = "Analysis", ["Analyzed"] = analyzed, ["Failed"] = failed, ["Cached"] = cached, ["Pending"] = pending, ["AnalyzedIds"] = analyzedIds,
                ["Summary"] = new JsonObject { ["Description"] = description, ["Cancelled"] = cancelled } },
            ["performance"] = JsonSerializer.SerializeToNode(job.PerformanceView()), ["foldersPending"] = dirty.Count > 0, ["warning"] = warning };
    }
    private readonly object activityGate = new();
    public void RecordLifecycle(string operation, string outcome) => WriteActivity(operation, outcome, 0, "Idle");
    public void RecordReadingControl(string reason) => WriteActivity("ReadingScheduler", "Completed", 0, reason == "UserPaused" ? "Paused" : "Analyzing", reason);
    private void WriteActivity(string action, string outcome, long duration, string stage = "Finishing", string reason = "", long completed = 0, long total = 0, long failed = 0, long cached = 0, Job? performanceJob = null) {
        try { lock (activityGate) {
            var operation = action switch { "Refresh" => "Update", "Analyze" or "AnalyzeBacklog" => "Analysis", "Approve" or "Disapprove" or "Undo" => "Reclassify", "ScannerSettings" or "ApplyProfile" => "Settings", "Browse" => "BrowseRefresh", "InstallPreparedUpdate" or "PrepareUpdate" => "OfflineUpdate", _ => action };
            var path = Path.Combine(root, "Logs", "Web", "activity.jsonl"); Directory.CreateDirectory(Path.GetDirectoryName(path)!); SafeFiles.RequireDirect(path); SafeFiles.RequireDirect(path + ".previous");
            if (File.Exists(path) && new FileInfo(path).Length > 1_048_576) File.Move(path, path + ".previous", true);
            File.AppendAllText(path, JsonSerializer.Serialize(new { SchemaVersion = 3, TimeUtc = DateTimeOffset.UtcNow, Operation = operation, Outcome = outcome, DurationMs = duration, Stage = stage, Reason = reason.Length > 0 ? reason : outcome == "Failed" ? "WorkerFailed" : outcome == "Started" ? "OperationStarted" : "OperationCompleted", ErrorKind = outcome == "Failed" ? "Unknown" : "None", Counts = new { Completed = completed, Total = total, Failed = failed, Cached = cached, PlanPasses = performanceJob?.PlanBuildCount ?? 0, SnapshotPasses = performanceJob?.FullSnapshotCount ?? 0, LibraryPasses = performanceJob?.LibrarySyncCount ?? 0, QueueCompleted = performanceJob?.ProcessedCount ?? 0, CacheHits = performanceJob?.CacheSkipCount ?? 0, WorkerStarts = performanceJob?.WorkerStartCount ?? 0, InlinePdfReads = performanceJob?.InlinePdfReadCount ?? 0, HelperMilliseconds = performanceJob?.HelperMilliseconds ?? 0, ReadWorkerMilliseconds = performanceJob?.ReadWorkerMilliseconds ?? 0, PlanningMilliseconds = performanceJob?.PlanningMilliseconds ?? 0, SnapshotMilliseconds = performanceJob?.SnapshotMilliseconds ?? 0 } }) + Environment.NewLine, new UTF8Encoding(false));
        }} catch { }
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
