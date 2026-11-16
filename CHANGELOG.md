# Changes

## Unreleased — workstation engineering branch

- Bound the Reports list to 100 visible rows with keyboard-aware page navigation, debounced searches, reused metadata sorting and unchanged-view reuse. Exports continue to include every matching report.
- Increase readable text sizes and contrast, add Comfortable/Compact display density, improve narrow/short-window Review layouts, and add named dialogs, keyboard-accessible PDF scrolling and complete Settings tab semantics. Preserve Light/Dark modes and scanner accents.
- Make file-label confirmation explicit; keep clinical results and formal reviewed evidence separate. Compact expandable Monthly scanner details retain existing calculations and checklist history.
- Resolve selected PDFs from fresh validated archive records without rebuilding unrelated dashboards; keep exact path and SHA-256 checks.
- Reject ambiguous archive identities/destinations and linked metadata without rewriting stored data. Neutralize spreadsheet formula prefixes only in the derived master CSV.
- Harden update destination checks and failed-update rollback, validate backup ZIP members before restore, retain a single validated input archive, and align the update launcher with 64-bit PowerShell selection.
- Add pull-request Windows validation, per-branch CI concurrency, synthetic large-library benchmarks and effective-viewport accessibility checks. No release is published by this work.

## 5.6.0 — existing release baseline

- Separate Monthly document receipt, detected cached sections and previously reviewed checklist evidence in a dedicated workspace; preserve checklist effective history.
- Consolidate Review filing actions, retain batch Undo and preserve keyboard focus across background snapshots. Move the Daily receipt calendar into Reports.
- Add eight source-context table-position series, targeted cache upgrades and stable Trends refresh revisions. Keep Classic Windows available.
- Preserve portable offline operation, bundled readers, protected scanner credentials and checked update/backup paths. See the existing versioned validation report for executed baseline tests.

## 4.3.0

- Move scanner status to the top and group historical review items in their own Archive review tab without removing details.
- Clarify saved PDFs, pending report types, cached text reading, and printed results. Review / confirm selected files in Reports.
- Simplify connections, add per-scanner Save & reconnect, remember successful prompt sign-ins, and stop automatic password retry loops.
- Add a scrubbed support ZIP and standalone export that work while the application is open. Include all retained structured activity, timings, counts and fixed error categories; exclude raw logs, passwords, paths and report contents. Retain up to 90 days / 50 MB with serialized cross-process writes.
- Log per-PDF processing outcomes and stop automatic batch scheduling when all saved PDFs have current cached results.
- Add offline ZIP updates with staging, file checks, bounded shutdown waits, automatic restart, rollback copies, and clean end-user packages.

## 4.2.2

- Fix the Windows PowerShell `-File` startup failure caused by resolving `$PSScriptRoot` in parameter defaults in both update helpers.
- Track the password-free network update launcher and exercise its real CMD launch path with spaces, an unrelated working directory, and omitted source/target defaults.
- Preserve reports, customized archive location, previous program backups, and secure password entry.

## 4.2.1

- Apply private connection profiles locally without publishing scanner addresses or passwords.
- Preserve the archive and reviewed evidence when repairing connection settings in an existing installation.
- Authenticate to the SMB share root before accessing the full reports subfolder; reuse readable Windows sessions.
- Keep unrelated drive assignments intact and continue using UNC paths when an optional mapping cannot be created.
- Show Windows authentication, session-conflict, missing-share and folder-permission errors in the import preview.
- Identify factory examples as setup that is not yet configured, and disable confirming a zero-report import.
- Add synthetic network regressions and an existing-installation repair helper.

## 4.2.0

- Redesigned Today dashboard with separate report receipt, extracted printed results, scanner freshness, Monthly evidence, and storage information.
- Added department due days, Daily calendar exceptions, and effective-month checklist history. Historical report revisions remain preserved; current coverage uses the latest revision at each source path.
- Added local PDF analysis with hash caching and supporting page text. Unrecognized or incomplete text needs review. No numeric tolerances, clinical conclusions, or reviewed labels are inferred.
- Added bounded scanner enumeration and reconnection workers, bounded PDF reading, optional checks while the window is open, and a responsive saved-report search.
- Added a portable Data folder, local settings excluded from Git, portable logs, and an updater that verifies file checksums and retains the previous program.
- Added verified full backup/restore to new folders. Backup excludes saved credentials and includes program files, configuration, metadata, review evidence, analysis and readable reports.
- Added readable original-name PDFs, an offline searchable HTML library, and a portable CSV inventory.
- Added computer checks, storage checks, read-only deep source verification, cloud scenario tests, browser tests and a Windows validation/screenshot workflow.

## 4.1.0

Imported the supplied package, bundled PDF reader, licenses and synthetic test fixtures. Workplace network addresses and usernames were replaced with placeholders.

## 4.0.0

Initial source import into this repository.
