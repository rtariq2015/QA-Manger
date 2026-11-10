# Portable local host

This project builds CT QA Manager's offline HTML host using Microsoft ASP.NET Core Kestrel and .NET 10 LTS. It is a local application host, not an internet website or a Windows service. The development SDK is not required on the work computer. A self-contained release bundles the runtime; native runtime files extract under the workspace's `Data/RuntimeCache` when launched through `App/Start-Web.ps1`.

Build a Windows release with the .NET 10 SDK:

```sh
dotnet publish Host/CTQa.Host.csproj -c Release -r win-x64 --self-contained true -o artifacts/host
```

Copy the published `CTQa.Host.exe` into `App/Host/` before packaging. Do not ship SDK files, compiler output folders or development caches. Include the .NET and ASP.NET Core runtime license and third-party notices alongside the binary. The release must be tested after publishing; a successful compilation does not establish workplace endpoint approval.

For a development run, build then launch with:

```sh
dotnet Host/bin/Debug/net10.0/CTQa.Host.dll --root PATH_TO_WORKSPACE --powershell PATH_TO_POWERSHELL --no-browser
```

The application must have its `App/Web/` assets and `App/WebWorker.ps1`. Runtime configuration stays in the selected workspace. `Data/web-ready.json` contains the selected loopback URL and a per-launch session token; its ACL permits only the current user. It is deleted during normal shutdown. Do not upload or commit this file. The host never prints the token.

The host binds only `127.0.0.1`, selecting an available port by default. It does not register HTTP.sys namespaces, add firewall rules or require administrator launch. Endpoint policy can still block the executable or local browser connection. The previous WPF interface remains the fallback through the fixed OpenClassic action or the main launcher's `classic` argument.

The browser opens `/#session=TOKEN`, exchanges the fragment token with `POST /api/session`, and receives an HttpOnly SameSite=Strict cookie for PDF frames. API calls also accept `X-Qa-Session`. Host and Origin checks reject foreign websites. There is no broad CORS allowance. Only static app assets are public; no untrusted remote content is loaded.

Worker requests are streamed as UTF-8 JSON over standard input to Windows PowerShell and results return over standard output. Scanner passwords are not written to request files, command arguments, jobs or logs. `/api/jobs` contains only status, results and fixed operation names. Job mutations are serialized; read-only snapshots and saved PDF views remain separate. The worker uses the existing archive guards and revision-preserving operations.

API summary:

- `GET /api/snapshot`: saved workspace snapshot, or 503 while loading.
- `GET /api/jobs`: `{jobs:[...]}`. Jobs use queued/running/completed/failed/cancelled status.
- `POST /api/actions`: a narrow allowed action; returns 202 with a job ID.
- `POST /api/jobs/{id}/cancel`: request worker cancellation. The existing archive transaction recovery preserves committed work and retries interrupted staging.
- `GET /api/pdf/{recordId}`: resolve and verify a saved PDF through the helper; arbitrary paths are rejected.
- `GET /api/preview/{recordId}?page=0`: read-only native Windows PDF image rendering; ID and page bounds are validated.
- `GET /api/download/{artifactId}`: download a helper-produced export, backup or scrubbed support bundle.
- `POST /api/update`: one ZIP in multipart `file`; returns a PrepareUpdate job. An opaque `updateId` is used by `InstallPreparedUpdate`.
- `POST /api/heartbeat`: retain the local app session. The host stops after 30 minutes without API activity and no running jobs, or through Shutdown. Automatic scanner checks and analysis require a browser heartbeat within the previous 90 seconds; closing the tab stops those checks promptly.

A checked update launches the existing upgrader only after the host PID has exited, so the host executable is not replaced while running. The temporary update stage must belong to the current workspace. The browser cannot provide arbitrary install paths.

No internet connection is required. Saved reports and operations stay local. Actual scanner access still uses the workstation's approved internal network and credentials. A shared Windows login is an activity actor, not a verified personal clinical reviewer.
