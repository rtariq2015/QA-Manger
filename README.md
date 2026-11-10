# CT QA Manager Pro

![Illustrative dashboard and report-export concept](docs/images/concept-preview.png)

*Illustrative concept with example data; not a verified screenshot of native Windows rendering.*

A portable Windows application for collecting, organizing, finding, and exporting CT quality-assurance report PDFs. Built with native WPF and Windows PowerShell 5.1 for a straightforward department-supervisor workflow.

> **Validation status:** v4.1.0 passed **104 synthetic scenarios and 797 assertions** using PowerShell 7.4.19 on Linux. Actual Windows PowerShell 5.1 execution, WPF rendering, Windows DPAPI, scanner authentication, and hospital-network operation still require workstation acceptance testing. This is an initial source upload, not a claim of validated hospital deployment.

## Everyday workflow

1. **Set up once.** Choose an approved local archive folder, configure scanner connections, inspect the import preview, and approve the initial copy.
2. **Update reports.** After setup, opening the application starts one update by default. Use the Settings checkbox to disable this, or click **Update Reports** whenever needed.
3. **Find, browse, or export.** Open the readable folders, filter by scanner/month/year/QA type, or prepare a ZIP package for a local folder or USB drive.

The application does not install a service or scheduled task. Original scanner PDFs remain read-only.

## Features

| Feature | What it does |
| --- | --- |
| Scanner dashboard | Shows configured scanner connections, saved report counts, and last successful updates. Supports up to 20 connections. |
| Incremental archive | Skips unchanged metadata, preserves changed-file revisions and distinct sessions, and verifies new copies with SHA-256. |
| Two folder views | Keeps the managed archive alongside independent, readable copies organized by scanner, year, month, and QA type. |
| Search and report packages | Filters one or several years, a month, scanners, report types, and text. Exports every matching report with a CSV list and linked offline HTML summary. |
| Monthly checklist coverage | Combines explicitly reviewed items from one comprehensive PDF or several separate PDFs for the same scanner and month. |
| Attention center | Distinguishes unavailable connections, absent saved records, pending report labels, incomplete reviewed checklist evidence, and transfer/integrity issues. |
| Secure connections | Provides editable paths and usernames plus optional Windows DPAPI-encrypted sign-ins bound to the connection and Windows account. |
| Local PDF text reader | Uses bundled PdfPig components to extract existing text and identify test-name hints, without sending PDFs to a cloud service. OCR is not included. |
| Recovery and audit | Supports interrupted-copy recovery, activity history, legacy archive adoption, and an optional full saved-file integrity audit. |

## Run on Windows

1. Download the repository with **Code → Download ZIP**, or clone it. Extract the complete folder to a user-writable local location, such as the Desktop.
2. Double-click **Start CT QA Manager.cmd**. Keep `App` and `Config` beside the launcher.
3. Configure authorized scanner shares in the application, for example `\\SERVER\Share\ConstancyReports`.
4. Complete **First-Time Setup** before relying on automatic updates.

The repository contains generic hostnames and `SCANNER_USERNAME` placeholders. Configure actual connections in the app; its saved `Config/Settings.json` and encrypted credentials are ignored by Git. `Config/Settings.example.json` documents the initial settings schema.

Normal use requires no Python installation, traditional installer, paid dependency, or administrator launch. Windows PowerShell 5.1 and WPF are required. The optional PDF text reader also requires .NET Framework 4.7.2 or newer. Follow hospital IT policy if scripts or bundled assemblies require approval; do not weaken execution policies or endpoint protection.

Archive and export destinations must be direct local-disk or USB folders. Network and mapped-drive destinations are rejected to prevent a scanner-share alias from becoming a write destination. USB is an optional destination for exported reports; the application can run from its folder on the computer.

## Development checks

The **Manual Windows validation** workflow can be run from GitHub Actions. It runs synthetic suites with Windows PowerShell 5.1 and loads the native WPF layout. It has not been run yet; a successful layout load would still not validate scanner access, interactive dialogs or DPI. No automatic or scheduled workflow is configured.

## Documentation and validation

- [User guide](User%20Guide.html)
- [Understanding Siemens QA reports](App/Reference/Siemens_QA_Guide.html)
- [Validation report](Tests/Validation.html)
- [Machine-readable test summary](Tests/Test-Summary.json)
- [Windows acceptance checklist](Tests/Windows-Smoke.md)
- [Changes](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security and privacy](SECURITY.md)

GitHub displays HTML source in repository views. Download the project and open the HTML files locally for their formatted presentation.

## Documentation evidence, not clinical certification

The department's approved procedure determines the Monthly checklist; no universal checklist is assumed. File size, a generic Constancy filename, or detected test wording cannot confirm complete Monthly QA. A report label and a complete set of reviewed checklist items are separate concepts. Missing PDFs do not establish that clinical QA was omitted or that equipment is noncompliant.

Fast updates depend on metadata. Source edits that preserve size and timestamps are outside the fast cache's detection. The integrity audit checks saved PDFs against recorded hashes. The readable folder view is an independent local copy; a separate approved backup location is needed for protection from device failure.

## Repository privacy and licensing

Keep real reports, live network configuration, passwords, credential envelopes, archive indexes, and logs out of Git. Use synthetic fixtures for development and issue reports. See [SECURITY.md](SECURITY.md).

A project license has not been selected. Bundled third-party components retain their own Apache-2.0 and MIT licenses and notices in [App/Lib/PdfPig](App/Lib/PdfPig).
