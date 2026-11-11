# Testing and practical limits

Final v5.3.1 Windows validation passed at source `006268bb12a6ca93c428ac5cbe1078d7d3976bf3` in [the recorded workflow](https://github.com/rtariq2015/QA-Manger/actions/runs/43062859219). Public test PDFs, scanner folders, identities, credentials and screenshot data are generated synthetic fixtures. User-provided reports, extracted private text, private archive audits and workplace photographs are excluded from repository evidence, documentation figures and release previews.

| Execution | Scenarios or checks | Assertions | Failed | Evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: eighteen native suites | 306 | 2,608 | 0 | [Native summary](../Tests/Current/Windows/Summary.json) and unchanged raw reports |
| Windows PowerShell: reader comparison and cache reuse | 3 | 80 | 0 | [Reader benchmark](../Tests/Current/Reader-Benchmark-Windows.json) |
| Windows Edge: application and detailed support workflow | 15 | 553 | 0 | [Main browser report](../Tests/Current/Browser-Web-Windows.json) |
| Windows PowerShell: generated 1,367-report library | 4 | 5,463 | 0 | [Library report](../Tests/Current/Large-Library-Windows.json) |
| Windows Edge: large-library progress and cancellation | 4 | 27,328 | 0 | [Large browser report](../Tests/Current/Browser-Large-Windows.json) |
| Windows Edge: contents, scanner rules and automatic pending processing | 6 | 188 | 0 | [Content browser report](../Tests/Current/Browser-Content-Windows.json) |
| Windows Edge: bundled Python, measurements and Trends | 4 | 118 | 0 | [Python browser report](../Tests/Current/Browser-Python-Windows.json) |
| Windows actual host with deterministic synthetic PowerShell adapter | 10 checks | Not reported | 0 | [Scheduler report](../Tests/Current/Background-Scheduler-Windows.json) |
| Linux PowerShell 7.4.13: six reports run during v5.3.1 development | 106 | 863 | 0 | [Local groups](../Tests/Current/Summary.json) and raw Content, Analysis, Integration, WebService, Support and Update reports |
| Linux PowerShell: three retained unchanged-scope v5.3.0 reports | 43 | 125 | 0 | Raw PDF-reader, Measurement and Trend reports; these are earlier executions, not new final-source reruns |
| Linux actual host with deterministic synthetic PowerShell adapter | 10 checks | Not reported | 0 | [Scheduler development report](../Tests/Current/Background-Scheduler-Linux.json) |
| Retained Linux Python worker protocol | 11 | Not reported | 0 | [Unchanged worker report](../Tests/Current/Python-Worker-Linux.json) |

The nine Linux PowerShell reports sum to 149 scenarios and 988 assertions. Only six were executed during v5.3.1 development; the three earlier reports are retained for unchanged reader, measurement and trend scopes. They do not establish a Linux rerun of the final commit, and their raw reports embed no commit hash. The independent successful Windows artifact pins all eighteen native suites and all four browser workloads to the final source. Native and Linux totals are kept separate. The scheduler reports provide ten check outcomes without a PowerShell assertion counter; the unchanged worker protocol provides eleven scenarios without an assertion counter.

Prior complete evidence is preserved byte-for-byte under [Tests/Historical/v5.3.0](../Tests/Historical/v5.3.0), with older releases in their own historical folders. Some raw Version fields describe the feature's introduction and remain unchanged. The final Windows summary records source/run identifiers, host executable SHA-256, runtime artifact SHA-256, Python integrity manifest SHA-256 and validation artifact SHA-256.

## Detailed shareable diagnostics and printing

**Settings → Backup & support** offers a diagnostic ZIP and a separate printable report. Their independent links remain available after later operations and snapshots. The printable document opens in a separate browser tab; Ctrl+P prints it or saves it as PDF. Its HTML uses print styles with no script or external assets. Only the authenticated generated HTML download receives the narrowly scoped report policy; the main application's content security policy is retained.

The ZIP has seven entries:

- `SupportReport.html`: overview, configuration and reader state, grouped reasons, a bounded activity timeline and pending-report detail.
- `Support-Summary.json`: structured summary and diagnostic rows.
- `Report-Diagnostics.csv` and `Report-Diagnostics.jsonl`: all report diagnostic rows in the exported snapshot.
- `Scrubbed-Activity.csv` and `Scrubbed-Activity.jsonl`: all retained supported structured events available at export time.
- `READ ME.txt`: scope, retention, alias and sharing instructions.

Report detail separates missing or stale text caches, measurement upgrades, reader failures, unknown templates, missing format rules, conflicting dates/times/types, incomplete reads and unsupported tables. Fixed enums and bounded numeric fields retain reader/profile/model, support revision, page coverage, measurement counts, timings and size bands. Work snapshots show queue stages, progress and pause/cancel requests. Operation history records accepted starts, finishes, failures and controlled reading events. The readable report explains that pause, resume and stop requests take effect at safe checkpoints.

Report references such as `Report0001` are regenerated per export. They are not persistent file identifiers or a tamper-proof audit trail. Scanner aliases use configured ordinal positions. PDF text, files, filenames, paths, hashes, account names, passwords, addresses, raw exception strings and unstructured logs are excluded. All inputs are reconstructed through allowlists; raw caller objects are not serialized directly into shareable documents.

Printable detail and recent activity are each capped at 500 and disclose their limits. Full machine-readable exports retain all available supported rows/events. Structured logs normally retain up to 90 days within the storage budget; this is retained history, not a promise that every past action was recorded. Legacy data is included only where readable and bounded. Export does not reread all PDFs or upload anything automatically.

Synthetic tests inject private sentinels into configuration, prior reviews, cache fields, arbitrary events and free text, then inspect every ZIP entry and the printable output. They verify safe behavior with malformed analysis caches and unreadable organization state, complete CSV/JSONL details, honest HTML caps, atomic file creation and preservation of source data. Browser tests perform the actual export, inspect its seven entries, open the separately authenticated printable page, emulate print media, and verify both links survive unrelated jobs. Application APIs in these browser tests are not mocked.

## Continuous background processing and filing rules

The ordinary **Read next 20 saved PDFs** action retains its twenty-attempt bound. The explicit **Read all saved PDFs** and Review's **Read & organize automatically** actions create a continuous eligible queue. They process one PDF at a time at lower process priority and yield between files for foreground review, search and export. Pause acts at a safe boundary, Resume continues the current job, and Stop preserves completed work. Closing the app stops its local helper; a later explicitly started queue resumes from saved cache evidence.

The queue can add measurements to valid older classifications and retry older unknown-template evidence once for a newer support revision. Recognized older evidence remains reusable. Saved read errors are not repeatedly retried without an appropriate explicit retry or changed input. Failed or interrupted parsing cannot replace prior verified evidence. Completing a queue synchronizes readable folders without changing protected originals, user filing decisions or clinical archive fields. A zero-eligible queue is allowed to finish normally rather than reporting an invented read failure.

The scheduler regression uses the real host with a deterministic synthetic PowerShell adapter to isolate request sanitation, serialization, factual cumulative progress, duplicate rejection, pause/no extra helpers, foreground handoff, safe cancellation and shutdown. A twenty-five-item explicit queue must continue beyond the ordinary twenty-item cap and perform its final readable-folder synchronization. These ten outcomes do not measure PDF parser speed or hospital network throughput.

Content regressions recognize exact compatible Siemens Edge, Flash and Drive body profiles. Complete numbered Basic and Extended IEC section sets, bounded individual/combined additional tests, and the separate explicit `Quality Daily` body family are tested. A supported model name, page count, file size or table of contents alone is insufficient. Mixed models, unknown/reference-only sections, incomplete bodies and conflicting evidence remain unresolved. The manufacturer Daily body label identifies a Daily document; it does not create a clinical PASS.

Basic, Extended and Additional layouts default to **Ask** unless the department saves a scanner-specific Daily/Monthly/Other rule. One-file approval does not teach a global rule. The browser content workload generates compatible Flash Basic and Extended PDFs, saves a rule once for that scanner, runs the unresolved queue, and verifies automatic filing without fabricated human approval history. Prior explicit Undo and contradictory dates remain pending; all original/source PDF bytes and the clinical archive state remain unchanged. Public evidence uses generated layouts only and contains no aggregate audit of user-provided reports.

## Browser workflow and continuous PDF rendering

The interface keeps **Today, Reports, Review, Exports, Trends and Settings** separate. Today distinguishes saved Daily receipt, scanner access and department Monthly evidence. Review offers Approve/Disapprove and Undo without a required name or authorization checkbox for file sorting. Exports has independent filters, including multiple years, and includes every matching PDF. Light/Dark is persisted with the portable workspace.

Native Edge checks verify actual decoded PNG page pixels against the authenticated selected-page response, including report identity, PDF fingerprint, page and dimensions. The main application policy permits local Blob images without permitting arbitrary Blob network fetches. The content report must set `nativeContinuousPreviewActuallyRun: true`: scrolling must display the last page of a multi-page document without Previous/Next controls. Lazy loading, bounded concurrent page requests and a bounded image cache keep the PDF navigable. Both filing controls remain visible at 1024×768 with the inspector open.

The browser suites also retain authentication/origin rejection, offline-only assets, normal typing after mouse release, unfinished form preservation, password clearing, persistent Undo, stale-decision rejection, exact filtered ZIP hashes, saved theme after a full process restart, background reading controls and independent foreground work.

## Portable PDF readers and measured comparison

The program bundles its Windows x64 Python interpreter, standard library and pure-Python reader alongside Standard/PdfPig. No Python installation or pip is used at work. Dependency versions/hashes are in [native Python build metadata](../Tests/Current/Python-Build-Windows.json). Python uses isolated imports, disabled site/bytecode writes and its own socket-operation guard. This guard is not a test of the operating-system firewall and does not bypass workplace controls.

Both engines consume a bounded already-verified PDF buffer. Archive membership, indexed SHA-256, length and write timestamp are checked around reading, and returned provenance must agree before derived evidence is saved. PDF content and paths are not passed as Python command-line arguments or temporary PDF files. Native tests exercise the production bridge under an actual standard Windows user, with live cancellation and child cleanup, limits, image-only/encrypted input, changed saved bytes, damaged dependencies, explicit reader failure, Automatic fallback and cache preservation. Ephemeral test-account setup occurs only inside CI infrastructure; the application creates no Windows users or policy changes.

The comparison uses identical generated **Basic nine-page and Extended six-page** reports, fresh isolated workers and alternating reader order. Qualification requires complete pages, expected body profiles, matching footer dates/times, section observations and exact input fingerprints. Across 12 cold reads, the whole-read median was **1135.01 ms for Standard** and **1614.14 ms for Python**. The faster reader in this fixture was **Standard**; Standard median divided by Python median was 0.703.

Whole-read time includes startup, transport, verification and parsing. Lower-level timings remain in the raw evidence. No hardware-dependent speed threshold or memory claim is made. Warm analysis reuses two cached reports with **zero new parses and zero cache writes**. This local synthetic comparison does not establish hospital SMB speed, endpoint scanning cost or performance for every layout.

## Measurements, Trends and archive preservation

Supported single-metric tables can supply current Water CT values and Image noise in HU, explicit associated limits, mode, system, slice and page. Historical/reference values and unrelated scan parameters are not substituted. Ambiguous, shared-column, incomplete or unsupported tables remain visible for review. New document-filing support does not imply universal measurement extraction or numerical QA decisions.

Trends keeps scanner, Head/Body, system and slice contexts separate. It uses complete, date-consistent, verified current values and links back to their source pages. Printed failures and outliers remain visible with warnings; uncertain limits stay absent. Conflicting aliases/timestamps are withheld instead of averaged. Latest-minus-first change is documentary change within the selected period, not a calibrated drift diagnosis or clinical approval. Full-series summaries precede plotting caps, and truncation is disclosed. Looking at a graph starts no hidden PDF reading.

Schema-3 cache provenance stays bound to the parsed PDF hash, record identity, length and write time. Equal-content destinations retain their metadata. Manual decisions, prior formal reviews and Undo retain priority. Readable folders, derived dates and exports do not rewrite protected clinical fields. Native suites retain archive locks/recovery, Monthly checklist evidence, sign-in protection, backups/restore, update admission/rollback and support privacy.

The generated large workload contains 1,367 reports with known automatic, pending, approved and disapproved distributions. A cold readable-library pass performs 2,734 hash operations and one ownership-ledger write; an unchanged warm pass performs zero PDF hash reads, copies or ledger writes. Explicit verification catches changed bytes even when length/timestamps are restored. A barrier is inserted only into a disposable fixture's copied progress checkpoint; the real archive loop exercises progress, duplicate Refresh coalescing, browsing/reload while busy, cancellation and resumed completion. Detailed support export remains independent of the held update.

## Captures and reproduction

All **thirty-one captures** are copied unchanged from the successful final native artifact. They include twelve six-tab Light/Dark views, seven main/small-window compatibility captures, two large-library captures, three original content captures, four Python/measurement captures, and three new support/automatic-filing captures. They are screenshots of the actual application using synthetic data, not workplace photographs or design mockups.

| Tab | Light | Dark |
| --- | --- | --- |
| Today | [Light](images/today-light-web-demo.png) | [Dark](images/today-dark-web-demo.png) |
| Reports | [Light](images/reports-light-web-demo.png) | [Dark](images/reports-dark-web-demo.png) |
| Review | [Light](images/review-light-web-demo.png) | [Dark](images/review-dark-web-demo.png) |
| Exports | [Light](images/exports-light-web-demo.png) | [Dark](images/exports-dark-web-demo.png) |
| Trends | [Light](images/trends-light-web-demo.png) | [Dark](images/trends-dark-web-demo.png) |
| Settings | [Light](images/settings-light-web-demo.png) | [Dark](images/settings-dark-web-demo.png) |

Further screenshots show [detailed support](images/support-activity-web-demo.png), [the printable report](images/support-print-web-demo.png), [automatic filing](images/automatic-filing-web-demo.png), [continuous native PDF scrolling](images/content-continuous-pdf-web-demo.png), [report format settings](images/content-settings-web-demo.png), [printed measurements](images/python-measurements-web-demo.png) and [source-linked Trends](images/trends-measurements-web-demo.png).

Build validation uses .NET SDK, Python dependency downloads and Node/Playwright. These are development tools and build-time network requests; the work computer receives the completed offline package. The workflow builds the self-contained host and pinned Python reader, exercises all four browser workloads in native Edge, runs the comparison/eighteen native suites/scheduler and captures WPF compatibility views. The browser command is:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

Fresh fixture destinations are required. [Windows-Smoke.md](../Tests/Windows-Smoke.md) describes work-computer checks.

## Practical limits

- Hosted Windows tests do not approve workplace endpoint policy or establish scanner-share access. The completed program still needs compatible Windows components and permission to launch its executable/scripts and local browser connection.
- Reading one PDF at a time and yielding improves interaction opportunities; it does not remove CPU, storage or network work. Real workload timing and memory remain workstation-dependent.
- Scanner collection needs the internal network. Saved review, filing and export work locally. Missing PDFs or unavailable scanners do not establish clinical QA failure.
- Recognized document layouts and their labels do not replace department frequency rules or clinical review. Image-only OCR and universal table/model recognition are not included. Unsupported or conflicting reports can still need a person.
- Queue cancellation is cooperative. An already-running Windows read may need to return before a checkpoint. Completed evidence remains saved; unstarted files are not logged as read failures.
- Diagnostics retain supported structured history, not every past action or a signed audit system. Shareable aliases are per export. Full machine exports and printable detail have explicitly different scopes/caps.
- Nothing is uploaded automatically, and no installed service or scheduled task is added. Closing the helper stops background work. Keep an approved separate backup; same-drive readable copies do not protect against disk loss.
- Moving to another Windows account/computer can require scanner sign-in again. Updates preserve settings/data; checksums detect inconsistent files but do not authenticate an unknown publisher.
- Keyboard/IME, DPI, folder dialogs, long paths, additional report variants and actual scanner access still need appropriate workstation checks.
