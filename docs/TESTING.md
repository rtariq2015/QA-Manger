# Validation — CT QA Manager Pro

## 5.7.18 focused startup and network reuse checks

- **51 assertions passed** in one synthetic production-web Chromium flow. A library returning the ordinary loading response beyond 30 virtual seconds recovered automatically with no job events; heartbeat and job polling continued. Verified informational loading, 1/2/4/5-second maximum backoff, coalesced requests, exact saved report identities, library-owned notice cleanup, unrelated-error preservation, actual startup/session errors and manual retry. No unexpected browser errors, external requests or scanner/action mutations. [Evidence](../Tests/Startup-Recovery/Browser.json), [fixture](../Tests/Web/run-startup-recovery.cjs).
- **19 assertions passed** on Linux PowerShell 7.4.13, using module mocks for availability/authentication/mapping and parser checks. Verified accessible-folder reuse avoids authentication, explicit credentials still authenticate, unavailable access falls back, the isolated 30-second deadline remains, worker compatibility and exact source fingerprints. No live network, credentials, Windows DPAPI or actual timeout execution. UTF-8 BOM/CRLF remain intact. [Evidence](../Tests/Startup-Recovery/Network-Reuse.json), [fixture](../Tests/Test-NetworkReuse.ps1).

These are focused development checks, not Windows PowerShell 5.1, live scanner/SMB or hospital workstation validation. The existing host snapshot worker and its 90-second deadline are unchanged; browser recovery polls the in-memory result rather than restarting that worker. Actual host startup failure remains an error requiring corrective action. No broad suite or hospital startup benchmark was performed. Release delivery separately verifies syntax, source scope, ZIP/package integrity and uploaded asset hashes.


## 5.7.17 focused navigation/cache check

Executed one synthetic production-web Chromium workload against 5.7.16 and 5.7.17: **68 assertions passed**. Reports/Exports keep exact matching IDs and existing row limits; Today metadata, unchanged Folders/Exports DOM and receipt-calendar models are reused. Saved-record, scanner-policy and archive changes invalidate their results. Calendar recovery after invalid input and the filter/calendar count/reference caps were checked.

Repeated PDF and Trends A → B → A navigation made **zero additional backend GET requests**. Exact Trends values, units, printed bounds, report IDs and source page were preserved. PDF stamp changes, cache expiry and 23 generated one-page documents exercised reuse and the existing shared 20-page/30 MiB budget. No unexpected browser errors, external requests or mutation requests occurred. See [raw evidence](../Tests/Navigation-Cache/result.json) and [the focused fixture](../Tests/Web/run-navigation-cache.cjs).

Local median of five repeat-navigation samples (synthetic browser fixture, milliseconds):

| Synthetic records | View/work | 5.7.16 | 5.7.17 |
| ---: | --- | ---: | ---: |
| 1,367 | reports | 32.2 ms | 25.6 ms |
| 1,367 | calendar | 12.1 ms | 5.5 ms |
| 1,367 | folders | 11.2 ms | 3.6 ms |
| 1,367 | exports | 5.1 ms | 3.9 ms |
| 1,367 | unchangedSnapshot | 8.9 ms | 6.8 ms |
| 20,000 | reports | 59.1 ms | 15.0 ms |
| 20,000 | calendar | 43.9 ms | 4.3 ms |
| 20,000 | folders | 18.7 ms | 2.3 ms |
| 20,000 | exports | 7.7 ms | 2.5 ms |
| 20,000 | unchangedSnapshot | 32.9 ms | 6.6 ms |

These are local synthetic Chromium measurements, not Windows/hospital workstation timings, real PDF extraction or live scanner validation. No broad suite was repeated. First loads and verified writes still require their original work; browser-memory caches are cleared on restart. The release workflow separately checks syntax, version-only backend scope, package integrity/manifests and uploaded hashes.


## 5.7.16 focused Monthly cache check

