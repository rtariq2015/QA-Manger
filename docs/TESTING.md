# Validation — CT QA Manager Pro 5.4.0

Final native source: `bb611aa93947bf01b0576616a34a5b44cbeda1a3`. Raw native test evidence: [https://github.com/rtariq2015/QA-Manger/actions/runs/43092551021](https://github.com/rtariq2015/QA-Manger/actions/runs/43092551021). Overall workflow status at staging: **completed**; conclusion: **success**. Passing raw test results do not assert that the overall workflow completed.

Public reports, scanner folders, credentials and screenshots use generated synthetic fixtures. User PDFs, extracted private text, private archive audits or aggregate findings, and workplace photographs are excluded from evidence, release previews and documentation.

| Execution | Scenarios or checks | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: eighteen native suites | 343 | 3,201 | 0 | [Native summary](../Tests/Current/Windows/Summary.json) and unchanged raw reports |
| Native reader comparison and cache reuse | 3 | 80 | 0 | [Reader benchmark](../Tests/Current/Reader-Benchmark-Windows.json) |
| Windows Edge: application and support workflow | 15 | 562 | 0 | [Main browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: generated 1,367-report library | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large-library interaction and cancellation | 5 | 27,347 | 0 | [Large browser report](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: document contents and automatic filing | 7 | 214 | 0 | [Content browser report](../Tests/Current/Browser-Content-Windows.json) |
| Windows Edge: portable Python and measurement trends | 6 | 208 | 0 | [Python browser report](../Tests/Current/Browser-Python-Windows.json) |
| Windows actual host with deterministic synthetic PowerShell adapter | 14 checks | Not reported | 0 | [Scheduler report](../Tests/Current/Background-Scheduler-Windows.json) |
| Linux PowerShell 7.4.13: eight development reports | 187 | 1644 | 0 | [Local summary](../Tests/Current/Summary.json) and unchanged raw reports |
| Linux actual host with deterministic synthetic adapter | 14 checks | Not reported | 0 | [Scheduler development report](../Tests/Current/Background-Scheduler-Linux.json) |
| Linux focused in-flight cancellation regression | 7 checks | Not reported | 0 | [Focused cancellation report](../Tests/Current/Background-Scheduler-Focused-Linux.json) |
| Retained earlier Linux Python worker protocol | 11 | Not reported | 0 | [Unchanged worker report](../Tests/Current/Python-Worker-Linux.json) |

The eight Linux PowerShell reports sum to **187 scenarios and 1644 assertions**. They were executed during development and do not embed a final commit hash. They therefore do not establish a Linux rerun of the final source. The native artifact independently pins all eighteen suites, all four Edge browser workloads, the scheduler and reader comparison to the final source. Native and Linux totals remain separate. Scheduler and worker outcomes without PowerShell assertion counters are excluded from suite/assertion sums.

Native Core runs 26 scenarios with 258 assertions. Linux Core runs 27 scenarios with 242 assertions, including a case-sensitive path-alias regression. Platform-specific branches produce different assertion totals; each summary retains its actual raw counts. The Linux focused seven-check cancellation run remains separate from the full fourteen-check scheduler run; the native fourteen-check scheduler also includes the corrected in-flight cancellation behavior. The eleven-case worker report retains its earlier unchanged-protocol scope and is not presented as a fresh execution.

The previous complete forty-file evidence collection is preserved unchanged in [Tests/Historical/v5.3.1](../Tests/Historical/v5.3.1). Older releases retain their own historical folders. Some raw Version fields describe a feature's introduction and remain unchanged. The native summary records exact source/run identifiers, host executable SHA-256, Python runtime artifact SHA-256, Python integrity manifest SHA-256 and validation artifact SHA-256.

## Automatic filing and the review queue

**Auto** is the default report-format policy. Compatible complete Basic and Extended manufacturer body formats can infer Daily and Monthly filing respectively. Explicit document labels, saved scanner overrides and supported archive grouping retain their own filing basis. Inferred filing is recorded as inferred; it does not create clinical approval or certify that a scanner passed. **Ask** explicitly leaves that format for individual review. Daily/Monthly/Other rules remain available as scanner-specific overrides.

The application separates **Waiting for reading**, **Needs review** and **Filed**. Unread documents belong to background reading rather than the Approve/Disapprove decision list. Manual decisions, previous formal reviews and Undo retain priority. Date/time/type conflicts, incomplete bodies, unsupported evidence and explicit Ask remain visible for a person. Approving one report does not silently teach a global rule.

Synthetic content tests cover exact compatible Edge, Flash and Drive headers; supported Basic, Extended and additional numbered IEC bodies; explicit Quality Daily sections; and bounded standalone test layouts. File size, page count, model name or a table of contents alone cannot establish a complete supported report. Footers must supply consistent dates/times where content-based filing requires them. Mixed, unknown, incomplete and contradictory evidence remains unresolved.

Auto files validated manufacturer reference documents as Other; saved manual decisions retain priority. References never count as current QA receipts or measurement trends. Anchored reference-section evidence also excludes current values when the overall template is still unknown; that weaker evidence does not turn an unresolved document into an automatically filed reference. Legacy cached numbers and old filing labels cannot override these exclusions. Synthetic regressions include reference headings outside tables of contents, mixed section families, unknown labels and old cached measurements.

## Background work and responsiveness

Ordinary **Read next 20 saved PDFs** retains its twenty-attempt limit. Explicit all-saved or pending-file queues can continue beyond twenty eligible files. They build a trusted eligibility plan, process one selected record at a time, and publish full overview/library checkpoints periodically. They rebuild the plan when foreground changes invalidate its generation. Compact per-PDF results avoid rebuilding and transmitting the entire archive overview after every read.

Fresh archive membership, selected identity, direct paths, file length/timestamp and parsed-byte SHA-256 remain checked. Supplied-record analysis avoids reconstructing coverage and attention data inside a PDF step. Directory validation can reuse existing safe ancestor directories only within one state read; every leaf is checked afresh, missing directories are never cached and reuse ends with that call. Regressions introduce linked leaves, parent changes between calls, missing-directory links, root-boundary cases and case-sensitive aliases.

Pause takes effect at a safe boundary; Resume continues the job. Stop retains completed results and does not count an interrupted PDF as completed or failed. Foreground review, search and export can run between background steps. Automatic reading starts only when work is eligible, and explicit Stop prevents automatic restart until the relevant user action clears that intent. Lower process priority and cooperative yielding reduce interference; they do not eliminate CPU or disk work.

The real-host scheduler tests use a deterministic synthetic adapter to isolate queue planning, duplicate rejection, sanitized internal flags, factual cumulative progress, foreground handoff, pause/resume, cancellation, cleanup, shutdown, automatic startup and stop intent. A 25-item queue exceeds the ordinary cap and completes readable-folder synchronization. Controlled counters record plan passes, full snapshots, library passes, completed records and cache skips. These adapter tests make no real PDF-reader speed claim.

## Selective cache upgrades and measurements

Measurement schema version remains **1**. Measurement capability revision **2** records the newer Daily and slice-thickness support separately. Older Daily or slice-containing evidence can receive one bounded upgrade attempt. Complete older Basic HU evidence remains reusable and graphable. Unsupported extraction still records the attempted revision, preventing repeated background retries. Existing read errors remain cached until an appropriate explicit retry or changed file; references are excluded from measurement-upgrade queues.

Supported printed tables can supply Water CT values and Image noise in HU, plus Slice thickness in mm. Daily sections support their validated table forms, and contexts keep mode, system, slice and source page separate. Associated printed limits remain distinct from measured values. Historical/reference values, scan parameters, ambiguous columns, incomplete input and unknown units are not substituted as current readings.

Trends uses complete, date-consistent verified readings and links to source pages. Uncertain limits stay absent. Printed failures and outliers remain visible with documentary warnings; no clinical PASS or calibrated drift diagnosis is invented. Conflicting aliases/timestamps are withheld rather than averaged. Coverage distinguishes unread, unsupported selected measurements and reference exclusions. Looking at a graph starts no hidden PDF reading.

Cache provenance remains bound to exact PDF hash, record identity, length and write time. Equal-content destinations retain independent provenance and upgrade revisions. Failed or interrupted work cannot replace prior verified evidence. Filing, derived dates and readable folders do not rewrite protected clinical archive fields.

## Shareable diagnostics and printing

Settings provides independent diagnostic-ZIP and printable-report links. The printable page opens separately and supports Ctrl+P without external assets or scripts. Both links remain available after later actions and snapshots. The ZIP contains exactly seven entries:

- `SupportReport.html` and `Support-Summary.json`.
- `Report-Diagnostics.csv` and `Report-Diagnostics.jsonl` with every diagnostic row in the snapshot.
- `Scrubbed-Activity.csv` and `Scrubbed-Activity.jsonl` with all retained supported structured events.
- `READ ME.txt` describing scope, sharing and retention.

Controlled fields separate filing basis, filing state and inferred grouping from text-cache status, measurement capability, reader status and reference exclusion. Numeric metadata includes page coverage, measurement counts, timing and support revisions. Independent waiting/review/filed/inferred counts make queue status interpretable. Operation events retain allowlisted stages, outcomes, reasons and numeric counters.

Every shareable field is rebuilt through allowlists. PDFs, extracted text, filenames, paths, report IDs/hashes, usernames, passwords, network addresses, workstation names, raw exceptions and unstructured logs are excluded. References such as Report0001 are regenerated per export and cannot serve as stable identities or a tamper-proof audit trail. Printable detail and recent activity are each capped at 500 with disclosed limits; full machine exports retain all available supported rows/events. Normal structured-log retention is bounded to 90 days and its storage budget.

Synthetic tests inject private sentinels into all new filing fields, configuration, caches, reviews and arbitrary events. They inspect every ZIP entry and printable output, verify atomic new exports and protected source files, and check safe fallback with malformed/unreadable state. Reference evidence forces zero current measurement counts even for an unresolved template with legacy numeric cache rows. Classic diagnostics perform that filtering while the PDF is exclusively locked, proving the export reads metadata/cache rather than reopening PDF contents.

## Browser workflows and continuous PDF rendering

Today, Reports, Review, Exports, Trends and Settings remain separate. Today distinguishes saved report receipt from clinical evidence and scanner access. Review offers Approve/Disapprove and Undo without requiring a name for file sorting. Exports has independent scanner/type/date/multi-year filters and preserves every matching PDF. Light/Dark settings persist with the portable workspace.

Actual Edge tests compare decoded native page pixels with the authenticated selected-page response, including report fingerprint, page and dimensions. Continuous rendering must reach the final page of a multi-page PDF without repeated Previous/Next controls. Lazy loading, bounded concurrent requests and bounded image caching keep the PDF navigable. Both review actions remain visible at 1024×768.

The four browser workloads also exercise authentication/origin rejection, offline-only assets, ordinary typing after mouse release, unsaved form preservation, password clearing, stale-decision rejection, exact filtered ZIP hashes, persistent Undo/theme state, diagnostic printing, automatic filing and foreground work during background reading. Their application APIs are not mocked.

## Portable readers and measured scope

The completed package includes its Windows x64 Python interpreter, standard library and pure-Python reader beside Standard/PdfPig. Work use requires neither Python installation nor pip. Versions and hashes appear in [Python build metadata](../Tests/Current/Python-Build-Windows.json). Python uses isolated imports, no site/bytecode writes and an application socket guard; that guard neither tests nor bypasses workplace firewall policy.

Both engines consume a bounded verified PDF buffer. Archive membership, indexed SHA-256, length and write timestamp are checked around the read. PDF paths/content are not exposed in Python command-line arguments or temporary PDF files. Native tests exercise the production bridge under a real standard Windows user, live cancellation/cleanup, input limits, image-only/encrypted files, changed bytes, damaged dependencies, explicit failures, automatic fallback and cache preservation. CI test-account setup does not mean the application creates Windows users or changes policy.

The native comparison uses identical generated Basic nine-page and Extended six-page PDFs, fresh isolated workers and alternating reader order. Qualification requires complete pages, supported body profiles, matching footer timestamps, observations and exact fingerprints. Across 12 cold reads, whole-read medians were **1370.557 ms for Standard** and **2036.892 ms for Python**. The faster reader in this fixture was **Standard**; the Standard/Python ratio was 0.673. Whole-read timing includes startup, transport, verification and parsing. Warm analysis proves zero new parses and zero cache writes. No hardware threshold, memory measurement or hospital SMB speed is claimed.

A separate [Linux development comparison](../Tests/Current/Background-Reading-Comparison-Linux.json) required 25 successful reads, zero failures,25 matching verified hashes and 25 complete PDF reads in both versions before recording results. Its 25 saved records use six distinct generated PDF hashes. Both core state and all PDF bytes stayed unchanged. It is one sequential comparison per version on a shared local machine, excludes failed-read attempts, does not pin the final source and does not establish native Windows, hospital SMB or 1,367-record throughput. It is excluded from suite/assertion totals.

## Large library, captures and reproduction

The generated large workload contains 1,367 saved reports. It tests exact folder ownership, cold copy/hash work, unchanged warm reuse, changed bytes with restored metadata, filtered export, browsing/reload while busy, duplicate refresh coalescing, cancellation and resumed completion. A synchronization barrier is inserted only into a disposable fixture's copied progress hook. Detailed support export remains independent of a held update. Original PDFs and protected archive state stay unchanged.

All **33 captures** are copied unchanged from the pinned native artifact. They include the six-tab Light/Dark views, compact-window and native-PDF views, large-library progress, support/printing, automatic filing and measurement trends. New views show [Daily readings](images/daily-readings-web-demo.png) and [Slice thickness trends](images/slice-thickness-trends-web-demo.png). They are actual application screenshots with synthetic data; the release preview selects 22 of these captures.

| Tab | Light | Dark |
| --- | --- | --- |
| Today | [Light](images/today-light-web-demo.png) | [Dark](images/today-dark-web-demo.png) |
| Reports | [Light](images/reports-light-web-demo.png) | [Dark](images/reports-dark-web-demo.png) |
| Review | [Light](images/review-light-web-demo.png) | [Dark](images/review-dark-web-demo.png) |
| Exports | [Light](images/exports-light-web-demo.png) | [Dark](images/exports-dark-web-demo.png) |
| Trends | [Light](images/trends-light-web-demo.png) | [Dark](images/trends-dark-web-demo.png) |
| Settings | [Light](images/settings-light-web-demo.png) | [Dark](images/settings-dark-web-demo.png) |

Other captures show [support details](images/support-activity-web-demo.png), [printing](images/support-print-web-demo.png), [automatic filing](images/automatic-filing-web-demo.png), [continuous PDF scrolling](images/content-continuous-pdf-web-demo.png), [format settings](images/content-settings-web-demo.png) and [source-linked measurements](images/trends-measurements-web-demo.png).

Build validation uses .NET SDK, dependency downloads and Node/Playwright as development tools. The work computer receives the completed offline package. The native workflow builds the self-contained host and pinned Python runtime, runs all eighteen suites, reader comparison and scheduler, exercises all four Edge workloads and captures WPF compatibility views. The browser command is:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

Fresh fixture destinations are required. [Windows-Smoke.md](../Tests/Windows-Smoke.md) describes the remaining work-computer checks.

## Release package validation

[Actual package checks](../Tests/Current/Package-Validation.json) passed all **880 checks** across the three generic ZIPs and two private local-only variants. Each packaged host matches the tested native executable, all 103 Python manifest components match, and package manifests exclude development files and live reports. Private variants are not release assets.

The existing version 5.3.1 updater actually staged and installed the normal 5.4.0 Update ZIP in a disposable fixture. Seven configuration, credential-file, data, archive, organization-history and prior-log sentinels remained byte-identical; a previous-program backup exists and staging was cleaned. Generic/private one-time helpers and the standalone diagnostic collector also passed. These are Linux ZIP/PowerShell installation-logic checks; Windows executable execution is established separately by the native run. The package checks do not contribute to suite/assertion totals.

## Practical limits

- Hosted Windows validation does not approve endpoint policy or establish scanner-share access. The workstation must permit its completed executable/scripts and local browser connection.
- Scanner collection needs the internal network. Saved filing/review/export work locally. Missing files or unavailable scanners do not establish clinical QA failure.
- Automatic inferred document filing does not replace department frequency policy, complete Monthly evidence or clinical QA review. Image-only OCR and universal template/table recognition are not included.
- One-PDF processing and yielding still consume CPU/storage. Cancellation is cooperative; an active Windows read may return before its safe checkpoint. Memory and real workload speed remain workstation-dependent.
- Closing the app stops local helpers. Nothing uploads automatically, and no service or scheduled task is installed. Keep a separate approved backup; same-drive readable copies do not protect against disk loss.
- Moving Windows account/computer may require scanner sign-in again. Updates preserve data/settings; checksums detect inconsistency rather than authenticating an unknown publisher.
- Keyboard/IME, DPI, folder dialogs, long paths, further report variants and scanner access still need appropriate workstation checks.
