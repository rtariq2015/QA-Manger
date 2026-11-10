# Testing and practical limits

The cloud development scenario uses generated PDFs and local folders representing three scanners. No real scanner reports, credentials, or clinical records are used.

The synthetic tests cover receipt calendars, explicit printed results, separate Monthly component PDFs, combined PDFs, changed report revisions, unavailable sources, cancelled transfers, interrupted transactions, corrupted reports, readable folders, exports, backup verification, rejected tampered backups, restore into a new folder, folder moves, saved configuration and verified upgrades.

The offline library is also tested in Chromium for searching, no results, reset, relative links and actual PDF targets. The README image is a screenshot of this generated library with synthetic files.

## Windows validation

The GitHub **Windows validation and visual preview** workflow runs all eleven suites under Windows PowerShell 5.1. It also loads WPF and captures six native screens populated only with synthetic demonstration data. Download its `windows-validation` artifact for the JSON results and image. Check the actual workflow result; the existence of the workflow does not mean it passed.

The Linux cloud suite and the dedicated hosted Windows suite have both run. The Windows run additionally exercised native PowerShell 5.1 and DPAPI and rendered WPF. These checks do not establish real scanner authentication, interactive high-DPI behavior, workstation endpoint approval, or hospital SMB performance. Follow `Tests/Windows-Smoke.md` on the approved work computer. The original v4.1.0 reports remain historical evidence; current-run reports live in `Tests/Current`.

The v4.4.0 review suite checks explicit Accept/Decline decisions, checklist boundaries, persistent Undo snapshots, stale decisions, unchanged rescans and reviewed-other browsing and exports. Windows additionally renders an actual synthetic PDF and clicks through the native workspace to verify Skip, Accept, Undo and Decline. These synthetic reports contain no clinical data.

## Operating limits

- Checks and reminders run only while the application window is open. There is no service, installed task, or closed-app notification.
- Scanner access still depends on the workstation's existing network permissions. An unavailable source does not establish missed QA.
- Reconnection and enumeration run in bounded helper processes. A Windows network read already in progress during a file transfer can still wait for the OS to return before the next safe cancellation checkpoint.
- The optional PDF reader needs the workstation's existing .NET Framework 4.7.2+ and approval for the bundled DLLs. No runtime is installed or downloaded by the application.
- The visual preview uses the Windows PDF renderer already supplied with Windows. If endpoint policy blocks it, use the approved default PDF viewer. Preview workers are bounded and do not change the file.
- OCR is not included. Explicit `Noise: PASS` / `MTF: FAIL` style lines can be extracted with page evidence; actual scanner templates require redacted examples to extend recognition. Unrecognized text stays for review. No department-specific numerical limits are assumed.
- Receipt, extracted printed results, reviewed classification and complete checklist evidence are distinct. Provisional filename/size grouping alone does not satisfy the Today receipt headline.
- Fast updates use metadata. Use saved-file integrity audit and the separate scanner-source fingerprint check when deeper verification is needed.
- Cached analysis is derived data keyed by PDF fingerprint. Changed files require new analysis; review labels remain independent.
- Same-drive readable copies and same-drive backups do not protect against drive failure. Keep a verified backup on approved separate storage.
- Saved sign-ins are Windows account/workstation bound and excluded from full backups. Re-enter them after moving to another computer.
- The updater verifies package integrity, preserves local settings/data, and keeps the previous App folder. Obtain release packages from this repository; checksums alone do not authenticate an unknown publisher.
- SHA-256 manifests and review history detect ordinary inconsistencies; they are not a signed, tamper-proof audit system.

The Windows runs exposed and helped fix managed/readable path-length failures and duplicate-name suffix handling. The application keeps managed names compact and shortens readable filenames when needed; original names remain in the index and offline inventory. Very long workspace roots can still exceed Windows PowerShell 5.1 path limits; choose a short local folder.

## Network update tests (4.2.1)

