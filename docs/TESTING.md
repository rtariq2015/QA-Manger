# Validation — CT QA Manager Pro

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