Executed one synthetic production-web Chromium flow: **75 assertions passed**, with no unexpected browser errors, external requests, mutation requests or PDF requests. Arrow/picker returns to cached months made zero additional Monthly HTTP requests. It also checks scanner filtering during an in-flight load, cancellation, error retry, report/configuration/archive invalidation, rapid-arrow debounce, the 12-month LRU bound, oversize-response exclusion and five-minute expiry. Source hashes match before/after execution; see [raw evidence](../Tests/Monthly-Cache/result.json) and [the focused fixture](../Tests/Web/run-monthly-cache-ui.cjs).

This is a local synthetic frontend check with a controlled 80 ms response delay, not Windows, real scanner/reader or hospital workstation throughput validation. The release workflow separately checks syntax, version-only backend scope, package CRC/manifests and uploaded hashes. No broad suite was repeated for this frontend change. The initial uncached month still needs a backend request, and this session cache is cleared by a browser reload/restart.

## 5.7.1 historical validation

The Review saving fix uses the exact Windows application source `3d46b34f43336349d793edc7e9ee9087a6061f0d` and its tested host artifact. The subsequent commit changes only test readiness observation and checksums; App, Host, Config, launchers, guide and package-builder bytes remain unchanged.

| Actually executed | Scenarios | Assertions | Failed |
| --- | ---: | ---: | ---: |
| Windows PowerShell 5.1, 18 suites | 413 | 4320 | 0 |
| Actual Windows Edge, six workloads | 115 | 30682 | 0 |
| New Review queue, included in browser total | 5 | 284 | 0 |

The reader comparison, selected-PDF benchmark, large-library core checks, calendar/controller rules and Classic layout/captures also passed. Raw results and the source/host fingerprints are in [Tests/Releases/v5.7.1](../Tests/Releases/v5.7.1/Summary.json). All reports and screenshots use synthetic data.

## Known validation limitation and focused correction

The [initial Windows workflow](https://github.com/rtariq2015/QA-Manger/actions/runs/43929342040) has an overall **failure**: its background scheduler test completed 14 deterministic groups, then decoded an incomplete startup JSON record. Its remaining real-reader/deadline groups are **not claimed as native passes**. Windows creates the private readiness file before applying its ACL and writing JSON; the test had treated file existence as completed startup.

The corrected test waits for complete JSON and the current process ID within the same timeout. It retains every outcome assertion and the 90-second reader deadline. A focused [Linux run](../Tests/Releases/v5.7.1/Scheduler-Corrected-Linux.json) passed all 18 groups, including real reader/export/cancellation preservation and actual child-tree cleanup at the deadline. This is explicitly Linux execution.

At the user's direction, the [full repeat](https://github.com/rtariq2015/QA-Manger/actions/runs/43938032793) was cancelled instead of repeating unchanged application tests. It is not a passing workflow. This release records these scopes separately and does not modify the automated publisher's existing success gate.

## Packages and preservation

The complete Portable, Update and legacy Upgrade ZIPs passed 5377 checks: CRC, complete SHA-256 manifests, exact source and executed Windows host bytes, PE version 5.7.1.0, all 103 pinned Python components, licenses and all 16 native tab/theme preview images. The actual [5.7.0 → 5.7.1 synthetic update](../Tests/Releases/v5.7.1/Update-Preservation.json) on Linux PowerShell retained nine configuration, profile, credential-placeholder, report, decision, analysis-cache and log sentinels byte for byte, with previous-program/metadata backup and stage cleanup. Those package checks are separate from native Windows tests.

For an existing 5.3+ installation, create a full backup, choose the intact Update ZIP under Settings → Program updates, then install and restart. The previous program remains in Backups. To roll back, close the app, restore the previous App and backed-up root launchers/package metadata, and retain current Config, Data and Logs.

[5.7.0 evidence](TESTING-5.7.0.md), [5.6.0 evidence](TESTING-5.6.0.md) and [development findings](REVIEW-RESPONSIVENESS.md) retain their provenance. Hosted/effective-viewport checks do not establish hospital IT approval, real scanner connectivity, OS DPI testing or workstation throughput. Filing is separate from clinical QA approval.
