Small calendar fix only:

- Days without a separate Daily PDF now show **Monthly PDF available** when an eligible Monthly PDF exists for that scanner and date.
- Clicking a calendar day shows its saved Daily and Monthly PDFs. The same selection carries through to Exports.
- Original PDFs stay in their existing folders. Nothing is copied or reclassified. Daily receipt totals and clinical review evidence are unchanged.

**[Update ZIP](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.2/CT_QA_Manager_Pro_v5.7.2_Update.zip)** — select it intact in Settings → Program updates. Keep your usual backup.

[New installation](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.2/CT_QA_Manager_Pro_v5.7.2_Portable.zip) · [Older-version upgrade](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.2/CT_QA_Manager_Pro_v5.7.2_Upgrade.zip) · [SHA-256 checksums](https://github.com/rtariq2015/QA-Manger/releases/download/v5.7.2/SHA256SUMS.txt)

Focused validation: nine calendar-rule scenarios and 31 Chromium assertions using synthetic API responses and the production frontend. The browser check covered the three Monthly-only dates, unchanged 27/30 Daily totals, same-day/scanner filtering, reference/pending exclusions and matching export selections, with no JavaScript errors or external assets. It does not claim real backend, scanner, PDF-content or exported-ZIP execution. No full native Windows test rerun was performed for this frontend change. The Windows host is rebuilt from unchanged application logic with only its version strings updated; bundled PDF-reader bytes are reused from their pinned artifact. Package integrity and uploaded hashes are checked during delivery.
