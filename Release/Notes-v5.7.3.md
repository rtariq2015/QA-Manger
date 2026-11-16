Requested dashboard and folder-opening fixes only:

- **Open library** always opens the Library list, clears old calendar/search filters, and shows Daily PDFs from the latest available report date.
- Click a scanner's Daily card to open its latest saved Daily PDF. Its date is displayed, including when the latest report is from an earlier day.
- Each scanner now has its own Monthly received/missing row. A received row opens the latest saved Monthly PDF for the current month. The separate Monthly tab remains available.
- **Open report folders** reuses an existing readable folder instead of rebuilding the report library and overview each time. First-time folder creation and normal import/filing maintenance stay in place.

[Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.3/CT_QA_Manager_Pro_v5.7.3_Update.zip) — choose the ZIP intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.3/CT_QA_Manager_Pro_v5.7.3_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.3/CT_QA_Manager_Pro_v5.7.3_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.3/SHA256SUMS.txt)

Checks are limited to the changed flows: a focused Chromium navigation check with synthetic API responses, a synthetic PowerShell 7 folder-opening check, syntax/build validation and package/upload integrity. Existing-folder reuse, first-time creation and linked-folder rejection are covered. No full native Windows suite, actual Explorer launch, hospital workstation or live scanner testing is claimed. Report receipt is separate from clinical QA approval. PDFs and their classifications are unchanged.
