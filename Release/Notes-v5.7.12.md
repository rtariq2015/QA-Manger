One requested calendar control change:

**Receipt calendar** now uses clickable scanner tabs: **All scanners** plus each configured machine, such as CT Edge, CT Flash and MDP Building. The selected scanner is clearly marked with its existing accent color. Controls wrap on smaller screens and remain keyboard accessible.

Calendar dates, receipt calculations, month navigation, Daily/Monthly evidence distinctions and opening the selected day’s original reports are unchanged. The Review layout and 100% PDF default are retained.

[Download Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.12/CT_QA_Manager_Pro_v5.7.12_Update.zip) — select the ZIP intact in Settings → Program updates.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.12/CT_QA_Manager_Pro_v5.7.12_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.12/CT_QA_Manager_Pro_v5.7.12_Upgrade.zip) · [Checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.12/SHA256SUMS.txt)

Web UI only; other runtime changes are version labels. No new dependencies, processing, archive, cloud or clinical-evidence changes.

Validation uses the existing focused synthetic calendar/Monthly frontend flow with only its scanner-selection interaction updated for the new tabs. Original assertions are retained. It simulates local API data/actions and does not establish Windows rendering, backend writes, live-scanner behavior or hospital approval. No broad suite was run. Delivery checks source scope, JavaScript syntax, package integrity and uploaded release hashes.
