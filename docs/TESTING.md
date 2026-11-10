# Testing and practical limits

The final v5.0.0 Windows validation passed at source commit `b468e750188de9aa6c1b5020d0e9fdd702379e71` in [workflow run 42897377290](https://github.com/rtariq2015/QA-Manger/actions/runs/42897377290). All test PDFs, scanner folders, identities and password canaries are synthetic. No hospital reports or real credentials were used.

| Execution | Scenarios | Assertions | Failed | Saved evidence |
| --- | ---: | ---: | ---: | --- |
| Windows PowerShell 5.1: twelve native suites | 189 | 1,199 | 0 | [Windows summary](../Tests/Current/Windows/Summary.json) and its unmodified `Run-*.json` reports |
| Windows Edge: actual self-contained host and PowerShell adapter | 10 | 240 | 0 | [Windows browser report](../Tests/Current/Browser-Web-Windows.json) |
| Linux PowerShell 7.4.13: development suites | 184 | 1,139 | 0 | [Development summary](../Tests/Current/Summary.json) and root `Run-*.json` reports |
| Linux Chromium: actual local host and adapter | 10 | 236 | 0 | [Linux browser report](../Tests/Current/Browser-Web.json) |

The Windows run is the final pinned release validation. Linux results are separately labeled development evidence, not proof of Windows behavior. Some native suites retain older feature-version labels internally; their raw files were copied unchanged from the final successful run. Earlier v4.4.1 evidence is preserved under [Tests/Historical/v4.4.1](../Tests/Historical/v4.4.1).

## What the browser run exercised

The browser tests use the real Kestrel host, Windows PowerShell worker, archived synthetic PDFs and durable organization state. They do not mock the application API.

- Missing session authentication, hostile origins, unsupported shell-style actions and invalid PDF/page identifiers are rejected.
- Today, Reports and Settings load without external interface assets or JavaScript errors. Windows renders an actual PNG page through the native PDF renderer; the report verifies that rendering ran.
- Approve has no reviewer-name form or second confirmation. Undo restores pending; Disapprove retains the PDF under Other. Every decision preserves original PDF and scanner-source hashes, the exact core archive-state bytes, existing reviewer fields and checklist evidence.
- A stale approval cannot overwrite a newer decision. Organization decisions and Undo metadata survive a full host restart; the previous process token is rejected.
- Scanner/type filters drive a ZIP containing exactly the matching PDFs, each checked against its original SHA-256, plus an offline summary.
- A connection failure remains visible, an entered synthetic password does not appear in public job results, and the password input is cleared.
- At 1024×768, Approve and Disapprove remain visible. Real mouse clicks on Undo and an offline approval after a failed scanner connection are unobstructed by notifications.

The fresh Windows screenshots in [docs/images](images) show Today, Reports, Settings and the smaller Reports layout, using synthetic data only. They are actual interface captures, not design mockups.

## Existing protections retained

The native suites continue to exercise archive/source preservation, changed revisions, writer locks, stale decisions, interrupted-copy recovery, cancellation, separate/combined Monthly component evidence, readable copies, exports, verified backup/restore, configuration portability, path/collision handling, protected Windows credentials, CMD launchers and offline update/restart behavior.

The v5 adapter tests additionally cover classification-only sidecar history, unchanged-import persistence, preserved core clinical evidence, owned readable-library copies, rejection of modified PDFs, ZIP fingerprints and JSON worker transport. Browser classification is separate from formal QA verification: clicking Approve does not fabricate a clinical reviewer, printed PASS/FAIL or completed Monthly checklist.

Support exports reconstruct allowlisted counts, operation outcomes, timings and Windows error numbers. Privacy tests use synthetic canaries to check that passwords, report text, filenames, paths, usernames, network addresses and raw logs do not enter shareable bundles. Full retained structured logs normally keep up to 90 days / 50 MB. Nothing is uploaded automatically.

## Reproducing checks

The development environment needs the .NET SDK to build the host and Node/Playwright for browser tests. These are build/test tools, not installations required on the work computer.

The Windows validation workflow builds the self-contained Windows host, executes the native suites with Windows PowerShell 5.1, and runs:

```text
node Tests/Web/run-all.cjs --windows --output artifacts/web
```

That command creates a new synthetic workspace, launches the packaged host, runs Edge against it, restarts the host, and checks saved results. `Tests/Web/New-WebFixture.ps1` refuses an existing fixture destination. Browser output, generated report ZIPs and screenshots contain synthetic data. The work-computer smoke checks are listed in [Windows-Smoke.md](../Tests/Windows-Smoke.md).

## Practical limits

- The shipped web host includes its runtime; it still depends on the existing Windows PowerShell 5.1 and native Windows components used by the original application. Endpoint policy can block an executable, scripts, local browser access or scanner shares. Hosted tests cannot approve hospital policy or establish real network access.
- Scanner collection needs the hospital's internal network. Saved reports, classification, search and export work locally. An unavailable scanner or missing archived PDF does not establish a clinical QA failure.
- The interface is served on loopback, not as a public or hospital-LAN website. Core interface assets are bundled; no internet connection or automatic report upload is required.
- Automatic checks run only while the local app is running. There is no installed service, scheduled task or closed-app notification. Use the app's close action to stop its local helper.
- PDF analysis reuses cached content fingerprints. OCR is not included. Unrecognized or incomplete text stays for review, and no department-specific numerical limits are assumed. Receipt, document classification, extracted printed results and formal checklist evidence remain separate.
- Network enumeration and PDF rendering have bounded workers, but a Windows file read already in progress may still wait for the operating system before a safe cancellation checkpoint.
- The readable library is a convenience copy backed by the existing verified archive and history. Same-drive copies/backups do not protect against drive loss. Keep an approved separate backup.
- Windows-encrypted scanner sign-ins can need re-entry after moving to another Windows user or computer. Updates preserve existing local settings and data; do not manually replace the archive with a fresh program folder.
- Update manifests detect inconsistent files; they do not authenticate an unknown publisher. Existing history is not a signed, tamper-proof audit system. Very long Windows paths can still require a shorter workspace location.
- Native routed-key and browser interaction checks are not physical keyboard/IME, manual folder-picker, workstation DPI or real hospital performance tests. Run the approved workstation checks before relying on a new deployment.
