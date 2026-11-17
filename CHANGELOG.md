# Changes

## 5.7.13 — calendar and PDF printing options

- Add Print calendar for the current month/scanner, with a clean landscape print layout containing the calendar, scope, totals and receipt disclaimer. Hide application menus and unrelated pages when printing.
- Add Print PDF in the shared viewer. It opens the complete original report in the browser, where the printer icon or Ctrl+P prints all pages. Do not print the lazy-loaded preview images.

## 5.7.12 — calendar scanner tabs

- Replace Receipt calendar’s scanner dropdown with clickable All scanners and configured-machine buttons. Preserve scanner accent colors, selection state, names, receipt calculations, month navigation and day-to-library filtering. Wrap the controls on smaller screens.

## 5.7.11 — document-first Review

- Give the PDF the full Review width until the file list is opened; remove repeated Current PDF information from the main layout. Keep grouped and batch review accessible.
- Place current-file filing choices, saved status and Undo below the PDF. Use File as Daily/Monthly/Other and Choose another type, with Keep as Other available among the alternatives. These actions save file labels, not clinical QA approval.
- Rename Open PDF to Open in new tab, keep Details collapsed with the original filename and filing reason, and retain Expand PDF under More options. Keep 100% default zoom, continuous scrolling, existing preview caches and processing unchanged.

## 5.7.10 — Back button beside Open folders

- Move Report Library’s existing Back to Today button from the top view tabs to the action row immediately beside Open folders. Keep its label, destination and visibility behavior unchanged.

## 5.7.9 — direct return to Today and 100% PDF zoom

- Show an explicit Back to Today button above Report Library filters, including Monthly report lists, regardless of how the list was opened. Return directly to the main screen.
- Open each new PDF at 100% by default in the built-in preview and request 100% in the browser PDF viewer. Keep Fit page, Fit width, scrolling and the existing PDF Back button.

## 5.7.8 — clearer saved-report message and Monthly Back button

- Enlarge Today’s saved-report message and explain that reports are organized by scanner and date.
- Add a small Back button to Monthly report lists, returning to Today or Monthly according to where the list was opened. Retain the PDF viewer’s existing Back behavior and report filters.
- Keep existing report, Monthly, analysis and preview caches; no processing or stored-data changes.

## 5.7.1 — responsive single-file review

- Let distinct single-file filing decisions queue while staff read the next PDF. Show Sending, Queued and Saving states until a durable result and fresh snapshot confirm completion; preserve the PDF currently being viewed.
- Prevent rapid duplicate submissions, same-file overlaps and queue overflow. Keep Undo, grouped decisions and other mutations blocked while saves are unconfirmed; handle failed/cancelled jobs and jobs observed after reload conservatively.
- Reuse each snapshot's validated analysis rows for analysis counts and use the shared scheduling predicate for Daily receipt. Remove the second whole-library analysis-cache pass and the unused current-day findings pass without changing provenance checks, filing stamps, clinical evidence or saved data formats.

## 5.7.0 — workstation engineering upgrade

- Add a medical imaging-console visual system across all eight workspaces: pearl/slate surfaces, navy navigation, refined controls and bundled brand-neutral CT gantry/bed illustrations. Inline vector artwork keeps the existing offline update path and adds no image downloads or dependencies.

- Bound the Reports list to 100 visible rows with keyboard-aware page navigation, debounced searches, reused metadata sorting and unchanged-view reuse. Exports continue to include every matching report.
- Increase readable text sizes and contrast, add Comfortable/Compact display density, improve narrow/short-window Review layouts, and add named dialogs, keyboard-accessible PDF scrolling and complete Settings tab semantics. Preserve Light/Dark modes and scanner accents.
- Make file-label confirmation explicit; keep clinical results and formal reviewed evidence separate. Compact expandable Monthly scanner details retain existing calculations and checklist history.
- Resolve selected PDFs from fresh validated archive records without rebuilding unrelated dashboards; keep exact path and SHA-256 checks.
- Reject ambiguous archive identities/destinations and linked metadata without rewriting stored data. Neutralize spreadsheet formula prefixes only in the derived master CSV.
- Harden update destination checks and failed-update rollback, validate backup ZIP members before restore, retain a single validated input archive, and align the update launcher with 64-bit PowerShell selection.
- Add pull-request Windows validation, per-branch CI concurrency, synthetic large-library benchmarks and effective-viewport accessibility checks. Release publication is separately authorized and uses the exact Windows-tested runtime source.

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
