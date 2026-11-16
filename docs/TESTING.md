# Validation — CT QA Manager Pro 5.6.0

> This page records the published 5.6.0 baseline. Unreleased engineering changes have a separate [branch validation report](ENGINEERING-VALIDATION.md); fresh native branch outcomes are attached to the pull request checks. Historical results below are not new branch test runs.

Final source: `bea7a3ef62ad6db598ec1d27ee8bfc2a70b16980`. Completed successful native workflow: [https://github.com/rtariq2015/QA-Manger/actions/runs/43135344109](https://github.com/rtariq2015/QA-Manger/actions/runs/43135344109).

Public evidence uses generated reports, synthetic scanner folders and synthetic identities. No actual workstation support logs, private PDFs, extracted private text, credentials, network profiles, corpus aggregates or workplace photographs are included. Raw reports and screenshots retain their original bytes.

| Execution | Scenarios | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell5.1: eighteen suites | 397 | 3970 | 0 | [Raw/summary](../Tests/Current/Windows/Summary.json) |
| Native reader comparison | 3 | 80 | 0 | [Raw/summary](../Tests/Current/Reader-Benchmark-Windows.json) |
| Windows Edge: main | 18 | 826 | 0 | [Raw/summary](../Tests/Current/Browser-Web-Windows.json) |
| Generated large library | 4 | 5463 | 0 | [Raw/summary](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large library | 6 | 27395 | 0 | [Raw/summary](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: content | 9 | 290 | 0 | [Raw/summary](../Tests/Current/Browser-Content-Windows.json) |
| Windows Edge: Python/trends | 9 | 365 | 0 | [Raw/summary](../Tests/Current/Browser-Python-Windows.json) |

The final native workflow also passed 18 scheduler check groups and 7 cached calendar rule checks. Those outcomes, four browser workloads, large-library checks and the reader comparison are separate from the eighteen native PowerShell suite totals.

- Controller rules: 7 scenarios / 25 JavaScript assertions; [raw](../Tests/Current/Trends-Refresh-Controller-Windows.json). This is controller-only Node execution on the native runner, not a browser or PowerShell suite.

| Fresh changed development suite | Scenarios | Assertions | Evidence |
| --- | ---: | ---: | --- |
| Run-AnalysisTests | 22 | 184 | [Fresh raw](../Tests/Current/Run-AnalysisTests.json) |
| Run-MeasurementTests | 34 | 171 | [Fresh raw](../Tests/Current/Run-MeasurementTests.json) |
| Run-TrendTests | 27 | 112 | [Fresh raw](../Tests/Current/Run-TrendTests.json) |
| Run-ContentIntegrationTests | 17 | 496 | [Fresh raw](../Tests/Current/Run-ContentIntegrationTests.json) |
| Run-WebServiceTests | 55 | 475 | [Fresh raw](../Tests/Current/Run-WebServiceTests.json) |
| Run-MonthlyTests | 24 | 144 | [Fresh raw](../Tests/Current/Run-MonthlyTests.json) |

Only these explicitly supplied fresh development reports contribute to **179 scenarios / 1582 assertions**. Their raw files do not pin final source, so this is not a final-source Linux rerun claim. The completed native workflow independently pins its fresh suites, browser workloads and tested binaries/runtime.

- Controller (FreshDevelopment): 7 scenarios / 25 separate assertions; [raw](../Tests/Current/Trends-Refresh-Controller-Linux.json). Separately scoped outcomes; not part of the fresh PowerShell suite totals.
- DevelopmentBrowser (FreshDevelopment): 5 scenarios / 219 separate assertions; [raw](../Tests/Current/Focused-Metrics-Browser-Linux.json). Actual Linux Chromium/offline host and Standard reader; only the focused new-metric/snapshot scenarios ran. Bundled Windows Python and the first four complete-workload scenarios were not executed. Separate from PowerShell and final native browser totals.
- DevelopmentBrowser (FreshDevelopment): 1 scenarios / 50 separate assertions; [raw](../Tests/Current/Focused-Grouped-Review-Browser-Linux.json). One actual Linux Chromium/offline-host grouped-review regression: direct checkbox focus, a forced reading snapshot, stale all-or-none rejection, grouped save and restart Undo preserve clinical/PDF state. Only the updated case ran; this is not the full six-case native Large workload and is excluded from PowerShell/native browser totals.

Previous Current evidence remains byte-exact in [Tests/Historical/v5.5.0](../Tests/Historical/v5.5.0), including all 43 files. Unchanged previous reports are historical unless explicitly identified above as retained. Retained outcomes are not counted as fresh development scenarios or assertions.

## Monthly workspace and workflow scope

The Monthly workspace separates saved Monthly report receipt, documented report-section presence and legacy reviewed checklist coverage. A saved PDF or detected section does not establish a completed or clinically passing test. Cached-only viewing does not parse PDFs, contact scanners, refresh readable folders or write clinical decisions. Schedule/setup validation, effective-date history and the selected month are assessed separately from already-saved documents.

The Review controls distinguish the current file from an explicit captured batch selection. Decisions sort files; they do not record clinical approval. Existing exact-byte/stamp validation, bounded batch size, durable Undo and no-rule-learning boundaries remain part of the tested workflow. Trends browsing uses cached values and does not silently start reading.

## Diagnostics and portable operation

The shareable support bundle uses controlled metadata and count fields, retaining the printable HTML and structured exports. Synthetic privacy regressions check sensitive strings, identifiers, paths, credentials, PDF content and opaque selection data against export allowlists. Printing remains local and uses no external assets. Work snapshots are captured context rather than a live proof that an operation is stuck.

Host/runtime identity is tied to the exact tested artifacts and all 103 pinned Python component hashes. The native workflow executes Windows PowerShell5.1, actual Edge, WPF compatibility previews, DPAPI and non-administrator portable-Python cancellation/cleanup. This establishes hosted behavior and does not approve workplace endpoint policy, real scanner access, or hospital network throughput. Reading can consume CPU/storage; pause/cancellation remains cooperative.

Package manifests, actual previous-version update staging/preservation and release checks are recorded separately by the release packager. File-organization decisions, saved receipt calendars and document presence do not replace department policy or clinical QA review.

## Packaged update and preservation

The five actual ZIPs passed **1,744 package checks with zero failures: [Package validation](../Tests/Current/Package-Validation.json). Their host matches the tested native executable, all 103 Python components match its tested integrity manifest, and the new Monthly module matches the pinned source. The existing **5.5.0 updater** staged and installed **5.6.0**, preserved seven synthetic configuration/data/credential/archive/history/log sentinels, verified a previous-program backup and cleaned staging. Generic/private one-time helpers and the standalone diagnostic collector also passed. Private configured packages remain local and are excluded from Releases. These local Linux/PowerShell ZIP/staging checks are separate from the actual Windows execution above.

## Native screenshots

All 44 images below were copied unchanged from the final synthetic native browser captures. They are application screenshots, not private workstation photographs or design mockups.

- [today-light-web-demo.png](images/today-light-web-demo.png)
- [today-dark-web-demo.png](images/today-dark-web-demo.png)
- [reports-light-web-demo.png](images/reports-light-web-demo.png)
- [reports-dark-web-demo.png](images/reports-dark-web-demo.png)
- [review-light-web-demo.png](images/review-light-web-demo.png)
- [review-dark-web-demo.png](images/review-dark-web-demo.png)
- [exports-light-web-demo.png](images/exports-light-web-demo.png)
- [exports-dark-web-demo.png](images/exports-dark-web-demo.png)
- [trends-light-web-demo.png](images/trends-light-web-demo.png)
- [trends-dark-web-demo.png](images/trends-dark-web-demo.png)
- [settings-light-web-demo.png](images/settings-light-web-demo.png)
- [settings-dark-web-demo.png](images/settings-dark-web-demo.png)
- [today-web-demo.png](images/today-web-demo.png)
- [reports-web-demo.png](images/reports-web-demo.png)
- [review-web-demo.png](images/review-web-demo.png)
- [exports-web-demo.png](images/exports-web-demo.png)
- [trends-web-demo.png](images/trends-web-demo.png)
- [settings-web-demo.png](images/settings-web-demo.png)
- [reports-small-web-demo.png](images/reports-small-web-demo.png)
- [support-activity-web-demo.png](images/support-activity-web-demo.png)
- [support-print-web-demo.png](images/support-print-web-demo.png)
- [large-library-pending.png](images/large-library-pending.png)
- [large-refresh-progress.png](images/large-refresh-progress.png)
- [content-basic-web-demo.png](images/content-basic-web-demo.png)
- [content-continuous-pdf-web-demo.png](images/content-continuous-pdf-web-demo.png)
- [content-settings-web-demo.png](images/content-settings-web-demo.png)
- [automatic-filing-web-demo.png](images/automatic-filing-web-demo.png)
- [python-measurements-web-demo.png](images/python-measurements-web-demo.png)
- [python-measurements-small-web-demo.png](images/python-measurements-small-web-demo.png)
- [python-reader-settings-web-demo.png](images/python-reader-settings-web-demo.png)
- [trends-measurements-web-demo.png](images/trends-measurements-web-demo.png)
- [daily-readings-web-demo.png](images/daily-readings-web-demo.png)
- [slice-thickness-trends-web-demo.png](images/slice-thickness-trends-web-demo.png)
- [monthly-alignment-trends-web-demo.png](images/monthly-alignment-trends-web-demo.png)
- [daily-calendar-web-demo.png](images/daily-calendar-web-demo.png)
- [grouped-review-web-demo.png](images/grouped-review-web-demo.png)
- [folders-web-demo.png](images/folders-web-demo.png)
- [folders-light-web-demo.png](images/folders-light-web-demo.png)
- [folders-dark-web-demo.png](images/folders-dark-web-demo.png)
- [monthly-web-demo.png](images/monthly-web-demo.png)
- [monthly-light-web-demo.png](images/monthly-light-web-demo.png)
- [monthly-dark-web-demo.png](images/monthly-dark-web-demo.png)
- [monthly-documents-web-demo.png](images/monthly-documents-web-demo.png)
- [table-position-trends-web-demo.png](images/table-position-trends-web-demo.png)

Reproduce browser validation with `node Tests/Web/run-all.cjs --windows --output artifacts/web`. [Windows-Smoke.md](../Tests/Windows-Smoke.md) lists additional workstation checks. The completed portable package requires no runtime installer, administrator rights, background service or scheduled task during normal use. Scanner collection needs the internal network; saved review and export remain local.
