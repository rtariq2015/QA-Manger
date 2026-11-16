# Development and restricted-workstation maintenance

The shipped program remains Windows PowerShell 5.1, a self-contained Windows x64 localhost host, bundled PDF readers, and local HTML/CSS/JavaScript. Development tools below belong on a development machine or CI runner. Users do not install Node, Python, the .NET SDK, a service or a scheduled task.

## Boundaries that changes must preserve

- Scanner shares are read-only inputs. Copy to private staging, verify SHA-256 and fresh source metadata, then commit through the existing journal. Keep original filenames, separate sessions, revisions and exact-byte review history.
- `.ctqa/state.json` is the authoritative archive index. The master CSV is a spreadsheet-facing projection. Fail on ambiguous identities or destination ownership; never repair a corrupt state by silently dropping rows. Keep the original and its backup for authorized investigation.
- Web organization decisions do not populate clinical `ConfirmedComponents`. Receipt, cached section detection, printed measurements and authorized legacy reviewed evidence are separate facts.
- PDF views resolve from fresh validated core records and recheck the actual file hash. Removing unrelated dashboard projections must never remove membership, containment, direct-path or byte checks.
- Keep the local host on `127.0.0.1`, with its session/origin/CSP protections. Do not expose arbitrary paths or commands. DPAPI credentials remain tied to the Windows account and configured scanner identity.
- The report page holds 100 rendered rows, while its matching set and exports include all matching reports. Exports already has a 12-row preview. Sorting/search-text caches belong to a complete metadata revision, and changed content must invalidate them. Unchanged snapshots should retain DOM and focus; changed snapshots must restore focus safely after rebuilding.
- Review stays one current-file or explicit selected-batch action area. A stale batch must fail before any member is changed. Preserve durable Undo and clinical history. Keyboard navigation must target the visible report page.
- UI density is an origin-scoped browser-local preference (a new random port can reset it on a later launch); it is not a resource policy or clinical setting. Comfortable is the default. Theme, scanner colors, local SVG icons, reduced-motion support and the Classic fallback remain.
- Update checksums remain mandatory. Reject linked/ambiguous paths before mutation. Keep previous program backups and preserve settings, archives, credentials, saved decisions and logs. Restore validates and copies from the same open backup ZIP into a new folder.
- Do not raise existing PDF, upload, preview-cache, queue, batch, timeout or archive safety limits without explicit tests and justification. Do not change execution policy, application control or endpoint security.

## Incremental workflow

Create a branch from the intended baseline, read `AGENTS.md`, inspect the affected implementation and existing tests, and measure an actual problem before changing it. Keep purpose-specific commits. Use synthetic PDFs, scanner folders and credentials. Never commit workstation configuration, raw reports, patient data, private addresses, credential files, ready-file tokens or support bundles.

PowerShell source retains UTF-8 BOM and valid CRLF; CMD retains ASCII and CRLF. Use `git -c core.whitespace=cr-at-eol diff --check` for the repository's deliberate Windows line endings. Keep new test/runtime assets compatible with the existing updater payload allowlist; in particular, new JavaScript runtime filenames require a deliberate supported-upgrade design.

## Reproduce validation

Run the static source checker first:

```sh
python Tests/Verify-Package.py
```

On a Windows development runner, run relevant native suites and then the complete CI workflow. For example:

```powershell
New-Item -ItemType Directory -Force artifacts/windows | Out-Null
powershell.exe -NoProfile -File Tests/Run-Tests.ps1 -OutputPath artifacts/windows/Run-Tests.json
powershell.exe -NoProfile -File Tests/Run-UpdateTests.ps1 -OutputPath artifacts/windows/Run-UpdateTests.json
powershell.exe -NoProfile -File Tests/Run-PortableTests.ps1 -OutputPath artifacts/windows/Run-PortableTests.json
powershell.exe -NoProfile -File Tests/Run-WebServiceTests.ps1 -OutputPath artifacts/windows/Run-WebServiceTests.json
```

