# Validation — CT QA Manager Pro 5.5.0

Final source: `0199b05bf0e52cc12ca03d576a2583ebe736cb9a`. Completed successful native workflow: [https://github.com/rtariq2015/QA-Manger/actions/runs/43117160248](https://github.com/rtariq2015/QA-Manger/actions/runs/43117160248).

All public evidence uses generated PDFs, local synthetic scanner folders and synthetic identities. Private reports, extracted private text, private corpus audit aggregates, workplace profiles and workstation photographs are excluded. Raw evidence is copied without relabeling or changing its bytes.

| Execution | Scenarios or checks | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: eighteen fresh native suites | 376 | 3,654 | 0 | [Native summary](../Tests/Current/Windows/Summary.json) |
| Native reader comparison and cache reuse | 3 | 80 | 0 | [Reader benchmark](../Tests/Current/Reader-Benchmark-Windows.json) |
| Windows Edge: application, calendar and support | 17 | 681 | 0 | [Main browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: generated 1,367-report library | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large-library filtering and grouped review | 6 | 27,376 | 0 | [Large browser report](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: contents, targets and automatic filing | 8 | 246 | 0 | [Content browser report](../Tests/Current/Browser-Content-Windows.json) |
| Windows Edge: portable Python and measurement trends | 7 | 265 | 0 | [Python browser report](../Tests/Current/Browser-Python-Windows.json) |
| Native cached-metadata calendar rules | 7 | Not reported | 0 | [Calendar report](../Tests/Current/Calendar-Windows.json) |
| Native host scheduler, live-reader controls and timeout cleanup | 18 checks | Not reported | 0 | [Scheduler report](../Tests/Current/Background-Scheduler-Windows.json) |
| Linux PowerShell 7.4.13: six changed development suites | 168 | 1469 | 0 | [Local summary](../Tests/Current/Summary.json) |
| Linux host scheduler, live-reader controls and timeout cleanup | 18 checks | Not reported | 0 | [Scheduler report](../Tests/Current/Background-Scheduler-Linux.json) |
| Linux calendar: the same seven rules repeated in three timezones | 7 unique rules; three runs | Not reported | 0 | [Default](../Tests/Current/Calendar-Linux-Default.json), [New York](../Tests/Current/Calendar-Linux-New-York.json), [Tokyo](../Tests/Current/Calendar-Linux-Tokyo.json) |
| Separate final Linux production-reader controls | Three repeated control cases plus final invariants | Not reported | 0 | [Final controls](../Tests/Current/Real-Reader-Final-Controls-Linux.json) |
| Retained earlier Linux Python worker protocol | 11 | Not reported | 0 | [Unchanged worker report](../Tests/Current/Python-Worker-Linux.json) |

Only Analysis, Measurements, Trends, Content Integration, WebService and Support contribute to the fresh Linux PowerShell total of **168 scenarios / 1469 assertions**. Unchanged earlier local Core/Content reports remain historical and are not summed as new executions. Development raw reports do not embed final commit hashes, so they do not establish a Linux rerun of the final source. The completed native workflow independently pins all eighteen suites and all four Edge workloads to its source/run and tested artifact digests.

Calendar and scheduler checks have no PowerShell assertion counters and remain separate. The full 18-group Linux scheduler passed on the 15-second cadence before a counter-only correction; the separate final controls confirm that warm-cache skips count zero inline parsing, completed readings appear in foreground snapshots and exported PDFs preserve exact bytes. Fresh native execution establishes the complete scheduler behavior on final source. The same seven calendar rules run in the default timezone, America/New_York and Asia/Tokyo; this is not 21 unique rules. The retained eleven-case worker protocol report keeps its original unchanged-protocol scope. Previous complete evidence is preserved unchanged under [Tests/Historical/v5.4.0](../Tests/Historical/v5.4.0), including its 41 files. Some raw Version fields identify an earlier feature introduction and are preserved.

## Grouped file decisions and durable Undo

Review separates files waiting for reading, files needing a decision and files already filed. Pending decisions can be grouped by controlled reasons: manual policy, read errors, reference evidence, conflicting evidence, unsupported formats, Undo restoration or other review. Opaque local grouping keys never enter shareable support data.

Selections are capped at 50 and bind each exact report identity to its current stamp. Before saving a group, the backend validates current state/history and holds exact verified PDF handles. A stale selection, changed PDF, unsafe path or invalid filing target rejects the batch before its filing decisions are committed. Clear Daily/Monthly/Other targets remain available; an ambiguous report type requires an explicit choice rather than silently choosing a different category.

Saved file decisions and whole-batch Undo persist across restart. Undo retains the original PDFs and respects intervening changes. Readable-copy refresh is limited to selected records. Copy warnings are recorded separately from the counts of decisions actually saved. Approve/Disapprove still sorts documents without requesting a reviewer name for that file-organization task. It does not approve clinical QA, complete a Monthly checklist or teach a new global scanner rule.

Tests cover the 50-item bound, single-selection array handling, mixed explicit targets, stale stamps, state/history/byte changes, held file handles, exact selected-only refresh, post-save copy warnings and durable Undo. Windows exercises its actual share-denial behavior. Linux evidence accepts either enforced sharing or pre-commit metadata rejection without a write; it is not described as native Windows lock validation.

## Daily receipt calendar

The calendar uses existing snapshot metadata only: it does not read PDFs or contact scanners. It applies configured AllDays/Weekdays/Off schedules, active dates and exclusions. Valid filed Daily reports supply saved receipt; pending, Monthly, reference and suspected-reference documents do not. Scanner connection state remains distinct from already-saved evidence.

Future dates are neutral and do not increase received/missing totals. Off-schedule saved reports remain available without inventing an expected test. UTC date construction handles leap years and month boundaries without local-timezone shifts. Tests also cover scanner isolation, malformed dates, duplicate identities and snapshot preservation. Calendar status describes the archive and schedule, not whether clinical tests were performed or passed. Monthly reviewed evidence remains separate.

The helper is bundled into the existing application JavaScript resource. This avoids introducing a new shipped resource that an earlier portable updater would reject. The Folders tab browses managed saved reports without exposing arbitrary filesystem paths. The calendar can lead to date-filtered Reports or Exports without changing stored data.

## Printed measurements and trends

Measurement schema remains 1; capability revision 3 adds four alignment families in mm: Lightmarker, External lightmarker, Sagittal/Coronal lightmarker and Topogram position. Sagittal and coronal values retain separate axis context. Existing Water CT values, Image noise and Slice thickness remain available. The browser menu has seven metric families, with distinct series for their supported contexts.

Only validated printed result forms supply values and associated limits. Headers, page/section context and full read/date evidence must agree. Scan parameters, historical/reference values, ambiguous columns and unsupported layouts are excluded. Reference evidence blocks current readings even when an overall document template remains uncertain or older caches contain numeric values. No numerical clinical PASS or vendor tolerance is invented.

Capability upgrades use introduction thresholds: older Daily/Slice evidence can receive the revision 2 capability once; revision 3 targets only its four alignment sections. Existing revision 2 Daily/Slice and complete Basic HU caches remain warm. Unsupported attempts record their current capability revision and do not loop automatically. Manual filing decisions and formal clinical evidence remain untouched.

Trends separates scanner, mode, system, slice and axis contexts, shows printed limits where reliable and links values to exact source pages. Outliers and printed failures remain documentary warnings. Conflicting aliases/timestamps are withheld rather than averaged. Merely opening a graph starts no hidden PDF reading.

## Background reading and timing scope

The host retains one-PDF checkpoints, a trusted eligibility plan and foreground handoff. Internal inline-reader controls remain restricted to validated one-record background steps. Archive membership, exact bytes/hash, direct paths and metadata are still verified under the reader lock. Classic or explicit paths retain their own isolation behavior; the optimization does not authorize arbitrary caller paths or bypass the local API boundary.

The full scheduler regression combines synthetic-adapter orchestration with actual production-reader control/trust-boundary checks and an actual unresponsive-helper/child cleanup timeout. It checks pause/resume, Stop intent, interrupted pending totals, cleanup and completion beyond the ordinary twenty-item bound. These checks establish control behavior rather than hospital PDF throughput.

Scrubbed counters distinguish outer helper time, read-worker time, engine time, parsing/cache work, worker starts and cache writes. They are nonnegative bounded integers. Their intervals can overlap; they must not be added as independent stages or interpreted as a hardware guarantee.

A separate [quiet paired development comparison](../Tests/Current/Background-Reading-Comparison-Linux.json) requires 25 analyzed / 0 failed / 0 read errors, 25 matching verified hashes and 25 complete reads in both versions, plus the same synthetic input manifest. It is separate from suite/assertion totals and makes no hospital or general Windows throughput claim.

The separate native reader comparison uses identical generated Basic nine-page and Extended six-page PDFs, fresh isolated workers and alternating reader order. Every qualifying sample requires complete pages, expected profiles/dates and exact fingerprints. Across 12 reads, whole-read medians were **1792.477 ms for Standard** and **2534.18 ms for Python**; **Standard** was faster for that fixture. Whole-read time includes startup, transport, verification and parsing. Warm reuse performs zero new parses and zero cache writes. No memory, hardware-threshold or hospital SMB claim is made.

## Shareable diagnostics and printing

The support ZIP still has seven entries: printable HTML, structured summary, complete report CSV/JSONL, complete retained structured-activity CSV/JSONL, and sharing instructions. Independent ZIP and printable links remain available after later operations. The printable page supports Ctrl+P with no scripts or external assets.

New controlled fields retain pending-review reason groups, selected/approved/disapproved/undone/rejected/copy-failed counts, total duration and agreed numeric performance counters. New metric diagnostics retain counts, statuses and capability revisions rather than raw measurement values. Saved decisions and copy warnings remain separate outcomes.

Private strings, PDF text/files, paths, filenames, names, credentials, network addresses, hashes, record IDs, stamps, batch IDs and opaque grouping keys are excluded. All fields are reconstructed through allowlists. Synthetic regressions inject these values into batch history, grouping fields, counter values and arbitrary timing objects. Formulas, negative/fractional/overflow values and unknown keys cannot pass through to any ZIP entry or print view.

Report aliases are regenerated per export. Printable detail and recent activity are each capped at 500 with disclosed limits; full machine exports preserve all supported retained rows/events. Normal logs retain up to 90 days within their storage budget. This is retained structured history, not a promise that every past action was recorded or a signed audit trail.

## Native execution, preservation and captures

The native workflow builds the self-contained Windows host and pinned portable Python runtime, executes all eighteen suites, runs four actual Edge workloads, the reader comparison and scheduler, and captures WPF compatibility views. Production Python is tested under an actual standard Windows user with live cancellation and cleanup. CI-only test-account provisioning does not mean the application changes work-computer accounts or policy.

The 1,367-record synthetic workload retains folder ownership, exact export, warm-cache reuse, changed-byte detection, cancellation/resume, grouped review and stale-selection behavior. Original PDFs, clinical archive fields, settings and prior history remain protected. New support privacy tests retain the existing seven-entry package, 500-row print caps, bounded log retention and metadata-only fallback while a PDF is exclusively locked.

All **39 screenshots** are copied unchanged from final native captures. Existing Light/Dark seven-tab, compact PDF, support and trend views are joined by [calendar receipt](images/daily-calendar-web-demo.png), [grouped review](images/grouped-review-web-demo.png) and [Monthly alignment trends](images/monthly-alignment-trends-web-demo.png). They use generated data, not workstation photographs or design mockups. The release preview selects 27 embedded views: 14 theme views and 13 detail views.

| Tab | Light | Dark |
| --- | --- | --- |
| Today | [Light](images/today-light-web-demo.png) | [Dark](images/today-dark-web-demo.png) |
| Reports | [Light](images/reports-light-web-demo.png) | [Dark](images/reports-dark-web-demo.png) |
| Review | [Light](images/review-light-web-demo.png) | [Dark](images/review-dark-web-demo.png) |
| Exports | [Light](images/exports-light-web-demo.png) | [Dark](images/exports-dark-web-demo.png) |
| Folders | [Light](images/folders-light-web-demo.png) | [Dark](images/folders-dark-web-demo.png) |
| Trends | [Light](images/trends-light-web-demo.png) | [Dark](images/trends-dark-web-demo.png) |
| Settings | [Light](images/settings-light-web-demo.png) | [Dark](images/settings-dark-web-demo.png) |

Fresh fixture destinations are required. Browser reproduction uses `node Tests/Web/run-all.cjs --windows --output artifacts/web`; [Windows-Smoke.md](../Tests/Windows-Smoke.md) describes remaining workstation checks. Build-time SDK/dependency downloads are development tooling; the user receives the completed offline package.

## Packaged updates and preservation

The actual five completed ZIPs passed **1,729 package checks with zero failures: [Package validation](../Tests/Current/Package-Validation.json). Their executable matches the tested native host, and all 103 Python components match the tested integrity manifest. The existing **5.4.0 updater** staged and installed the **5.5.0 Update ZIP**, preserved all seven synthetic configuration/data/credential/archive/history/log sentinels, retained a previous-program backup and cleaned staging. Generic and private one-time upgrades and the standalone diagnostic collector also passed. Private configured packages remain local and are excluded from Releases. These are Linux/PowerShell ZIP and staging checks; Windows executables were exercised separately in the native workflow.

## Practical limits

- Hosted validation does not approve workplace endpoint policy or establish real scanner-share access. The workstation must allow the completed scripts/executable and its local browser connection.
- Scanner collection needs the internal network; saved filing, review and export work locally. Missing reports or unavailable scanners do not establish clinical QA failure.
- Automatic inferred file grouping and receipt calendars do not replace department frequency policy, Monthly evidence or clinical review. Unsupported formats and image-only OCR can still require a person.
- Background work still consumes CPU/storage; cancellation is cooperative. Completed results remain saved, and interrupted work is not falsely counted as completed.
- No service or scheduled task is installed, and nothing uploads automatically. Keep a separate approved backup. Moving Windows account/computer can require scanner sign-in again.
- Updates preserve data/settings; checksums detect inconsistency rather than authenticating an unknown publisher. Additional report variants, keyboard/IME, DPI, long paths and actual scanner access still need appropriate workstation checks.
