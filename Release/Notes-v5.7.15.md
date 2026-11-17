Approved Trends design and requested Monthly changes only:

- **Trends:** scanner tabs, clearer Measurement/Test setup controls, a larger plot, compact latest/change/count summaries, Line/Points/Table views and selected-reading evidence with the original PDF/page link.
- **Reading coverage:** clear PDFs-read/readings-available/waiting counts with the detailed explanation available on expansion. A read PDF without the selected test is still distinguished from an unread PDF.
- **Monthly:** hide Refresh monthly view and move scanner tabs toward the center. Check the host’s cached saved-library snapshot at most every 30 seconds while Monthly is visible and idle. Existing revision checks reload the Monthly model only when relevant data changed; failed Monthly loads retry automatically.

Line/Points/Table switching uses loaded data and sends no new request. All eight measurements, exact units, test contexts, per-PDF printed limits, outside-range/source warnings, source pages, cancellation and existing limits are preserved. There are no new parsers, background scanner scans, PDF re-reads or clinical conclusions. New scanner-file discovery still follows the existing Update reports/monitor settings.

[Download Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.15/CT_QA_Manager_Pro_v5.7.15_Update.zip) — select the ZIP intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.15/CT_QA_Manager_Pro_v5.7.15_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.15/CT_QA_Manager_Pro_v5.7.15_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.15/SHA256SUMS.txt)

Runtime logic changes are limited to four web UI files; other runtime differences are version labels only. Stored reports, settings formats, clinical evidence and Classic fallback remain unchanged. Google Drive and the later proposed custom dates, Trends printing and CSV additions are not included.

Validation uses the existing focused Trends controller check and one synthetic browser flow of the changed Trends/Monthly controls and throttled refresh. It does not validate actual PDF extraction, Windows browsers, hospital workstations or live scanners; no broad suite was run. Delivery verifies source scope, syntax, package integrity and uploaded hashes.