The Windows workflow builds the pinned self-contained host and bundled Python reader, runs real Edge workloads, eighteen Windows PowerShell suites, native reader comparison, scheduler controls and Classic WPF checks. It runs on ordinary pull requests with read-only repository permissions, never `pull_request_target`; independent suites continue after another suite fails and the overall job remains failed. Branch-scoped concurrency prevents unrelated branches cancelling each other. Publishing is a separate workflow and must not be invoked for an audit PR.

Developer browser dependencies are already pinned by CI. After building the host and setting the development `NODE_PATH`, run:

```sh
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

The accessibility workload uses a fresh synthetic workspace and the real host/adapter. It checks all eight tabs in both themes at effective viewport sizes corresponding to 100%, 125%, 150% and 200% of a 1366×768 screen, plus keyboard navigation, Review, density and preserved source bytes. This does not change Windows display settings or constitute a screen-reader usability certification.

The separate frontend benchmark uses production browser assets served by a development-only synthetic API. Its test bridge is injected into responses; no bridge or test server ships in the program:

```sh
node Tests/Web/run-library-performance.cjs --browser-channel msedge --output artifacts/web/library-performance.json
```

Use `--assets PATH_TO_BASELINE_APP_WEB --baseline true` to compare the exact original assets, `--counts 1367,20000` for the two library sizes, and `--budget-ms 120000` for a bounded workload. Run before/after sequentially on a quiet machine, preserve every sample, and report a timeout as a timeout. Debounce enqueue time differs from settled search latency; JS heap excludes browser/native DOM memory. The synthetic API benchmark does not measure PowerShell, PDF reading, scanner networking or full startup.

Selected-PDF metadata lookup has a separate reproducible benchmark:

```powershell
powershell.exe -NoProfile -File Tests/Run-SelectedLookupBenchmark.ps1 -OutputPath artifacts/windows/Selected-Lookup.json
```

It uses one real generated verified PDF and 1,367/20,000 synthetic index entries, with warm-up and repeated same-process resolution through the actual adapter. It verifies state/source/PDF bytes remain unchanged. Unselected indexed files are not physically populated. This measures lookup, not twenty thousand PDF parses, native page rendering or hospital throughput. CI uses a bounded iteration count; development callers should impose a finite process deadline and avoid concurrent benchmark workloads.

Store branch evidence separately from `Tests/Current`, which describes the published baseline. Record exact source/run identifiers, platform, executed/conditional tests, hashes and scope. Linux PowerShell 7/Chromium checks are useful development evidence; they do not establish Windows PowerShell 5.1, DPAPI, native PDF rendering, actual Windows DPI or hospital approval.

## Release authenticity options

SHA-256 detects package inconsistency; it does not authenticate a publisher if an attacker can replace both payload and manifest. Future IT-approved hardening can Authenticode-sign the host/PowerShell and verify a detached CMS signature over a canonical version/path/length/hash manifest using a deliberately pinned approved public key. Keep keys in a controlled signing service or hardware-backed store and design rotation, revocation, offline expiry and recovery first. Do not silently trust a new self-signed certificate or change workstation policy.

Official references: [PowerShell signing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing?view=powershell-5.1), [Windows cryptography tools](https://learn.microsoft.com/en-us/windows/win32/seccrypto/cryptography-tools), and [.NET Framework SignedCms](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.pkcs.signedcms?view=netframework-4.8.1). These are development references; the application loads no remote assets and ordinary use remains offline.

## Rollback and review

This engineering branch is delivered as a PR. It does not publish an update ZIP, merge main or deploy to a workstation. Review the source diff and fresh validation before separately authorizing packaging/release.

For development rollback, return to the baseline branch or revert the purpose-specific commits. For a separately installed checked update, close both interfaces, retain a full backup, and restore the previous `App` folder **and every backed-up root program file** from the matching `Backups/Program-*` transaction. Do not replace `Config`, `Data`, credentials, archives or logs. Automatic failed-install rollback also removes root files introduced by that failed transaction. OS file locks or storage failures can still prevent rollback; retain the backup and controlled error for IT.
