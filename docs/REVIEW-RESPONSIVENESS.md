# Responsive filing decisions — development follow-up

This follow-up is included in 5.7.1; the earlier 5.7.0 download does not include it. It changes the browser Review workflow and avoids redundant read-only snapshot work. It does not change source PDFs, clinical review, filing rules, saved schemas, archive locks, batch limits, reader timeouts or the host's 32-job bound. The Classic clinical-review workflow remains unchanged.

## Why one click takes time

The host already returns an asynchronous job number and serializes archive mutations. A filing worker validates the selected file and displayed stamp, saves the organization history atomically, refreshes that report's verified readable copy, and publishes a complete snapshot. Previously Review blocked all further filing until this entire job finished.

A generated 1,367-report development workload with all reports dated today confirmed that snapshot construction dominated. Each decision loaded saved analysis 4,103 times: one pass for report rows, one to build unused current-day legacy findings, one to count analysis, plus the selected-file checks. Selected readable-copy work took 21–245 ms in that workload; full snapshots took several seconds. These observations exclude host queue wait, worker startup and hospital network or workstation behavior. An action may also wait for an already-running PDF analysis to reach its existing safe boundary.

## Implemented behavior

- Capture each report ID, displayed stamp and selected type before submission. Sending, Queued and Saving remain progress states; an accepted HTTP request is not a completed filing decision.
- After acceptance, open the next report that has no submitted decision. Other distinct single-file decisions may queue while staff read, search or browse. A per-file guard prevents rapid duplicate submissions and same-file overlap.
- Keep the PDF the user is currently viewing when an earlier save finishes. Derive Undo from saved history, including when several jobs finish between polls.
- Keep Undo, grouped decisions and other archive mutations blocked until single-file saves are confirmed. Observe unknown jobs after reload conservatively; retain the existing host queue bound and an additional bound of 32 unconfirmed single-file decisions.
- Failed or cancelled decisions remain available for review. Successful decisions require a fresh saved snapshot; interrupted status checks cannot manufacture a saved result.
- Build snapshot analysis counts from the validated rows already used for that snapshot. Reuse the exact Daily schedule predicate and existing report rows for receipt, rather than reading unused legacy findings. The full Classic Today overview retains its findings.

## Executed development checks

[Analysis](../Tests/Review-Responsiveness/Analysis-Development.json): 22 scenarios / 184 assertions, all passed in Linux PowerShell 7.4.13. [Web adapter](../Tests/Review-Responsiveness/WebService-Development.json): 58 scenarios / 649 assertions, all passed. The new focused scenarios cover twelve valid/missing/stale/corrupt/error/upgrade/reference/shared-hash cases and explicit weekday, weekend, activation and exclusion cases. Every original regression remains in place.

The [actual before](../Tests/Review-Responsiveness/Decision-Before-1367.json), [actual after](../Tests/Review-Responsiveness/Decision-After-1367.json) and [comparison](../Tests/Review-Responsiveness/Decision-Comparison-1367.json) reports use 1,367 physical generated PDFs with populated per-record analysis caches. Four real public requests (Approve, Undo, Disapprove, Undo) ran per version, with derived organization/library state reset before each cohort. All source, managed PDF, analysis-cache and clinical-state hashes remained unchanged. Cache loads fell from **4,103 to 1,369 per request**, eliminating 2,734 duplicate reads.

Observed median request times were 21.59 and 14.06 seconds, but the first after-change request was slower than its baseline counterpart. Other development tests were active, and diagnostic wrappers add overhead. These individual observations are **not a controlled percentage speed claim** and do not promise workplace latency. The queue is the principal interaction improvement; saving is still serialized and can take time.

The [actual-host browser regression](../Tests/Review-Responsiveness/Browser-Development.json) passed **5 scenarios / 284 assertions**, with zero JavaScript errors or external asset requests. It checks delayed submission, two distinct queued decisions, duplicate prevention, browsing/focus, real reloads with the first jobs response held, stale rejection, cancellation, Undo, HTTP 503 snapshot recovery and protected bytes. Both filing buttons remained accessible at 1024×768 and 683×384 effective viewports with a real filing-progress indicator and a forced synthetic connection notice. Source fingerprints stayed unchanged throughout execution. Initial harness attempts were corrected to perform actual document reloads, settle asynchronous Undo before a new scenario, and complete intercepted routes safely; the final report comes from a complete fresh fixture run. Linux execution does not establish Windows PowerShell 5.1, actual Windows display scaling or hospital IT approval.

The final [validation record](TESTING.md) distinguishes the successful Windows Review/application checks, the failed startup-probe step, its corrected focused Linux check, and the full repeat cancelled at the user's direction. No complete native scheduler pass is claimed.
