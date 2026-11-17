Monthly browsing speed fix only:

- Recently visited months reopen from a session cache instead of starting another Monthly backend request. The cache keeps up to 12 months, with a 4 MiB serialized metadata budget and five-minute freshness limit.
- Saved report, analysis, scanner/checklist and archive changes invalidate cached results. Failed, cancelled or outdated responses are not cached. Explicit report updates, restore and archive selection clear the cache.
- Scanner tabs reuse the same all-scanner month. Rapid arrow clicks wait 150 ms before loading an uncached month, avoiding intermediate requests.
- Keep the existing layout, automatic snapshot refresh, PDF handling, stored reports, filing and clinical-review evidence unchanged. No new runtime dependency.

Install through **Settings → Program updates** using the intact Update ZIP. Existing settings, reports and saved decisions are preserved by the existing updater and rollback handling.

The first visit to an uncached month still needs a backend load. Reloading or restarting the program clears this browser-memory cache; entries also reload when stale or after relevant saved data changes. This does not claim to detect every external filesystem change immediately.

Validation: one focused synthetic Chromium Monthly navigation/cache flow (75 assertions passed) and JavaScript syntax validation. Returning A → B → A and selecting a visited month made zero additional Monthly HTTP requests in this controlled fixture. Release packaging verifies source scope, ZIP integrity, every package file checksum and uploaded asset hashes. No broad suite, actual Windows/hospital workstation testing or live scanner/PDF processing was performed for this frontend-only change.
