Requested Monthly layout and navigation changes:

- **Monthly** now uses the scanner-card design: scanner colors, PDF counts, latest report date, Open latest PDF and expandable report/checklist details.
- Use the **previous/next arrows** or **month/year picker** to browse other months. Empty periods show No Monthly PDF saved.
- **Today** separates Daily reports at the top and Monthly cards below a divider. Today always uses the current month, independently of the month selected in Monthly. Clicking a Monthly card shows all that scanner's reports for the current month; the separate latest-PDF button opens one report directly.
- **Reports** opens the Receipt calendar first. Report library is the second tab. Explicit Open library and report-list shortcuts still open the PDF list.

[Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.4/CT_QA_Manager_Pro_v5.7.4_Update.zip) — choose the ZIP intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.4/CT_QA_Manager_Pro_v5.7.4_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.4/CT_QA_Manager_Pro_v5.7.4_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.4/SHA256SUMS.txt)

Validation is limited to one focused Chromium flow with synthetic API/PDF stubs, syntax/build checks and package/upload integrity. It covered month/year navigation, card counts/eligible targets, empty periods, details/setup visibility, current-month Today isolation, Library filters and calendar-first navigation, with no mutation requests, browser errors or external assets. No full native Windows suite, backend/PDF-reading, live-scanner or hospital-workstation testing is claimed for this presentation change. Backend logic, report archives and clinical evidence are unchanged; Windows host version strings are updated and the pinned bundled reader is reused. PDF receipt and detected content do not establish clinical QA approval.
