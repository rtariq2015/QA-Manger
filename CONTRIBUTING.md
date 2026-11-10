# Development

The repository is the source of truth for CT QA Manager Pro. Commit each completed change with a clear message and push it to GitHub. Use a branch and pull request when review is useful. Do not force-push or rewrite existing history.

## Workstation requirements

- Keep normal operation portable: no installer, administrator rights, external runtime downloads, or third-party modules.
- Target Windows PowerShell 5.1 and native WPF. Python is only a development-time package checker.
- Preserve UTF-8 BOMs in PowerShell files and Windows launcher line endings.
- Preserve execution policy and work with the workstation's IT controls.
- Keep scanner sources read-only and use synthetic data for development.
- Keep real PDFs, credentials, archive metadata, logs, and deployed settings out of commits. `Config/Settings.json` and `Settings.example.json` are tracked generic baselines. The running application writes `Settings.local.json`, which is ignored by Git.

## Checks

From the repository root, run the static package checker on a development machine with Python:

```sh
python Tests/Verify-Package.py
```

On an approved Windows development workstation, run the supplied synthetic suite and layout validation with the Windows PowerShell already supplied with Windows:

```powershell
powershell.exe -NoProfile -File .\Tests\Run-Tests.ps1 -OutputPath "$env:TEMP\CTQA-Windows-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-ExportTests.ps1 -OutputPath "$env:TEMP\CTQA-Export-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-ConnectionTests.ps1 -OutputPath "$env:TEMP\CTQA-Connection-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-BrowseTests.ps1 -OutputPath "$env:TEMP\CTQA-Browse-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-MonthlyTests.ps1 -OutputPath "$env:TEMP\CTQA-Monthly-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-PdfTests.ps1 -OutputPath "$env:TEMP\CTQA-Pdf-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-PortableTests.ps1 -OutputPath "$env:TEMP\CTQA-Portable-Test-Results.json"
powershell.exe -NoProfile -File .\Tests\Run-PortableTests.ps1 -OutputPath "$env:TEMP\CTQA-Portable-Test-Results.json"
powershell.exe -NoProfile -STA -File .\App\Start.ps1 -ValidateLayout
```

Follow `Tests/Windows-Smoke.md` for interactive acceptance. Record the runtime and distinguish newly executed checks from reports supplied in the ZIP. The original v4.1.0 manifest is retained as `Tests/Original-v4.1.0-SHA256SUMS.txt`. Regenerate `Tests/Repository-SHA256SUMS.txt` when packaging a release. Create a new version's manifest when packaging later releases. Keep the bundled DLLs and their licenses together. Only the three supplied synthetic PDFs in `Tests/Fixtures/PdfReader` are allowed through the PDF ignore rule.

Develop and deploy in separate folders. Downloaded work-computer copies do not synchronize automatically with GitHub, and updates must preserve the deployed configuration and archive.

The Windows workflow runs all suites and captures only synthetic demonstration data. Read `docs/TESTING.md` for practical limits. No installer, service or scheduled task may be introduced. Browser screenshots of the offline library are real generated artifacts; do not present them as native WPF screenshots.
