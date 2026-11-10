# CT QA Manager Pro

Portable CT quality-assurance report manager for Windows, built with Windows PowerShell 5.1 and native WPF. This repository tracks the supplied **v4.0.0** project.

## Run without installing software

1. Choose **Code → Download ZIP** on GitHub and extract the complete folder to a user-writable local folder.
2. Double-click **Start CT QA Manager.cmd**. Keep `App`, `Config`, and the launcher together.
3. Complete **First-Time Setup** in the application and select a separate, approved local archive folder.

Normal use requires no installer, administrator launch, Python, Git, or third-party PowerShell modules. It uses the Windows PowerShell 5.1 and WPF components supplied with Windows. Workstation policy may require IT approval or script signing. The launcher preserves execution policy.

The application reads scanner report folders, previews imports, copies and indexes PDFs, identifies reports needing review, and offers a manual integrity audit. See the [User Guide](User%20Guide.html) for the full workflow. Download and open the HTML guide locally to view its formatting.

## Version and validation

The 17 files from `CT_QA_Manager_Pro_v4.0.0.zip` form this baseline. Before upload, workplace scanner addresses and the suggested username were replaced with generic placeholders in four files: `App/Archive.psm1`, `App/Start.ps1`, `Config/Settings.json`, and `User Guide.html`. Configure authorized scanner paths and usernames in the deployed application. The other 13 supplied files are byte-for-byte unchanged. Original ZIP hashes and supplied validation results remain in `Tests`; `Tests/Repository-SHA256SUMS.txt` records this sanitized import. The package verifier passed **370 static checks** during import. The supplied test reports are historical build evidence; Windows PowerShell 5.1 execution, WPF rendering, scanner authentication, and workstation policy still need acceptance testing on Windows.

- [Windows acceptance checklist](Tests/Windows-Smoke.md)
- [Supplied validation report](Tests/Validation.html)
- [Original file hashes](Tests/SHA256SUMS.txt)

The repository previously contained only a README describing v4.1.0. That text is retained in [docs/Previous-README.md](docs/Previous-README.md) for reference. Its newer feature claims and linked files do not describe this v4.0.0 source import.

## Tracking future updates

Use this repository as the source of truth. Each completed update should have a descriptive Git commit and be pushed here. GitHub records changes after they are committed and pushed; it does not automatically synchronize edits made in a downloaded work-computer copy.

Keep development work separate from the deployed application and its live archive. The imported `Config/Settings.json` is a tracked baseline; keep later workstation-specific settings in the deployed copy. Do not commit real reports, credentials, live archive indexes, or logs. The repository remains private.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks and portability requirements. No project license has been selected.
