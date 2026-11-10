# Changes

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
