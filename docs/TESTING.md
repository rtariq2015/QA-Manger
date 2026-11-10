# Testing and practical limits

Final v5.1.0 Windows validation passed at source `0c20b818542c819c601c85af314b727bb9159558` in [workflow 42923789148](https://github.com/rtariq2015/QA-Manger/actions/runs/42923789148). All PDFs, scanner folders, identities and password canaries are synthetic; no hospital records or real credentials were used.

| Execution | Scenarios | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: twelve native suites | 200 | 1,256 | 0 | [Windows summary](../Tests/Current/Windows/Summary.json) and unmodified raw suite reports |
| Windows Edge: actual self-contained host and adapter | 12 | 296 | 0 | [Windows browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: 1,367-report library workload | 4 | 5,463 | 0 | [Windows library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: 1,367-report progress and cancellation workload | 4 | 27,328 | 0 | [Large Windows browser report](../Tests/Current/Browser-Large-Windows.json) |
| Linux PowerShell 7.4.13: core, PDF reader and adapter | 56 | 317 | 0 | [Current summary](../Tests/Current/Summary.json) and three raw `Run-*.json` reports |
| Linux PowerShell: 1,367-report library workload | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Linux.json) |
| Linux Chromium: actual local host and adapter | 12 | 292 | 0 | [Browser report](../Tests/Current/Browser-Web.json) |
| Linux Chromium: 1,367-report progress and cancellation workload | 4 | 27,328 | 0 | [Large browser report](../Tests/Current/Browser-Large-Linux.json) |

The Windows reports are the final pinned release execution, including native PNG rendering in Edge. Most separately labeled Linux development runs preceded the final PowerShell 5.1 array-representation compatibility fix. The adapter was rerun afterward and again passed 21 scenarios / 81 assertions. These are supporting checks rather than a claim that every final-source suite was rerun on Linux. The complete previous evidence, including the controlled mouse-release typing regression, is preserved in [Tests/Historical/v5.0.1](../Tests/Historical/v5.0.1). Earlier broad runs remain under `Tests/Historical/v5.0.0`. Some raw report version fields identify feature introduction; raw reports are copied without alteration. Host-binary and validation-artifact SHA-256 values are recorded in the Windows summary.

## What changed and what was exercised

Standard Daily filenames, including provisional generic Constancy Daily grouping, are automatically filed as Daily documents. An explicit valid Monthly filename can be filed as a Monthly document. Saved Approve/Disapprove decisions and valid prior clinical reviews take precedence. Size-only Monthly candidates, generic text hints and unknown types remain pending. These are document labels: automatic filing and Approve do not create a clinical reviewer, printed PASS/FAIL or completed Monthly checklist.

The large fixture contains 1,367 real synthetic source and archive PDFs: 1,050 automatically organized, 217 pending, 81 approved and 19 disapproved. The adapter and browser verify the exact populations and preserve prior reviewer fields, checklist evidence, clinical history and file-organization decisions. The browser uses the actual local host and PowerShell worker; its application API is not mocked.

The readable-library checks measure work rather than impose hardware-dependent duration limits. A cold batch verifies each new PDF and commits its ownership ledger once: 2,734 hash operations for 1,367 copies. An unchanged warm batch performs zero PDF hash reads, zero copies and zero ledger writes. An explicit integrity audit bypasses that metadata shortcut and detects altered bytes even when the file length and timestamp were restored. Those counters describe local synthetic files, not a promise about hospital network speed.

A deterministic barrier is inserted only into a disposable fixture's copied progress checkpoint. The real archive loop, worker progress channel, cancellation marker and persistence run normally. The browser confirms:

- Real stage, count and elapsed progress; repeated Refresh requests reuse the active job.
- Saved reports remain searchable and viewable while an update runs, including after reloading the browser.
- Cancel stops at a safe checkpoint, stops the progress display and prevents subsequent library work; all original source and archive hashes and prior evidence remain preserved.
- A later unchanged update completes after browser reload and reuses all 1,367 cached readable copies.
- Support collection completes and its actual ZIP downloads while Refresh remains held. A dedicated support link remains available after the later Refresh result replaces the progress notification.

The regular browser suite retains authentication/origin guards, bundled offline assets, actual keyboard typing and connection drafts, no-name Approve/Disapprove, Undo, stale-decision rejection, restart persistence, exact filtered ZIP exports, visible connection errors and a 1024×768 layout check. Windows runs also check real native PNG rendering inside the review pane. The four standard interface screenshots and two large-workload screenshots in [docs/images](images) are actual synthetic Windows captures copied from the successful final workflow. The large captures show the [pending library](images/large-library-pending.png) and [active Refresh progress](images/large-refresh-progress.png); they are not design mockups.

Core and PDF tests cover source preservation, revised files, archive locks, interrupted-copy recovery, cancellation, structured extraction and reuse of cached analysis, including multi-PDF batches. The adapter additionally covers explicit-review precedence, old approval/Undo behavior, interrupted library ownership commits and concurrent edits during verification.

Support bundles reconstruct allowlisted counts, outcomes, timings and Windows error numbers. Synthetic privacy canaries check that passwords, report text, filenames, paths, usernames, network addresses and raw logs do not enter the shareable bundle. Nothing is uploaded automatically.

## Reproducing checks

Development validation needs the .NET SDK and Node/Playwright. These are build/test tools; they are not installations required on the work computer. The Windows workflow builds the self-contained host, runs the native suites in Windows PowerShell 5.1, then runs:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

This creates separate fresh small and 1,367-report synthetic workspaces, runs both real-host browser suites and the large-library PowerShell checks, and saves separate JSON reports. Fixture helpers refuse existing destinations. See [Windows-Smoke.md](../Tests/Windows-Smoke.md) for workstation checks.

## Practical limits

- The portable host includes its runtime, but still uses existing Windows PowerShell 5.1 and native Windows components. Endpoint policy can restrict executables, scripts, loopback browser access or scanner shares. Hosted tests cannot establish hospital access or approve workstation policy.
- Scanner collection requires the internal hospital network. Saved reports, classification, search and export work locally. An unavailable scanner or absent PDF does not establish a clinical QA failure.
- The interface is served on loopback, with bundled assets and no automatic upload. Checks run only while the local app is running; no service, scheduled task or closed-app notification is installed.
- Cancellation is cooperative. A Windows network file read already in progress may have to return before the next safe checkpoint. Local synthetic timings do not reproduce slow SMB shares, endpoint scanning or workstation load.
- PDF analysis caches content fingerprints. OCR and department-specific numerical QA limits are not included. Incomplete text stays for review; report receipt, document labels, extracted results and formal checklist evidence remain separate.
- The readable library is a convenience copy. Metadata reuse speeds ordinary refresh; explicit integrity verification rereads bytes. Same-drive copies do not protect against drive loss. Keep an approved separate backup.
- Windows-encrypted scanner sign-ins may need re-entry after moving to another user or computer. Updates preserve local settings and data. Manifest checks detect inconsistent files but do not authenticate an unknown publisher; retained history is not a signed audit system.
- Physical keyboard/IME behavior, manual folder pickers, workstation DPI, very long paths, real hospital reports and actual scanner-share performance still need approved workstation checks.
