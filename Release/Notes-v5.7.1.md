Choose the download for your task:

- **[Update your existing program](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.1/CT_QA_Manager_Pro_v5.7.1_Update.zip)**: create a full backup, then open **Settings → Program updates → Choose update ZIP → Install & restart**. Select the ZIP intact. Saved reports, settings, sign-ins and filing decisions stay in place.
- **[Full portable program — new installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.1/CT_QA_Manager_Pro_v5.7.1_Portable.zip)**: extract the complete folder and run **Start CT QA Manager.cmd**.
- **[One-time upgrade — 5.2 and earlier](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.1/CT_QA_Manager_Pro_v5.7.1_Upgrade.zip)**: extract separately, close the old app, run the upgrade helper and select the existing program folder.
- [Visual preview, including saving decisions](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.1/CT_QA_Manager_Pro_v5.7.1_Preview.html)
- [SHA-256 checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.1/SHA256SUMS.txt)

### Review saving fix

- Keep reading the next PDF while earlier single-file decisions save. Other distinct decisions can queue with clear **Sending, Queued and Saving** indicators.
- Prevent duplicate clicks and same-file overlap. Confirm saved status and Undo from the saved result and refreshed library; preserve the PDF currently being viewed.
- Recover from failed/cancelled decisions and interrupted status refreshes. Keep existing archive serialization and bounded queues.
- Avoid redundant overview cache reads while preserving file provenance, Daily schedules, clinical evidence and original PDFs.

The app remains portable and offline, with the existing Light/Dark design, exports, organized folders, Trends and Classic fallback. Filing as Daily, Monthly or Other does not approve clinical QA measurements.

### Validation scope

The actual Windows application tests passed: **18 PowerShell 5.1 suites / 413 scenarios / 4,320 assertions**, and **six Edge workloads / 115 scenarios / 30,682 assertions**, including the Review queue's five scenarios. Reader comparison, selected-PDF lookup, large-library integrity and Classic captures also passed.

The overall Windows workflow [43929342040](https://github.com/rtariq2015/QA-Manger/actions/runs/43929342040) is **failed** because its scheduler test tried to parse a readiness file before its JSON write completed. Its final real-reader/deadline checks are not claimed as native passes. The corrected bounded readiness probe passed a focused **Linux** scheduler run with all 18 groups, including the actual 90-second helper cleanup. At the user's direction, the full repeat [43938032793](https://github.com/rtariq2015/QA-Manger/actions/runs/43938032793) was cancelled; it is not recorded as a pass. Application and host source bytes remain unchanged from the Windows-tested build.

Complete package manifests, the executed Windows host, all 103 pinned Python components, licensing and synthetic 5.7.0 → 5.7.1 preservation were checked separately. Details and the known validation limitation are recorded in **docs/TESTING.md** and **Tests/Releases/v5.7.1** on the release source branch. No hospital deployment, live-scanner connectivity, actual OS-DPI certification or hospital IT approval is claimed.
