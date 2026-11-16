Requested Monthly, Today and PDF-viewing changes only:

- Monthly received status now uses the same green circled check as Daily.
- One prominent **View all N Monthly PDFs** button replaces Open latest PDF and the duplicate View all link. Singular and empty states are handled separately.
- Today removes the redundant Daily library/history links. PDF-reading details live inside Archive activity. Today's date, Open report folders and the current Monthly archive label are more prominent.
- Saved reports open in a wider **PDF viewer** mode, with the filing rail hidden. Pending reports have a **Review filing** button; the Review sidebar still opens filing controls. Viewing mode blocks the filing decision actions.
- **Fit page** is the default for native page previews, including resize refitting. Fit width, 100% and 150% remain available. Browser PDF views request full-page fit. Continuous scrolling, existing page loading/cache limits and source-page navigation are retained.

[Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.6/CT_QA_Manager_Pro_v5.7.6_Update.zip) — select it intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.6/CT_QA_Manager_Pro_v5.7.6_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.6/CT_QA_Manager_Pro_v5.7.6_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.6/SHA256SUMS.txt)

Validation was limited to one synthetic frontend control flow, syntax/build checks and package/upload integrity. The browser flow checked Monthly counts/list targeting and circle style, Today cleanup, native full-page geometry and resize, Fit width, and transitions between viewing and pending filing review, with no browser errors, external assets or mutation requests. Native preview responses were generated test PNGs, not extracted clinical PDFs. No full native Windows suite, actual Windows PDF rendering, hospital workstation or live-scanner execution is claimed for this frontend change. Backend logic, stored reports and clinical evidence are unchanged; the host version is updated and the pinned bundled PDF reader is reused.
