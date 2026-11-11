# Testing and practical limits

Final v5.3.0 Windows validation passed at source `5400798e55e4895fd16f5b9f575401ac52aef089` in [the recorded workflow](https://github.com/rtariq2015/QA-Manger/actions/runs/43043750417). All public test PDFs, scanner folders, identities and password canaries are generated synthetic data. Uploaded private reports, their text and workplace screenshots are excluded from repository evidence and release previews.

| Execution | Scenarios | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: eighteen native suites | 283 | 2,333 | 0 | [Windows summary](../Tests/Current/Windows/Summary.json) and unmodified raw reports |
| Windows PowerShell: separate reader comparison and warm-cache checks | 3 | 80 | 0 | [Reader benchmark](../Tests/Current/Reader-Benchmark-Windows.json) |
| Windows Edge: standard actual-host workflow | 14 | 475 | 0 | [Standard browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: 1,367-report library workload | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large-library progress and cancellation | 4 | 27,328 | 0 | [Large browser report](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: content and per-scanner format workflow | 5 | 130 | 0 | [Content browser report](../Tests/Current/Browser-Content-Windows.json) |
| Windows Edge: Python reading, printed measurements and reader preferences | 4 | 118 | 0 | [Python browser report](../Tests/Current/Browser-Python-Windows.json) |
| Linux PowerShell 7.4.13: seven targeted development suites | 100 | 585 | 0 | [Current summary](../Tests/Current/Summary.json) and seven raw `Run-*.json` reports |
| Windows actual-host scheduler with a deterministic synthetic PowerShell adapter | 9 checks | Not reported | 0 | [Scheduler report](../Tests/Current/Background-Scheduler-Windows.json) |
| Linux actual-host scheduler with a deterministic synthetic PowerShell adapter | 9 checks | Not reported | 0 | [Scheduler development report](../Tests/Current/Background-Scheduler-Linux.json) |
| Linux Python: worker protocol cases | 11 | Not reported | 0 | [Worker protocol report](../Tests/Current/Python-Worker-Linux.json) |

Native counts above come from the successful final pinned artifact. Linux evidence is separately labeled development execution; its raw reports do not embed commit hashes. The worker report gives eleven scenario outcomes without an assertion counter. Each separate scheduler report gives nine check outcomes from the real host with a deterministic synthetic PowerShell adapter; it does not exercise actual PDF-reader speed. These outcomes are kept out of the PowerShell suite totals. The complete prior v5.2.0 evidence remains under [Tests/Historical/v5.2.0](../Tests/Historical/v5.2.0), with earlier releases in their own historical folders. Stale Linux reports are removed from Current rather than relabeled. Some raw Version fields identify feature introduction and are preserved unchanged. Exact Windows host, Python runtime artifact, optional Python integrity manifest and validation-artifact SHA-256 values are recorded in the Windows summary.

## Six tabs, both themes and continuous PDF review

The browser rebuild retains the original program's local archive and export capabilities while separating **Today, Reports, Review, Exports, Trends and Settings**. Today distinguishes saved Daily receipts, scanner access and department Monthly evidence. Reports searches the library; Exports keeps its own filters, including multiple years, and includes every matching report. Review uses one-click Approve/Disapprove for the suggested file type without asking for a name. These filing decisions do not approve clinical QA or replace formal evidence. Light/Dark is saved with the portable workspace.

Native Windows Edge checks verify a continuously scrolling PDF with more than the first page rendered. The dedicated content report must set `nativeContinuousPreviewActuallyRun: true`; the continuous-view screenshot is required from that same successful native artifact. Lazy page loading and bounded image caching keep the full document navigable without loading every image into memory at once. Source-page links from Trends open the matching original saved report and page.

Background reading works one PDF at a time, at lower process priority, and yields between files so foreground review and export can proceed. Pause takes effect at a safe boundary; Resume continues; Stop retains completed readings. A batch stops after **twenty actual read attempts** and reports work remaining for a later batch. Duplicate background jobs are rejected, and a selected one-PDF read remains a foreground action. The real-host scheduler checks exercise cumulative progress, pause/no further helpers, foreground priority, duplicate-job rejection, safe cancellation, the twenty-attempt bound and shutdown using a deterministic PowerShell adapter. This isolates scheduling behavior and supplies no measurement of real PDF parsing speed.

## Portable Python reading and the measured comparison

The program bundles its Windows x64 Python interpreter, standard library and pure-Python PDF reader. Normal use does not install Python or run pip. The source-pinned dependency versions and hashes are retained in [the native Python build metadata](../Tests/Current/Python-Build-Windows.json). Python runs with isolated imports, site disabled and bytecode writes disabled. It blocks its own socket operations. That is an application guard, not a test of operating-system firewall rules or a bypass of workplace restrictions.

Both engines consume the same bounded, already-verified PDF buffer. The production path validates archive membership, indexed SHA-256, file length and write timestamp, then verifies the returned reader fingerprint and metadata before saving derived results. PDF bytes and paths do not become Python command-line arguments or temporary PDF files. Python failure or unavailability can use the verified alternate path in Automatic mode; an explicit unavailable Python selection reports an error. The saved inspector identifies the actual reader and isolated read duration.

The native production suite exercises the bundled interpreter under an actual standard Windows user and observes a Boolean non-administrator result. It also tests live cancellation, child-process cleanup, page/character/size limits, image-only and encrypted input, changed saved bytes, damaged reader dependencies, explicit failure, Automatic fallback, legacy-cache preservation and input hashes. Setup of an ephemeral test account happens only inside elevated CI infrastructure. The portable application does not create users or change execution policy, UAC or firewall configuration.

The separate reader comparison uses identical generated **Basic nine-page and Extended six-page** PDFs, a fresh PowerShell worker for each sample, and alternating reader order. All qualifying samples must retain complete page counts, the expected body profile, consistent footer date/time, printed section observations and exact input hashes before timing is compared. Across 12 cold reads, the measured whole-read median was **1689.885 ms for Standard** and **2475.332 ms for Python**. The faster reader for this fixture was **Standard**, with Standard median divided by Python median equal to 0.683.

Whole-read timing includes worker startup, validation, transport and parsing; lower-level reader timing is recorded separately. These are local synthetic measurements, without an artificial pass/fail speed threshold. They do not measure memory, hospital SMB latency, endpoint scanning, scanner performance or every real report layout. A repeated analysis batch verifies that both cached documents are reused with **zero new parses and zero cache writes**. The numerical comparison is evidence for this fixture, not a promise of a universal speed increase.

## Printed measurements and filing remain separate

Supported single-metric Siemens IEC tables can supply current **Water CT values and Image noise in HU**, their explicitly printed limits, test mode, system, slice and page. Parenthesized reference values, scan parameters and other numeric tables are not substituted for current measurements. Bounds are displayed only when explicitly associated with that table. Missing structure, shared columns, conflicting identities, reversed bounds, inconsistent units, ambiguous separators, incomplete text and unsupported templates remain visible for review. No inferred clinical PASS, reviewer identity or department sign-off is created.

The browser workload reads an actual generated three-page Basic PDF through the bundled Python engine and verifies its two current values, printed limits and context in the inspector. It exercises the reader preference, unsaved changes across a real background snapshot, one-click Approve/Disapprove controls, Undo, a switch to Standard, a selected reread and warm-cache reuse. Both decision buttons remain visible at 1024×768 with measurements open. Original scanner and archived bytes and the complete clinical archive state remain unchanged.

Report layouts are recognized from complete numbered body sections. A table of contents, file size or page count is insufficient. A recognized layout defaults to Ask unless the department saves a scanner-specific Daily/Monthly/Other filing rule. One-file approval does not teach a rule for every report. Supported explicit Daily/Monthly document titles are handled as document labels. Existing manual decisions, valid prior reviews and Undo retain priority.

Only consistent report-footer timestamps from a complete read can supply missing filing dates. A disagreeing indexed filename date is preserved and requires review. Conflict tests include contradictory footers behind an explicit Monthly filename and a printed Daily title that disagrees with a saved Monthly rule. Accepted derived dates drive filters, readable folders, CSV/HTML inventories and ZIP paths without rewriting core clinical fields.

## Trends: current printed readings with provenance

Water CT number and image-noise readings stay separate by scanner, Head/Body mode, system and slice. The graph uses complete, date-consistent saved evidence with an unambiguous current numeric value; reference values are excluded and metrics remain separate. Confirm other protocol settings are consistent before interpreting a change. Only associated limits explicitly printed in the source PDF are displayed. A clear current value can remain visible when limits are missing or uncertain, with a review warning and no invented range.

Printed failures and values outside printed limits remain visible with warnings. A document-level review flag does not silently remove those readings or make a trend look normal. Obsolete revisions, identical-content aliases and identical timestamp/value copies are handled conservatively; contradictory values for one context/time are withheld and counted rather than averaged. Separate reader-cache aliases for the same PDF cannot select an arbitrary conflicting value. Conflicting dates and incomplete reads are excluded with coverage information.

The displayed change means the latest minus the first reading in the selected period. It is not a calibrated baseline, a clinical drift diagnosis or a new PASS/FAIL decision. Query summaries cover the full available selected series before the plotted-point cap; truncation is disclosed. Viewing Trends reads verified cached metadata and starts no PDF reading. Explicit measurement collection is bounded to selected saved reports, reuses current caches and keeps failed or unsupported evidence visible without an automatic reread loop. Synthetic regressions cover read-only archive access, provenance changes, grouping, revision and duplicate handling, unusual values, missing limits, date conflicts, bounded pending IDs and full-period summaries under plotting limits.

## Cached evidence, archive protection and actual workflows

Schema-3 analysis records the requested and actual reader, reader version, elapsed isolated work and conservative measurement output. Successful cache provenance remains bound to the actual parsed PDF hash, record identity, length and write timestamp. Equal-content destinations retain independent metadata. Cancelled or inconsistent reads cannot replace prior verified evidence. Full PDF text is not persisted in the analysis cache.

Earlier successful classifications remain reusable during normal background work. A selected Read contents action can upgrade that selected report with current reader/measurement evidence, and an explicit reader preference change is honored on the next selected read. The application avoids forcing an immediate full-library reread simply because new measurement features became available. Read failures and unsupported or incomplete evidence are cached with explicit status until a change or appropriate retry.

The eighteen native suites retain archive revision/lock/recovery checks, department Monthly checklist evidence, filtered exports, protected Windows sign-ins, scrubbed support logs, portability, verified backup/restore and offline updates. Python-enabled package tests keep payload admission narrow, check the expected runtime and reader files and preserve existing settings/data. Standard browser tests retain authentication/origin guards, bundled assets, keyboard typing and drafts, native PNG rendering, stale decisions, restart persistence and exact filtered ZIP hashes. Application APIs in the browser suites are not mocked.

The large synthetic workload retains 1,367 PDFs: 1,050 automatically filed, 217 pending, 81 approved and 19 disapproved. A cold readable-library batch verifies 2,734 hash operations and commits one ownership ledger. An unchanged warm batch performs zero PDF hash reads, copies or ledger writes. Explicit integrity verification detects altered bytes even with restored length/timestamp. These counters verify work performed rather than hardware-dependent completion times.

A barrier is inserted only into a disposable fixture's copied progress checkpoint. The real archive loop and cooperative cancellation verify factual counters, duplicate Refresh coalescing, browsing/reload while busy, safe cancellation, resumed completion and an independently downloadable support ZIP while Refresh remains held. The dedicated support link survives later job notifications.

The **twenty-eight documentation captures** come from the successful final Windows workflow: all twelve six-tab Light/Dark views, seven main-view and small-window captures retained for existing links, two large-library captures, three content captures including native continuous scrolling, and four Python/measurement captures including Trends. They are actual synthetic interface captures copied unchanged from the workflow; workplace photographs and fabricated mockups are excluded.

| Tab | Light | Dark |
| --- | --- | --- |
| Today | [Light](images/today-light-web-demo.png) | [Dark](images/today-dark-web-demo.png) |
| Reports | [Light](images/reports-light-web-demo.png) | [Dark](images/reports-dark-web-demo.png) |
| Review | [Light](images/review-light-web-demo.png) | [Dark](images/review-dark-web-demo.png) |
| Exports | [Light](images/exports-light-web-demo.png) | [Dark](images/exports-dark-web-demo.png) |
| Trends | [Light](images/trends-light-web-demo.png) | [Dark](images/trends-dark-web-demo.png) |
| Settings | [Light](images/settings-light-web-demo.png) | [Dark](images/settings-dark-web-demo.png) |

Further captures show [the pending library](images/large-library-pending.png), [active update](images/large-refresh-progress.png), [content evidence](images/content-basic-web-demo.png), [continuous native PDF scrolling](images/content-continuous-pdf-web-demo.png), [report-format settings](images/content-settings-web-demo.png), [printed measurements](images/python-measurements-web-demo.png), [small-window measurements](images/python-measurements-small-web-demo.png), [reader preferences](images/python-reader-settings-web-demo.png) and [measurement Trends with source-page links](images/trends-measurements-web-demo.png).

Support bundles reconstruct allowlisted counts, outcomes, timings and Windows error numbers. Synthetic canaries test that passwords, report contents, filenames, paths, usernames, addresses and raw logs do not enter shareable bundles. Nothing is uploaded automatically.

## Reproducing checks

Build/test validation uses the .NET SDK, Python dependency downloads and Node/Playwright. These are development tools and build-time network requests; the work computer receives the completed offline bundle. The Windows workflow builds the self-contained host and pinned Python reader, runs eighteen native suites and the separate reader comparison, then runs:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

That creates fresh standard, large, content and Python measurement workspaces, runs the real-host browser suites and separate large-library workload, and saves JSON reports and screenshots. The Python browser suite includes actual native reading, displayed measurements, Trends and source-page navigation. The content suite separately establishes native continuous PDF rendering. Fixture destinations must be new. See [Windows-Smoke.md](../Tests/Windows-Smoke.md) for workstation checks.

## Practical limits

- The portable host and Python include their runtimes but still use existing Windows components. Hosted tests cannot approve endpoint policy or establish hospital access. A successful small Python probe on one workstation does not automatically establish approval of every future module or the entire rebuilt application.
- Scanner collection needs the internal network. Saved reports, document filing, search and export work locally. An unavailable scanner or absent PDF does not establish clinical QA failure.
- The interface uses loopback and bundled assets; no public website or automatic upload is required. Checks run only while the app runs. No installed service, scheduled task or closed-app notification is added.
- Cancellation is cooperative. A Windows network read already in progress may need to return before a safe checkpoint. Local fixture timings do not predict hospital SMB speed, endpoint scanning or workstation load.
- Trend change is a documentary latest-minus-first difference, not a calibrated baseline or a clinical drift diagnosis. Printed limits and outlier warnings do not replace department policy or clinical review.
- Supported layouts and measurement tables do not replace department policy or clinical review. Image-only OCR, universal table recognition and department-specific numerical QA decisions are not included. Receipt, file labels, raw printed observations, numeric readings and formally reviewed checklist evidence remain separate.
- The readable library is a convenience copy. Metadata reuse speeds normal refresh; explicit verification rereads bytes. Same-drive copies do not protect against drive loss. Keep an approved separate backup.
- Windows-encrypted sign-ins may need re-entry after moving to another account/computer. Updates preserve local settings and data. Manifests detect inconsistent files but do not authenticate an unknown publisher; retained history is not a signed audit system.
- Physical keyboard/IME, folder pickers, DPI, very long paths, real report variants and scanner-share behavior still need appropriate workstation checks.

The large-browser raw summary does not embed a browser-channel field. Its Edge execution is established by the pinned Windows workflow invoking `run-all.cjs --windows`, whose large-workload arguments select `--browser-channel msedge`, and by the successful launch in `run-large-e2e.cjs`. Raw evidence is retained unchanged.
