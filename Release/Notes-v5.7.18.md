Startup recovery and scanner-access fix only:

- Keep checking the cached host snapshot while the saved local library loads, instead of giving up after approximately 30 seconds. Use the existing polling loop with coalesced requests and backoff capped at five seconds; keep heartbeat and job polling active.
- Show ordinary startup loading as an informational status. Clear only the library-owned notice when reports arrive, including recovery without a job event. Preserve unrelated errors; actual startup or session failures retain error guidance.
- During report updates, freshly verify existing scanner-folder read/list access before attempting another native sign-in. Explicit sign-in still tests supplied credentials, and failed access retains the existing authentication path. Preserve isolated execution, the 30-second reconnect timeout, credential protection and drive-mapping protections.
- Keep existing caches, saved reports, filing/review decisions, source-file checks and portable/offline operation unchanged. No new runtime dependency, persistent startup snapshot or security-policy change.

Install the intact Update ZIP through **Settings → Program updates**. The existing updater preserves settings, archives, decisions and previous-program rollback backups.

Executed verification: **51 synthetic Chromium startup assertions** and **19 Linux PowerShell 7.4.13 module-mock/parser assertions** passed. Fingerprints match the delivered source. Packaging checks JavaScript syntax, the limited source scope, ZIP CRC, package manifests and uploaded asset hashes.

These checks did not execute Windows PowerShell 5.1, Windows SMB/DPAPI, live scanners or a hospital workstation. Cold startup still validates saved metadata and analysis; this change does not make a failed host initialization succeed or remove actual network/server latency. Automatic browser retries read host memory, without repeatedly launching startup workers or scanner scans. A genuine host startup failure may still require correcting permissions/policy and restarting.
