# Testing and practical limits

The cloud development scenario uses generated PDFs and local folders representing three scanners. No real scanner reports, credentials, or clinical records are used.

The synthetic tests cover receipt calendars, explicit printed results, separate Monthly component PDFs, combined PDFs, changed report revisions, unavailable sources, cancelled transfers, interrupted transactions, corrupted reports, readable folders, exports, backup verification, rejected tampered backups, restore into a new folder, folder moves, saved configuration and verified upgrades.

The offline library is also tested in Chromium for searching, no results, reset, relative links and actual PDF targets. The README image is a screenshot of this generated library with synthetic files.

## Windows validation

The GitHub **Windows validation and visual preview** workflow runs all seven suites under Windows PowerShell 5.1. It also loads WPF and captures a native dashboard populated only with synthetic demonstration data. Download its `windows-validation` artifact for the JSON results and image. Check the actual workflow result; the existence of the workflow does not mean it passed.

The Linux cloud suite and the dedicated hosted Windows suite have both run. The Windows run additionally exercised native PowerShell 5.1 and DPAPI and rendered WPF. These checks do not establish real scanner authentication, interactive high-DPI behavior, workstation endpoint approval, or hospital SMB performance. Follow `Tests/Windows-Smoke.md` on the approved work computer. The original v4.1.0 reports remain historical evidence; current-run reports live in `Tests/Current`.

## Operating limits

- Checks and reminders run only while the application window is open. There is no service, installed task, or closed-app notification.
- Scanner access still depends on the workstation's existing network permissions. An unavailable source does not establish missed QA.
- Reconnection and enumeration run in bounded helper processes. A Windows network read already in progress during a file transfer can still wait for the OS to return before the next safe cancellation checkpoint.
- The optional PDF reader needs the workstation's existing .NET Framework 4.7.2+ and approval for the bundled DLLs. No runtime is installed or downloaded by the application.
- OCR is not included. Explicit `Noise: PASS` / `MTF: FAIL` style lines can be extracted with page evidence; actual scanner templates require redacted examples to extend recognition. Unrecognized text stays for review. No department-specific numerical limits are assumed.
- Receipt, extracted printed results, reviewed classification and complete checklist evidence are distinct. Provisional filename/size grouping alone does not satisfy the Today receipt headline.
- Fast updates use metadata. Use saved-file integrity audit and the separate scanner-source fingerprint check when deeper verification is needed.
- Cached analysis is derived data keyed by PDF fingerprint. Changed files require new analysis; review labels remain independent.
- Same-drive readable copies and same-drive backups do not protect against drive failure. Keep a verified backup on approved separate storage.
- Saved sign-ins are Windows account/workstation bound and excluded from full backups. Re-enter them after moving to another computer.
- The updater verifies package integrity, preserves local settings/data, and keeps the previous App folder. Obtain release packages from this repository; checksums alone do not authenticate an unknown publisher.
- SHA-256 manifests and review history detect ordinary inconsistencies; they are not a signed, tamper-proof audit system.

The Windows runs exposed and helped fix managed/readable path-length failures and duplicate-name suffix handling. The application keeps managed names compact and shortens readable filenames when needed; original names remain in the index and offline inventory. Very long workspace roots can still exceed Windows PowerShell 5.1 path limits; choose a short local folder.
