# Validation — CT QA Manager Pro 5.7.0

Release 5.7.0 promotes the completed imaging-console upgrade to a clearly numbered portable download. Runtime changes from the preceding Windows-tested engineering build are version strings only; the production file comparison is recorded with the release evidence. Historical [5.6.0 validation](TESTING-5.6.0.md) and the [engineering development results](ENGINEERING-VALIDATION.md) retain their original provenance.

The final fresh Windows execution and full-package preservation results are recorded below. All published test evidence uses synthetic reports, scanner folders and identities. No workplace PDFs, passwords, actual workstation logs or private scanner connection profiles are shipped.

Fresh successful workflow: [Windows validation run 43910393227](https://github.com/rtariq2015/QA-Manger/actions/runs/43910393227), exact source `6023f49ccb2a4d2a83e83249fe59e58867a7c124`. The downloaded host matches the executed browser host fingerprint, and all source hashes recorded by the accessibility and frontend workloads match this commit.

| Actual execution | Scenarios | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: 18 suites | 411 | 4,151 | 0 | [Summary](../Tests/Releases/v5.7.0/Summary.json) |
| Windows Edge: Main | 18 | 826 | 0 | [Raw](../Tests/Releases/v5.7.0/web/browser-summary.json) |
| Windows Edge: Accessibility and layout | 67 | 1,014 | 0 | [Raw](../Tests/Releases/v5.7.0/web/accessibility/accessibility-summary.json) |
| Windows Edge: Large library | 6 | 27,847 | 0 | [Raw](../Tests/Releases/v5.7.0/web/large/large-browser-summary.json) |
| Windows Edge: PDF content | 9 | 290 | 0 | [Raw](../Tests/Releases/v5.7.0/web/content/content-browser-summary.json) |
| Windows Edge: Python and Trends | 10 | 421 | 0 | [Raw](../Tests/Releases/v5.7.0/web/python/python-browser-summary.json) |
| Native reader comparison | 3 | 80 | 0 | [Raw](../Tests/Releases/v5.7.0/windows/Reader-Benchmark.json) |
| Generated large library | 4 | 5,463 | 0 | [Raw](../Tests/Releases/v5.7.0/web/large/library-summary.json) |
| Node controller rules, separate from browser totals | 7 | 25 | 0 | [Raw](../Tests/Releases/v5.7.0/web/trends-refresh/controller-summary.json) |

The five actual Edge workloads total **110 scenarios / 30,398 assertions / zero failures**. These totals are separate from the native PowerShell, reader and generated-library totals. The [background scheduler](../Tests/Releases/v5.7.0/windows/Background-Scheduler.json) passed **18 check groups**, including the real bounded helper deadline and process-tree cleanup. The [calendar](../Tests/Releases/v5.7.0/web/calendar-rules.json) passed **7 cached metadata rule groups**. The artifact also contains 6 fresh Classic WPF screenshots. Raw suite `Version` fields can identify the original feature version; their bytes are retained without relabeling historical feature names.

### Fresh Windows synthetic frontend observations

| Loaded metadata records | Open Reports | Unchanged snapshot | Settled search | Rendered rows | Total DOM nodes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,367 | 32.0 ms | 4.2 ms | 163.6 ms | 100 | 2,570 |
| 20,000 | 39.9 ms | 23.3 ms | 178.4 ms | 100 | 2,570 |

The [frontend workload](../Tests/Releases/v5.7.0/web/library-performance.json) passed **50 assertions** using actual production browser assets and deterministic synthetic API responses. These timings measure already-loaded metadata and browser layout, not HTTP transfer, PDF parsing, complete startup or scanner throughput. Each workload is an individual diagnostic observation. The earlier matched-platform before/after comparison remains in the [engineering report](ENGINEERING-VALIDATION.md); it is not relabeled a new Windows comparison.

### Actual downloadable package verification

[Package checks](../Tests/Releases/v5.7.0/Package-Validation.json) passed **5,377 supplemental assertions**, checking the three complete release ZIPs, exact source and Windows host bytes, the PE file/product version, all 103 reader components, licenses, complete SHA-256 manifests, update limits and 16 actual native preview images.

The [5.6.0 → 5.7.0 installation simulation](../Tests/Releases/v5.7.0/Update-Preservation.json) executed using **7.4.13 on Unix**. Both the installed 5.6.0 validator and the new validator accepted the actual Update ZIP. Installation retained all **9 synthetic settings, profile, credential-placeholder, report, decision, cache and log files** byte for byte; the previous App and version metadata were backed up, installed payload hashes matched, and staging was cleaned. These Linux package checks are supplemental; they are separate from actual hosted Windows execution and do not establish hospital-workstation behavior.

[Production version-only comparison](../Tests/Releases/v5.7.0/Version-Only-Comparison.json) records the eight production files whose 5.6.0 → 5.7.0 changes are version strings only. The source identity of all other application logic remains the engineering upgrade already documented in the audit.

### Fresh native screenshots

All sixteen captures below come byte for byte from the successful Windows run, using synthetic data. The release's offline visual preview embeds these same native screenshots.

- **Today**: [Light](images/v5.7.0/today-light-web-demo.png) · [Dark](images/v5.7.0/today-dark-web-demo.png)
- **Monthly**: [Light](images/v5.7.0/monthly-light-web-demo.png) · [Dark](images/v5.7.0/monthly-dark-web-demo.png)
- **Reports**: [Light](images/v5.7.0/reports-light-web-demo.png) · [Dark](images/v5.7.0/reports-dark-web-demo.png)
- **Review**: [Light](images/v5.7.0/review-light-web-demo.png) · [Dark](images/v5.7.0/review-dark-web-demo.png)
- **Exports**: [Light](images/v5.7.0/exports-light-web-demo.png) · [Dark](images/v5.7.0/exports-dark-web-demo.png)
- **Folders**: [Light](images/v5.7.0/folders-light-web-demo.png) · [Dark](images/v5.7.0/folders-dark-web-demo.png)
- **Trends**: [Light](images/v5.7.0/trends-light-web-demo.png) · [Dark](images/v5.7.0/trends-dark-web-demo.png)
- **Settings**: [Light](images/v5.7.0/settings-light-web-demo.png) · [Dark](images/v5.7.0/settings-dark-web-demo.png)

## Installing and rolling back

For an existing browser application (5.3+), create a full backup in Settings, then choose the intact Update ZIP in **Settings → Program updates → Choose update ZIP → Install & restart**. Use the Portable ZIP for a new installation. Versions 5.2 and earlier use the separate Upgrade ZIP extracted into a new folder, then select the existing program with its helper. Do not manually copy files over a running installation.

The updater retains settings, saved sign-ins, archive records, PDFs, cached analysis and filing decisions, and keeps the previous program under `Backups/Program-*`. To roll back, close every app window, restore the previous App folder plus backed-up launchers and package metadata, and retain current Config, Data and Logs. Do not copy an old data archive over current saved work.

## Practical limits

Hosted Windows validation does not establish hospital IT approval, live scanner access, actual workstation performance, every operating-system DPI setting or screen-reader usability. Background reading still consumes CPU and storage and can be paused. Unsupported or conflicting PDFs can still need a filing decision. Reports received, files organized and detected test sections do not mark clinical QA as passed or create clinical sign-off.

The Classic fallback remains available. Its original minimum window sizes can exceed the available logical space at extreme display scaling. Selected-PDF membership and hash checks still scale with the index; very large cold libraries and unknown-format Review lists remain future performance work. Density preference is scoped to the localhost browser origin and may reset after a different startup port.
