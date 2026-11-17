Requested **Option A** Review layout:

- Larger PDF area with a collapsible file list; no repeated Current PDF panel.
- One filing bar below the PDF: **File as Daily/Monthly/Other**, **Choose another type**, and **Keep as Other** among the alternatives. Saved-file status and existing Undo/batch Undo remain available.
- **Details** holds the original filename, filing reason and existing report evidence; **Open in new tab** explains the original PDF action. **More options** retains Expand PDF and manual reading.
- Keep the existing 100% default, continuous scrolling, reader, preview limits/caches, filing payloads and save/recovery safeguards.

[Download Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.11/CT_QA_Manager_Pro_v5.7.11_Update.zip) — select the ZIP intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.11/CT_QA_Manager_Pro_v5.7.11_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.11/CT_QA_Manager_Pro_v5.7.11_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.11/SHA256SUMS.txt)

Scope is web UI layout and labels only; backend runtime changes are version labels. Stored reports, clinical evidence, scanner files, decisions and update rollback are unchanged. Google Drive is not included.

Validation uses one focused synthetic Chromium frontend flow with production web assets, generated preview images and simulated filing/Undo API results. It does not validate actual Windows PDF rendering, backend writes, hospital workstations or live scanners; no broad suite was run. Delivery checks source scope, JavaScript syntax, package integrity and uploaded release hashes.