`Tests/Run-NetworkTests.ps1` uses synthetic profiles and mocked Windows network API boundaries to check share-root authentication, complete folder paths, occupied letters, mapping races, native error numbers, preserved data and profile privacy. These tests do not contact hospital scanner addresses or authenticate with real passwords. A private network profile is deliberately absent from this repository. The real workstation must still verify share access.

## Updater startup regression (4.2.2)

The network suite launches the tracked `Apply CT QA Network Update.cmd` through Windows CMD and Windows PowerShell 5.1, omits `SourceFolder`, and supplies the target noninteractively. Source and target paths contain spaces, and the working directory is unrelated. It also launches the normal upgrader without `TargetFolder`. This catches startup errors caused by evaluating `$PSScriptRoot` before the script body. Report preservation, archive settings, and previous-program copies are asserted after the update. Interactive folder-picker clicks and app relaunch still require the workstation check.

## Review, support and offline update validation (4.3.0)

`Run-SupportTests.ps1` verifies that hundreds of historical findings are grouped without changing the originals, provisional Daily files remain in the pending verification filter, rejected credentials do not trigger an automatic prompt loop, and only accepted credentials are eligible for remembering. Diagnostic canaries cover free text, filenames, paths, usernames, unknown statuses, raw logs, report fingerprints and extracted evidence. Exports rebuild an allowlisted summary and can run while the application lock is held; the Windows test also starts the production diagnostic CMD.

`Run-UpdateTests.ps1` checks isolated staging, complete manifests, unexpected files, ZIP traversal/ADS/reserved names, duplicate paths, links, modified staged files, protected data/settings, rollback copies and safe cleanup. The helper waits for a released application lock; a still-held lock stops installation. Windows additionally verifies that the normal launcher is started after the successful update. Checksums do not authenticate a publisher.

The actual clean release was also used to upgrade a synthetic v4.2.2 installation. Existing settings, encrypted-credential-file preservation sentinel, data and custom archive files retained their byte hashes, a previous-program copy was created, and the packaged standalone diagnostic collector worked against the upgraded installation. This test does not authenticate the sentinel or contact a scanner. Clean packages exclude development folders; private profiles and passwords are excluded from generic update packages. The five recorded WPF screens are synthetic previews, not captures of a clinical workstation.

## Complete scrubbed log bundle

Support ZIPs rebuild every included activity record from fixed operation/outcome/error enums and numeric count/timing fields. They include all retained structured events rather than only the 200-event summary. Owned logs rotate at 1 MB, normally retain up to 90 days and have a 50 MB aggregate cap; a named mutex serializes worker writes. Existing Activity.csv files contribute only recognized dates, operation names and numeric counts when readable and within 20 MB. Free-text details and raw startup/activity logs never enter the bundle.

Privacy tests inject private canaries into arbitrary fields, legacy details, PDF evidence and unknown statuses, inspect every ZIP entry, and verify three concurrent workers retain sixty events. Windows tests run the standalone ZIP export while the application lock is held. The .NET Framework compression assemblies are loaded explicitly. Per-PDF events record only safe aliases/counts, and automatic reading pauses when its queue is empty. Failed reads stay cached until the destination changes or a manual retry is requested.

The Releases workflow publishes only generic clean assets after checking that the recorded native Windows run succeeded and that its runtime source matches the release commit. It rejects any private local profile in the build checkout. Uploaded assets are first attached to a draft, then published together. Release checksums detect corruption; they are not a publisher signature.


## Reviewer input patch (4.4.1)

The review regression now exercises native routed key events before appending each character, Backspace, reviewer names with punctuation and the production F1 handler. A cross-platform test executes the actual dispatcher handler with an error event and verifies that it marks that event handled and preserves the original message. The launcher test executes the production CMD with a harmless PowerShell stub and verifies quiet startup plus its normal Startup.log. These tests address paths missed when the earlier test set the reviewer TextBox text directly. They do not claim to automate a physical keyboard or IME.
