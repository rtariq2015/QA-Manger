# Testing and practical limits

Final v5.2.0 Windows validation passed at source `d3f17e0c36ab304ea34cddb9820c73bba165a707` in [workflow 42933748650](https://github.com/rtariq2015/QA-Manger/actions/runs/42933748650). All public test PDFs, folders, identities and password canaries are generated synthetic data. Uploaded private reports and extracted private text are excluded from repository evidence and screenshots.

| Execution | Scenarios | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: fifteen native suites | 233 | 1,617 | 0 | [Windows summary](../Tests/Current/Windows/Summary.json) and unmodified raw reports |
| Windows Edge: standard actual-host workflow | 12 | 296 | 0 | [Browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: 1,367-report library workload | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large-library progress/cancellation | 4 | 27,328 | 0 | [Large browser report](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: selected content/format workflow | 4 | 105 | 0 | [Content browser report](../Tests/Current/Browser-Content-Windows.json) |
| Linux PowerShell 7.4.13: analysis, classifier, content integration and PDF reader | 44 | 390 | 0 | [Current summary](../Tests/Current/Summary.json) and four raw `Run-*.json` reports |
| Linux Chromium: actual-host content workflow | 4 | 105 | 0 | [Content browser report](../Tests/Current/Browser-Content-Linux.json) |

Windows counts above come from the final successful pinned artifact. Linux checks are separately labeled development evidence; their raw reports do not embed commit hashes. Previous v5.1.0 broad Linux/browser/Windows evidence remains under [Tests/Historical/v5.1.0](../Tests/Historical/v5.1.0), with older releases under their respective historical folders. It is not relabeled as new execution. Some raw report Version fields identify a feature's introduction and are preserved unchanged. Host and validation-artifact SHA-256 values are recorded in the Windows summary.

## Content-based document filing

The reader identifies supported Siemens IEC Basic and Extended profiles from the complete numbered body sections. A table of contents, file size or page count is insufficient. Tests deliberately use a nine-page Basic report and a six-page Extended report, and retain raw printed `OK` tokens with their section/page evidence rather than turning them into a clinical PASS.

A recognized profile defaults to Ask unless the department saves a scanner-specific filing rule. Approve can accept one file's suggestion without teaching a rule for every file. A verified explicit Daily/Monthly document title can identify that document's stated type. Tests cover saved mapping, clearing it back to Ask, invalid-rule rejection and scanner isolation. Existing manual decisions, valid prior reviews and Undo retain priority. Undo preserves the visible suggested category, and re-Approve files that same category again.

Only consistent report-footer timestamps from a complete read can supply a missing report date. A disagreeing indexed filename date remains unchanged and requires review. Tests include conflicting page footers behind an explicit Monthly filename and a printed Daily title that conflicts with a saved Monthly rule. Neither shortcut can silently resolve the conflict. CRLF text, incomplete/OCR-needed input and unsupported body sections also stay explicit in classifier evidence. Accepted derived dates drive report filters, readable folders and ZIP year/month paths while core clinical state remains byte-for-byte unchanged.

## Cache provenance and actual workflow checks

Analysis records captured provenance for the actual parsed buffer: its verified SHA-256, length, archive record identity and write timestamp. Reader metadata is checked around parsing before results are cached. Older caches without the current classifier receive a bounded upgrade read; current entries are reused. Equal-content records retain independent destination provenance. Tests cover changed bytes, interrupted reads, metadata/provenance mismatch, failed-read retention and explicit selected retry.

The content browser uses the real localhost host, PowerShell worker, PDF reader and durable state. Its application API is not mocked. It clicks Read contents for the selected PDF, shows raw section evidence, approves/undoes without names or secondary confirmations, saves Report formats in Settings, exports the correctly dated PDF, and verifies warm reads do not parse it again. Two simultaneous cold selected-PDF requests must receive different serialized jobs and each populate its own expected page count/cache. Source and archived PDF hashes and the entire clinical-state file remain unchanged. At 1024×768, both decision buttons remain visible with the evidence inspector open.

The fifteen native suites also retain archive revision/lock/recovery checks, Monthly checklist evidence, exports, protected Windows sign-ins, support privacy, portability, verified backup/restore and offline updates. Standard browser checks retain authentication/origin guards, bundled assets, actual typing/draft handling, native PNG rendering, stale decisions, restart persistence and exact filtered ZIP hashes.

The large synthetic workload retains 1,367 PDFs: 1,050 automatically filed, 217 pending, 81 approved and 19 disapproved. A cold readable-library batch verifies 2,734 hash operations and commits one ownership ledger. An unchanged warm batch performs zero PDF hash reads, copies or ledger writes. Explicit integrity verification detects altered bytes even with restored length/timestamp. These counters verify work performed, rather than impose hardware-dependent time limits.

A barrier is inserted only into a disposable fixture's copied progress checkpoint. The real archive loop and cooperative cancellation then verify factual counters, duplicate Refresh coalescing, browsing/reload while busy, safe cancellation, resumed completion, and an independently downloadable support ZIP while Refresh remains held. The dedicated support link survives later job notifications.

All eight documentation captures were copied from the successful final Windows workflow: the four standard interface images, [large pending library](images/large-library-pending.png), [active update](images/large-refresh-progress.png), [content evidence](images/content-basic-web-demo.png) and [report-format settings](images/content-settings-web-demo.png). They are actual synthetic interface captures, not mockups.

Support bundles reconstruct allowlisted counts, outcomes, timings and Windows error numbers. Synthetic canaries test that passwords, report contents, filenames, paths, usernames, addresses and raw logs do not enter shareable bundles. Nothing is uploaded automatically.

## Reproducing checks

Build/test validation uses the .NET SDK and Node/Playwright; these are development tools, not installations required on the work computer. The Windows workflow builds the self-contained host, runs fifteen suites in Windows PowerShell 5.1, then runs:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

That command creates separate fresh standard, large and content workspaces, runs real-host browser checks and the large-library PowerShell workload, and saves separate JSON reports/screenshots. Fixture destinations must be new. See [Windows-Smoke.md](../Tests/Windows-Smoke.md) for workstation checks.

## Practical limits

- The portable host includes its runtime but still uses existing Windows PowerShell and native Windows components. Hosted tests cannot establish hospital access or approve endpoint policy, which may restrict executables, scripts, loopback browser access or scanner shares.
- Scanner collection needs the internal network. Saved reports, document filing, search and export work locally. An unavailable scanner or absent PDF does not establish a clinical QA failure.
- The interface uses loopback and bundled assets; no public website or automatic upload is required. Checks run only while the app runs. No installed service, scheduled task or closed-app notification is added.
- Cancellation is cooperative. A Windows network read already in progress may need to return before a safe checkpoint. Synthetic local work counters and timings do not predict hospital SMB speed, endpoint scanning or workstation load.
- Supported content profiles do not replace department policy or clinical review. OCR and department-specific numerical QA limits are not included. Receipt, document labels, extracted printed observations and formally reviewed checklist evidence remain separate.
- The readable library is a convenience copy. Metadata reuse speeds normal refresh; explicit verification rereads bytes. Same-drive copies do not protect against drive loss. Keep an approved separate backup.
- Windows-encrypted sign-ins may need re-entry after moving to another account/computer. Updates preserve local settings and data. Manifests detect inconsistent files but do not authenticate an unknown publisher; retained history is not a signed audit system.
- Physical keyboard/IME, folder pickers, DPI, very long paths, real hospital reports and scanner-share behavior still need approved workstation checks.
