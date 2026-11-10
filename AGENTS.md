# Project instructions

This is a portable Windows PowerShell 5.1 / WPF application for a restricted work computer. Keep normal use free of installers, administrator rights, new runtime installations, and external PowerShell modules. Preserve execution policy, UTF-8 BOMs, and launcher line endings.

Use the GitHub repository `rtariq2015/QA-Manger` to track authorized project updates with descriptive commits and pushes. Preserve existing history. Do not include real reports, credentials, live archive data, or workstation-specific configuration in commits. The tracked settings file is the imported baseline.

Run checks appropriate to the change; `python Tests/Verify-Package.py` covers static package structure. Windows runtime and WPF behavior require Windows validation. Never present the historical test reports as newly executed results.
