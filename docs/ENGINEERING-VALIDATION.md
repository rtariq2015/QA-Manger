# Engineering branch validation

This report covers the unreleased `engineering/offline-workstation-audit` branch. The published **5.6.0** evidence in `Tests/Current` remains historical for this work. No release, merge or workplace deployment is authorized by this report.

## Reproducible frontend comparison

Original assets match commit `6b51f4c3223b9cbe051dd9c9e502c10954f8e603` byte for byte. Measured improved assets match commit `410b55a` byte for byte. The raw reports contain all four asset SHA-256s. Subsequent density-help wording and a Trends-only chart legibility style do not change the measured Reports rendering logic.

Execution: Linux x64, Chromium 156.0.8078.79, Node 24.22.1. Original and improved workloads ran sequentially on the same quiet development computer, with deterministic **1,367** and **20,000** synthetic records. These are individual diagnostic observations, not population statistics or guaranteed workstation timings.

| Indexed records | Action | Original | Improved |
| ---: | --- | ---: | ---: |
| 1,367 | Open Reports after metadata is loaded | 1,143.5 ms | 90.6 ms |
| 1,367 | Render an unchanged snapshot | 1,062.5 ms | 13.1 ms |
| 1,367 | Settled search after six rapid inputs | 6,039.7 ms | 194.8 ms |
| 20,000 | Open Reports after metadata is loaded | 12,196.1 ms | 74.8 ms |
| 20,000 | Render an unchanged snapshot | 16,701.6 ms | 24.0 ms |
| 20,000 | Settled search after six rapid inputs | 81,257.6 ms | 314.7 ms |

At 20,000 records, rendered report rows changed from **20,000 to 100** and total DOM nodes from **301,018 to 2,530**. The unchanged list made zero child replacements. Six rapid search inputs produced one replacement after the 150 ms debounce, while retaining the complete matching set for exports. Fifty functional assertions passed across the two improved workloads, including paging/keyboard focus, combined filters, exact filename search, changed-record invalidation, Monthly expansion, density reload and all-matching export IDs. No JavaScript errors or external HTTP requests were observed.

JavaScript heap after garbage collection increased from **3.13 to 3.72 MB** at 1,367 records and **13.41 to 27.83 MB** at 20,000 because metadata, lookup and search caches retain additional data. This measure excludes native DOM/browser memory, so it does **not** establish an overall RAM reduction. DOM counts and synchronous main-thread work are the measured gains.

The test server supplies synthetic API responses and injects a response-only test bridge. Product files do not contain the bridge. Snapshot timing above measures synchronous rendering/layout of an already-loaded snapshot; it excludes HTTP transfer, JSON parsing and the metadata fingerprint. Settled search includes the debounce interval. These results do not measure PDF extraction, PowerShell, scanner networking, complete startup, native Windows DPI or hospital throughput.

Raw, unchanged reports: [original](../Tests/Engineering/Library-Frontend-Before.json), [improved](../Tests/Engineering/Library-Frontend-After.json). Reproduce with `Tests/Web/run-library-performance.cjs`; see [developer instructions](DEVELOPMENT.md).

## Selected-PDF lookup comparison

A separate actual PowerShell adapter benchmark used one generated verified PDF and a synthetic index. After a warm-up, three same-process samples ran for each size before and after, sequentially with other team tests paused. Original copied sources match `6b51f4c`; all measured PowerShell source and benchmark-script bytes stayed unchanged. The unrelated density-help HTML changed during the run and is explicitly disclosed in the provenance report.

| Synthetic indexed records | Original median | Improved median | Observed reduction |
| ---: | ---: | ---: | ---: |
| 1,367 | 2,301.336 ms | 1,811.462 ms | 21.29% |
| 20,000 | 48,328.085 ms | 29,454.928 ms | 39.05% |

Both commands completed within their 600-second development-process bounds. State, scanner-source PDF and archived PDF hashes stayed unchanged. Raw samples, including their variance, are retained: [before](../Tests/Engineering/Selected-Lookup-Before.json), [after](../Tests/Engineering/Selected-Lookup-After.json), [provenance](../Tests/Engineering/Selected-Lookup-Provenance.json), [comparison](../Tests/Engineering/Selected-Lookup-Comparison.json).

