# CT QA Manager Pro

Portable CT quality-assurance report manager for Windows, built with Windows PowerShell 5.1 and native WPF. **v4.1.0** is the current source baseline, imported from `CT_QA_Manager_Pro_v4.1.0.zip`. The earlier v4.0.0 import remains in Git history.

## Run without installing software

1. Choose **Code → Download ZIP** on GitHub and extract the complete folder to a user-writable local folder.
2. Double-click **Start CT QA Manager.cmd**. Keep `App`, `Config`, and the launcher together, including the bundled `App/Lib` files.
3. Configure authorized scanner shares and usernames in the application, then complete **First-Time Setup** using an approved local archive folder.

Normal use requires no installer, administrator launch, Python, Git, or third-party PowerShell modules. It uses Windows PowerShell 5.1 and native WPF supplied with Windows. The optional bundled PDF text reader requires .NET Framework 4.7.2 or newer already on the workstation. The app does not install or download runtimes. Workstation policy may require IT approval or script signing; the launcher preserves execution policy.

The repository uses generic scanner hostnames and `SCANNER_USERNAME` placeholders. Configure the real connections in your deployed copy.

## Features in v4.1.0

- Incremental, verified PDF archiving with import previews, recovery, and manual integrity audits.
- Report search by scanner, date, and type, with ZIP exports and an offline HTML summary.
- Independent readable folders organized by scanner, year, month, and report type.
- Editable scanner connections and optional Windows DPAPI-encrypted sign-ins.
- Department-configured Monthly checklist evidence and explicit report review.
- Local PDF text extraction using bundled PdfPig libraries; OCR is not included.
- One update when opening the app after setup, enabled by default and configurable in Settings. No service or scheduled task is installed.

Scanner PDFs remain read-only. Archive and export destinations must be local-disk or USB folders. See the [User Guide](User%20Guide.html) for the full workflow and [Siemens QA reference](App/Reference/Siemens_QA_Guide.html) for report terminology. Download and open HTML documents locally to view their formatting.

## Import and validation

All 53 supplied files are included, including the bundled DLLs, their licenses, and three synthetic PDF fixtures. Workplace addresses and the suggested username were replaced with placeholders in `App/Archive.psm1`, `App/Start.ps1`, `Config/Settings.json`, and `User Guide.html`. The other 49 supplied files are byte-for-byte unchanged.

The package verifier passed **465 static checks** during this import. The supplied reports record **104 scenarios and 797 assertions** on PowerShell 7.4.19 on Linux; those suites were not rerun during import. Windows PowerShell 5.1 execution, native WPF rendering, DPAPI, scanner authentication, and workstation policy still need Windows acceptance testing.

- [Windows acceptance checklist](Tests/Windows-Smoke.md)
- [Supplied validation report](Tests/Validation.html) and [test summary](Tests/Test-Summary.json)
- [Original ZIP hashes](Tests/SHA256SUMS.txt) and [sanitized repository import hashes](Tests/Repository-SHA256SUMS.txt)
- [Bundled library provenance and licenses](App/Lib/PdfPig/README.txt)

The repository's original standalone README is retained in [docs/Previous-README.md](docs/Previous-README.md) for historical reference. Use this README and the supplied source as the current description.

## Tracking updates

Use this repository as the source of truth. Commit and push each completed update to record its changes. Downloaded work-computer copies do not synchronize automatically with GitHub.

Keep development separate from the deployed application and live archive. `Config/Settings.json` is a tracked, generic baseline; keep workstation-specific settings in the deployed copy. Do not commit real reports, credentials, archive indexes, or logs. The repository remains private.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks and portability requirements. A project license has not been selected; bundled third-party libraries retain their own licenses.