This is Linux PowerShell 7.4.13 metadata resolution and exact-byte hashing, excluding host/API latency, native page rendering and PDF text extraction. Unselected metadata paths are not physically populated. Even the improved 20,000-record lookup remains substantial; it is not described as instant or a full-library processing-speed guarantee. Existing production resource/time limits are unchanged.

## Readability and interface evidence

The actual-host development accessibility workload passed **67 scenarios / 997 assertions**: all eight tabs × both themes × four effective viewport scales, plus keyboard navigation, focused editable fields, display density, Review scope and preserved source hashes. These simulate effective screen space; they do not set Windows DPI. [Raw report](../Tests/Engineering/Accessibility-Development.json).

A second workload used real parsed synthetic measurements, rather than an empty Trends chart. Before the fix, axis text shrank to about 7.16 CSS pixels at the 200% effective viewport. The narrow chart now keeps 13 CSS-pixel labels and pans inside its own container, with no horizontal document overflow. **Six focused Standard-reader browser scenarios / 275 assertions passed**, preserving exact units, printed bounds, context, source page, analysis-cache bytes and source files. It covers the new metric/chart subset; the first four full bundled-Windows-Python scenarios were not run on Linux. [Raw report](../Tests/Engineering/Trends-Readability-Development.json).

The scheduler workload passed **18 check groups**, including real-reader foreground handoff, pause/cancel preservation and an actual bounded unresponsive-helper test. It uses a deterministic adapter for scheduling and generated PDFs for reader checks, not a scanner throughput benchmark. [Raw report](../Tests/Engineering/Background-Scheduler-Development.json).

[All eight workspaces in Light and Dark](ENGINEERING-SCREENSHOTS.md) include development previews and narrow-window detail captures. Their supplied asset hashes identify the executed versions; final native Windows results belong to the PR checks/artifacts.

## Component execution and fresh native checks

A fresh complete applicable Linux PowerShell 7.4.13 run passed **17 suites / 390 scenarios / 3,356 assertions**, with zero failed scenarios or processes. All application PowerShell and suite-file hashes stayed unchanged throughout the run; the [summary and 17 raw reports](../Tests/Engineering/PowerShell-Development/Summary.json) pin those bytes. The completion static checker passed 972 checks; later evidence-only additions can increase that file-count-dependent total. The bundled production Windows Python reader, DPAPI and WPF were not executed locally.

The development checks also executed an actual local host/Chromium accessibility workload and targeted JavaScript checks. Their scope differs from Windows PowerShell 5.1, native PDF rendering and WPF. A shared-tree initial diagnostic loop is not an immutable baseline or final-source whole-suite result.

The pull request's **Windows validation and visual preview** check builds the self-contained Windows host and pinned reader, then runs the existing native suites and browser workloads plus new accessibility/large-library checks. Fresh native outcome totals and artifact links belong in the PR validation record once the run completes. A queued, skipped, cancelled or failed check is not a passing test. Independent suites now retain their own outcomes even if another workload fails.

Hosted Windows checks do not establish actual hospital IT approval, live scanner connectivity, workstation CPU/storage throughput, arbitrary Windows DPI configurations or screen-reader usability. Use [Windows-Smoke.md](../Tests/Windows-Smoke.md) for authorized workstation checks. No test changes execution policy or endpoint security.

The complete main browser workload exposed one small-screen regression: connection and foreground progress banners could push the filing buttons below the visible rail. A focused actual-job reproduction now verifies both buttons fit at 1024×768 with both banners present, while retaining progress and cancellation details. The existing whole-workflow visibility assertions remain unchanged. [Focused geometry](../Tests/Engineering/Review-Progress-Layout-Development.json).

## Compatibility, limitations and rollback

- Classic retains its existing minimum windows (760×520 DIPs; Review 860×580 DIPs). A 1366×768 physical screen at 200% can have less logical space than those minima. Browser scaling tests do not establish Classic high-DPI fit; targeted native Classic scaling work remains a limitation.
- The release version remains 5.6.0; this branch is unreleased. No installed runtime, module, cloud service, telemetry or external UI asset is added. Classic remains available, with corrected version labels.
- Saved schemas and public action names remain compatible. Filing confirmation is separate from clinical evidence. No parser values, units, contexts, printed limits, PDF caps, batch limits, cancellation controls or timeouts are relaxed.
- Unsupported/conflicting PDFs still need filing review; automatic recognition cannot honestly cover every possible document. Initial confirmed Import retains its all-or-none stale-preview contract. Normal Update retains per-scanner/item failure isolation.
- Selected-PDF membership still validates fresh archive metadata and hashes actual bytes; lookup remains dependent on library size. Large cold snapshots, very large unknown-format Review queues and the generated full offline navigator remain candidates for measured future work.
- Density is scoped to the local browser origin and can reset when the app starts on a new random port. Theme remains a saved application setting. The extra cache memory is disclosed above.
- Existing Pause/Resume/Stop and AutoAnalyze controls remain the resource controls. No unmeasured duplicate Low Resource Mode or new concurrency limit is introduced.
- SHA-256 package validation remains mandatory. Publisher signing is an IT-approved future design, not a security feature claimed by this branch. See [authenticity options](DEVELOPMENT.md#release-authenticity-options).
- This PR changes source only. For development rollback, return to the baseline or revert the grouped commits. For a separately installed update, close both interfaces and restore previous `App` **and backed-up root program files**, preserving Config/Data/credentials/archive/logs. See [rollback details](DEVELOPMENT.md#rollback-and-review).

## Imaging-console visual pass and validation follow-up

The interface now uses a cohesive pearl/slate and navy imaging-console palette, instrument-style dividers and refined controls, while retaining CT QA identity, semantic scanner colors and Light/Dark. Brand-neutral CT gantry/bed artwork is embedded as one reusable SVG symbol in the already-supported HTML asset. It makes no external image request, adds no raster payload or runtime dependency, and changes no updater file allowlist. Daily receipt and preserved-PDF totals stay visible at narrow sizes; only decorative hero artwork is hidden when space is limited.

The actual-host console accessibility workload passed **67 scenarios / 1,014 assertions**, including explicit rendered scanner artwork and visible receipt/archive totals at all four scales. The full content workflow passed **9 scenarios / 289 assertions**, preserving classification, clinical evidence, continuous PDF viewing, exports, saved rules and Monthly separation. [Console accessibility](../Tests/Engineering/Console-Accessibility-Development.json) · [Content workflow](../Tests/Engineering/Console-Content-Development.json).

The first hosted Windows attempt (run `43882581919`, source `72230ad`) failed overall and is not presented as passing validation. Its independent suites exposed a malformed-ZIP test constructor that .NET Framework rejects before the application can inspect the archive. The fixture now creates legal equal-length filename placeholders and writes the malicious filename bytes into both ZIP headers after closing it; the unsafe-path rejection cases and every assertion remain. A fresh Linux Portable run passed **18 scenarios / 68 assertions**. Windows must independently execute the fixed fixture.

The large browser regression also needed its existing count invariant updated for intentional pagination: it now enumerates every waiting-report page and checks complete unique identities, total counts, page boundaries and exclusion of the analyzed exception. Changed-snapshot focus is tested through the supported scanner-settings action with controlled browser response delivery, rather than an external configuration edit that does not publish a new host snapshot. Atomic stale-batch, Undo, PDF and clinical-state guards remain intact. These are meaningful fixture/workload corrections, not relaxed product assertions.

The earlier quiet performance table identifies the measured optimization-stage asset hashes. Subsequent console styling and bundled decorative vectors are separately validated; do not treat that table as a new benchmark of every later visual asset. Final native execution and screenshot links are recorded in the PR checks.

The corrected actual large-library workflow passed **6 scenarios / 27,847 assertions**, including complete waiting-queue identity coverage, changed/unchanged focus, atomic stale-batch rejection and durable grouped Undo after restart. Its fresh 1,367-PDF core preparation passed **4 scenarios / 5,463 assertions**. [Browser raw](../Tests/Engineering/Console-Large-Browser-Development.json) · [Core raw](../Tests/Engineering/Console-Large-Core-Development.json).
