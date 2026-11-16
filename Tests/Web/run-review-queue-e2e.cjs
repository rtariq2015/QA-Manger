/* Actual offline host/browser review-queue regression; synthetic PDFs only.
 * A bounded gate is installed only in the disposable fixture's copied adapter.
 * It delays the real decision before preflight; it does not fake a saved result.
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
if (!args.root || !args.host) throw Error('Supply --root for a NEW disposable fixture and --host for the built local host.');
const product = path.resolve(args['product-root'] || path.join(__dirname, '../..'));
const root = path.resolve(args.root);
const output = path.resolve(args['output-dir'] || path.join(root, 'review-queue-results'));
const powershell = args.powershell || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
if (fs.existsSync(root)) throw Error('Choose a NEW synthetic fixture folder; existing folders are never reused.');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase();
const readJSON = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const sourceFiles = ['App/Web/app.js', 'App/Web/app.css', 'App/Web/index.html', 'App/WebService.psm1', 'App/Insights.psm1', 'Host/Program.cs'];
const testedFiles = Object.fromEntries(sourceFiles.map(name => [name, sha(fs.readFileSync(path.join(product, name)))]));
const results = [], errors = [], external = [], submissions = [];
let host, browser, page, ready, originalService, baseline, observedVersion, assertions = 0, releasePost, releaseJobs;
const serviceFile = path.join(root, 'App/WebService.psm1');
const hold = path.join(root, 'test-review-hold');
const control = path.join(root, 'test-review-control.json');
const reached = path.join(root, 'test-review-reached.json');
const clean = value => String(value || '').replaceAll(ready?.token || '\u0000', '[redacted session]');
function check(value, message) { assertions++; if (!value) throw Error(message); }
async function until(fn, message, timeout = 120000) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { const value = await fn(); if (value) return value; } catch (error) { last = error; }
    await delay(100);
  }
  throw Error(message + (last ? ': ' + clean(last.message) : ''));
}
async function scenario(name, fn) {
  try { await fn(); results.push({ name, result: 'PASS' }); console.log('PASS ' + name); }
  catch (error) { results.push({ name, result: 'FAIL', details: clean(error.stack) }); console.log('FAIL ' + name + ': ' + clean(error.message)); throw error; }
}
function prepareFixture() {
  const created = spawnSync(powershell, ['-NoProfile', '-File', path.join(product, 'Tests/Web/New-WebFixture.ps1'), '-FixtureRoot', root, '-ProductRoot', product], { cwd: product, encoding: 'utf8', windowsHide: true, timeout: 180000 });
  if (created.status !== 0) throw Error('Synthetic fixture creation failed: ' + clean(created.stdout + created.stderr));
  const prep = path.join(root, 'prepare-review-fixture.ps1');
  fs.writeFileSync(prep, '\uFEFF' + [
    "param([string]$ProductRoot,[string]$FixtureRoot)",
    "Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'",
    "Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue",
    "$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProductRoot 'Tests/Run-Tests.ps1'),[ref]$t,[ref]$e)",
    "foreach($name in @('New-TestPdf','Add-Report')){$d=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($d.Extent.Text))}",
    "$cfg=Read-QaConfig $FixtureRoot;$cfg|Add-Member PdfReaderMode 'Standard' -Force;$cfg|Add-Member AutoAnalyze $false -Force;$cfg|Add-Member AutoUpdateOnOpen $false -Force;$cfg|Add-Member MonitorMinutes 0 -Force",
    "[void](Save-QaConfig $FixtureRoot $cfg)",
    "$date=(Get-Date).ToString('yyyy-MM-dd');for($i=0;$i -lt 8;$i++){[void](Add-Report $cfg 'CT_Edge' 'Unlabelled' $date ('10-'+$i.ToString('00')+'-00') (6500+$i))}",
    "[void](Invoke-QaOperation $cfg -Mode Update)",
    "Import-Module (Join-Path $FixtureRoot 'App/Insights.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue",
    "$read=Invoke-QaAnalysis $cfg -Limit 20 -UpgradeMeasurements -RefreshUnsupported;if($read.Failed -gt 0){throw 'The generated text PDFs must all be readable.'}",
    "$dashboard=Get-QaDashboard $cfg;$files=New-Object 'Collections.Generic.List[object]'",
    "foreach($record in $dashboard.Records){foreach($p in @([string]$record.SourcePath,[string]$record.DestinationPath)){[void]$files.Add([pscustomobject]@{Path=$p;Hash=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash})}}",
    "foreach($p in @(Get-ChildItem (Join-Path $cfg.ArchiveRoot '.ctqa/analysis') -Filter '*.json' -File)){[void]$files.Add([pscustomobject]@{Path=$p.FullName;Hash=(Get-FileHash -LiteralPath $p.FullName -Algorithm SHA256).Hash})}",
    "$state=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';[pscustomobject]@{Synthetic=$true;RecordCount=$dashboard.Records.Count;StatePath=$state;StateHash=(Get-FileHash -LiteralPath $state -Algorithm SHA256).Hash;Files=@($files.ToArray())}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $FixtureRoot 'review-queue-baseline.json') -Encoding UTF8"
  ].join('\r\n') + '\r\n', 'utf8');
  const prepared = spawnSync(powershell, ['-NoProfile', '-File', prep, '-ProductRoot', product, '-FixtureRoot', root], { cwd: root, encoding: 'utf8', windowsHide: true, timeout: 180000 });
  fs.rmSync(prep, { force: true });
  if (prepared.status !== 0) throw Error('Synthetic reading preparation failed: ' + clean(prepared.stdout + prepared.stderr));
  baseline = readJSON(path.join(root, 'review-queue-baseline.json'));
  if (!baseline.Synthetic || baseline.RecordCount !== 14) throw Error('The focused workload requires fourteen generated PDFs.');
  fs.mkdirSync(output, { recursive: true });
  originalService = fs.readFileSync(serviceFile);
  const source = originalService.toString('utf8');
  const start = source.indexOf('function Invoke-QaWebOrganization {');
  const end = source.indexOf('function New-QaWebArtifactPath', start);
  const anchor = '    if((Test-QaWebHasProperty $Request selections)';
  const insertion = source.indexOf(anchor, start);
  if (start < 0 || end < 0 || insertion < start || insertion > end) throw Error('The copied adapter decision hook could not be found.');
  const gate = [
    "    # Synthetic-test-only gate. Production source is never modified.",
    "    $testControl=Join-Path $PSScriptRoot '../test-review-control.json';$testHold=Join-Path $PSScriptRoot '../test-review-hold'",
    "    if([IO.File]::Exists($testControl) -and [IO.File]::Exists($testHold)){",
    "        $testSelected=[IO.File]::ReadAllText($testControl)|ConvertFrom-Json",
    "        if([string](Get-QaWebValue $Request id '') -ceq [string]$testSelected.id){",
    "            [IO.File]::WriteAllText((Join-Path $PSScriptRoot '../test-review-reached.json'),([pscustomobject]@{id=[string]$testSelected.id;action=[string]$Request.action}|ConvertTo-Json -Compress))",
    "            $testClock=[Diagnostics.Stopwatch]::StartNew()",
    "            while([IO.File]::Exists($testHold) -and -not (Test-QaWebCancelled $Progress)){if($testClock.Elapsed.TotalSeconds -gt 100){throw 'Synthetic decision gate deadline exceeded.'};Start-Sleep -Milliseconds 50}",
    "        }",
    "    }", ''
  ].join('\r\n');
  fs.writeFileSync(serviceFile, source.slice(0, insertion) + gate + source.slice(insertion), 'utf8');
}
async function api(route, options = {}) { return fetch(new URL(route, ready.url), { ...options, headers: { 'X-Qa-Session': ready.token, ...options.headers } }); }
async function snapshot() { const response = await api('/api/snapshot'); const value = await response.json(); if (!response.ok) throw Error('Snapshot ' + response.status + ': ' + clean(value.error)); return value; }
async function jobs() { return (await (await api('/api/jobs')).json()).jobs; }
async function jobWith(id, predicate) { return until(async () => { const job = (await jobs()).find(row => row.id === id); return job && predicate(job) && job; }, 'The requested decision job did not reach its expected state.'); }
async function navigate(name) { await page.locator('.main-nav button[data-page="' + name + '"]').click(); if (name === 'reports') await page.locator('#reports-library-view').click(); }
async function reload() {
  await page.goto(ready.url + '#session=' + encodeURIComponent(ready.token), { waitUntil: 'domcontentloaded' });
  // Navigating only to the session fragment can be same-document navigation.
  // A true reload must discard the in-memory submitted-job ownership map.
  await page.evaluate(() => { window.__ctqaReviewReloadProbe = true; });
  await page.reload({ waitUntil: 'domcontentloaded' });
  check(await page.evaluate(() => window.__ctqaReviewReloadProbe === undefined), 'Reload creates a new document and clears in-memory job ownership');
  await page.locator('#refresh-button').waitFor({ state: 'visible' });
  await until(async () => (await page.locator('#report-total').innerText()).replaceAll(',', '') === String(baseline.RecordCount), 'The real saved snapshot did not appear.');
}
async function reviewIdentity(id) {
  await until(async () => await page.locator('#pdf-area').getAttribute('data-record-id') === id && await page.locator('#review-action-file').getAttribute('data-record-id') === id, 'The decision rail and PDF no longer identify the same selected file.');
  await until(async () => {
    if (await page.locator('#pdf-image').isVisible()) return await page.locator('#pdf-image').evaluate(image => image.complete && image.naturalWidth > 0);
    return await page.locator('#pdf-frame').isVisible() && (await page.locator('#pdf-frame').getAttribute('src') || '').includes('/api/pdf/' + id);
  }, 'The selected PDF did not finish loading.');
}
async function openRecord(id) {
  const value = await snapshot(), record = value.records.find(row => row.id === id);
  if (!record) throw Error('The synthetic target record is absent.');
  await navigate('reports'); await page.locator('#clear-filters').click(); await page.locator('#report-search').fill(record.filename);
  await until(async () => await page.locator('.report-item[data-record-id="' + id + '"]').count() === 1, 'The exact report search did not find its target.');
  await page.locator('.report-item[data-record-id="' + id + '"]').click(); await reviewIdentity(id);
}
async function chooseType(category = 'Monthly') { if (await page.locator('#review-target-type').isVisible()) await page.locator('#review-target-type').selectOption(category); }
function setBarrier(id) { fs.rmSync(reached, { force: true }); fs.writeFileSync(control, JSON.stringify({ id })); fs.writeFileSync(hold, 'bounded synthetic decision gate'); }
function releaseBarrier() { fs.rmSync(hold, { force: true }); }
async function barrierReached(id) { await until(() => fs.existsSync(reached) && readJSON(reached).id === id, 'The actual copied adapter did not enter its preflight gate.'); }
function preserveProtected() {
  check(sha(fs.readFileSync(baseline.StatePath)) === baseline.StateHash, 'Filing leaves the complete authoritative clinical state and review history byte-for-byte unchanged');
  for (const file of baseline.Files) check(sha(fs.readFileSync(file.Path)) === file.Hash, 'Filing never changes scanner originals, archived PDF bytes or saved analysis bytes');
}
function organization() { const file = path.join(root, 'Data/.ctqa/organization.json'); return fs.existsSync(file) ? readJSON(file) : { Records: [], History: [] }; }
async function captureSubmission(action, from, recordId) { return until(() => submissions.slice(from).find(row => row.request.action === action && row.request.id === recordId), 'The accepted filing request did not capture the intended PDF.'); }
async function terminal(id, expected = 'completed') { const job = await jobWith(id, row => ['completed', 'failed', 'cancelled'].includes(row.status)); check(job.status === expected, 'The captured filing job reaches its expected ' + expected + ' state'); return job; }
async function savedStatusSettled() { await until(async () => await page.locator('#review-save-status').isHidden(), 'The saving indicator did not settle after terminal jobs and a successful snapshot.'); }
async function pendingGeometry() {
  const saved = await page.locator('#connection-banner').evaluate(banner => ({ hidden: banner.hidden, text: banner.textContent, className: banner.className }));
  try {
    await page.locator('#connection-banner').evaluate(banner => { banner.hidden = false; banner.className = 'banner warning'; banner.textContent = 'Synthetic layout check: one scanner connection needs attention. Saved reports remain available.'; });
    check(await page.locator('#job-progress').isVisible(), 'The pending layout includes actual foreground filing progress');
    for (const viewport of [{ width: 1024, height: 768 }, { width: 683, height: 384 }]) {
      await page.setViewportSize(viewport);
      await delay(100);
      check(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1), 'Pending review has no horizontal document overflow at ' + viewport.width + '×' + viewport.height);
      for (const id of ['approve-button', 'disapprove-button']) {
        const button = page.locator('#' + id);
        await button.scrollIntoViewIfNeeded();
        const rect = await button.boundingBox();
        check(!!rect && rect.width > 40 && rect.height > 20 && rect.x >= -1 && rect.x + rect.width <= viewport.width + 1 && rect.y >= -1 && rect.y + rect.height <= viewport.height + 1, 'The pending ' + id + ' remains accessible at ' + viewport.width + '×' + viewport.height);
      }
      await page.screenshot({ path: path.join(output, 'review-saving-' + viewport.width + 'x' + viewport.height + '.png'), fullPage: true });
    }
  } finally {
    await page.setViewportSize({ width: 1366, height: 900 });
    await page.locator('#connection-banner').evaluate((banner, value) => { banner.hidden = value.hidden; banner.textContent = value.text; banner.className = value.className; }, saved);
  }
}
async function startHost() {
  const parameters = ['--root', root, '--powershell', powershell, '--no-browser'];
  host = spawn(args.dotnet || args.host, args.dotnet ? [args.host, ...parameters] : parameters, { cwd: root, stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
  let stderr = ''; host.stderr.on('data', bytes => stderr = (stderr + bytes.toString()).slice(-3000));
  await until(() => { if (host.exitCode !== null) throw Error('Host exited ' + host.exitCode + ': ' + clean(stderr)); const file = path.join(root, 'Data/web-ready.json'); if (!fs.existsSync(file)) return false; const value = readJSON(file); return value.pid === host.pid && (ready = value); }, 'The actual offline host did not become ready.');
  await until(async () => (await snapshot()).records?.length === baseline.RecordCount, 'The actual adapter did not load all generated reports.');
}
async function stopHost() {
  if (!host) return; const running = host;
  await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"Shutdown"}' });
  await until(() => running.exitCode !== null, 'Host shutdown timed out.', 15000); host = null;
}
(async () => {
  try {
    prepareFixture(); await startHost();
    const launch = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (args['browser-channel']) launch.channel = args['browser-channel']; else if (args.chromium) launch.executablePath = args.chromium;
    browser = await chromium.launch(launch); const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) { external.push(url.hostname); route.abort(); } else route.continue(); });
    page = await context.newPage(); page.on('pageerror', error => errors.push(clean(error.message)));
    page.on('response', async response => {
      if (new URL(response.url()).pathname !== '/api/actions' || response.status() !== 202) return;
      const request = response.request().postDataJSON(); if (!['Approve', 'Disapprove', 'Undo'].includes(request?.action)) return;
      try { submissions.push({ request, accepted: await response.json() }); } catch (error) { errors.push(clean(error.message)); }
    });
    await reload();
    const firstSnapshot = await snapshot(); observedVersion = firstSnapshot.version;
    let candidates = firstSnapshot.records.filter(row => row.filingState === 'NeedsReview' && row.filename.startsWith('Unlabelled'));
    check(candidates.length >= 8, 'Fresh real analysis exposes enough independent unsupported-layout filing exceptions');
    const [a, b, c, d, e, f, g, h] = candidates;
    await scenario('A delayed submit cannot duplicate a decision or claim it is saved; distinct decisions queue without interrupting browsing', async () => {
      await openRecord(a.id); setBarrier(a.id);
      let attempted = 0; const postGate = new Promise(resolve => releasePost = resolve);
      await page.route('**/api/actions', async route => { const request = route.request().postDataJSON(); if (request?.action === 'Disapprove' && request.id === a.id) { attempted++; await postGate; } await route.continue(); });
      const from = submissions.length;
      await page.locator('#disapprove-button').evaluate(button => { button.dispatchEvent(new MouseEvent('click', { bubbles: true })); button.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
      await until(() => attempted === 1, 'The delayed submission was not intercepted.');
      check(await page.locator('#disapprove-button').isDisabled(), 'The per-record guard disables duplicate filing before POST returns');
      check(await page.locator('#review-save-status').isVisible(), 'A saving state is visible while POST is still awaiting acceptance');
      check((await snapshot()).records.find(row => row.id === a.id).pending, 'A pending POST does not turn the snapshot into a saved classification');
      check(!organization().History.some(row => row.recordId === a.id), 'No durable decision is fabricated before the server accepts it');
      await delay(200); check(attempted === 1, 'Two immediate clicks emit only one captured filing POST');
      releasePost(); releasePost = null; const first = await captureSubmission('Disapprove', from, a.id); await barrierReached(a.id);
      await until(async () => await page.locator('#pdf-area').getAttribute('data-record-id') !== a.id, 'The next unscheduled PDF was not shown after queue acceptance.');
      check((await snapshot()).records.find(row => row.id === a.id).pending, 'An accepted but held worker remains truthfully pending');
      await page.unroute('**/api/actions'); await openRecord(b.id); await chooseType('Monthly');
      check(await page.locator('#approve-button').isEnabled(), 'A distinct PDF can be filed while the earlier owned decision is saving');
      await pendingGeometry();
      await page.locator('#approve-button').click(); const second = await captureSubmission('Approve', from, b.id);
      const waiting = await jobWith(second.accepted.id, row => row.status === 'queued');
      check(waiting.action === 'Approve', 'The second captured decision waits in the existing serialized mutation queue');
      check(second.request.category === 'Monthly' && second.request.stamp === b.stamp, 'The queue retains the exact chosen Monthly category and captured PDF stamp');
      check((await page.locator('#review-save-title').innerText()).includes('2'), 'The interface distinguishes both still-saving decisions');
      check(await page.locator('#undo-button').isDisabled() && await page.locator('#refresh-button').isDisabled(), 'Undo and conflicting mutations remain blocked while filing work is pending');
      await openRecord(c.id); await navigate('reports'); await page.locator('#report-search').fill(c.filename); await page.locator('#report-search').focus();
      check(await page.locator('#report-search').isEnabled(), 'Saved report search remains usable during the held write');
      await page.screenshot({ path: path.join(output, 'review-queued-browsing.png'), fullPage: true });
      releaseBarrier(); await terminal(first.accepted.id); await terminal(second.accepted.id); await savedStatusSettled();
      const value = await snapshot(), ar = value.records.find(row => row.id === a.id), br = value.records.find(row => row.id === b.id);
      check(ar.decision === 'Disapproved' && ar.category === 'Other' && !ar.pending, 'Disapprove durably files the intended first PDF as Other');
      check(br.decision === 'Approved' && br.category === 'Monthly' && !br.pending, 'The distinct second PDF retains its captured Monthly filing decision');
      check(await page.locator('.main-nav button[data-page="reports"]').getAttribute('aria-current') === 'page', 'Later job completion does not force the user away from Reports');
      check(await page.locator('#pdf-area').getAttribute('data-record-id') === c.id, 'Later job completion does not replace a different selected PDF');
      check(await page.locator('#report-search').evaluate(input => document.activeElement === input), 'Background decision completion preserves the active search input');
      preserveProtected();
    });
    await scenario('Reload discovers unknown in-flight work and blocks duplicate filing until the durable result is available', async () => {
      await openRecord(c.id); setBarrier(c.id); const from = submissions.length;
      await page.locator('#disapprove-button').click(); const saving = await captureSubmission('Disapprove', from, c.id); await barrierReached(c.id);
      let generation = 0, jobsHeld = false, jobsContinued = false;
      const generations = new WeakMap();
      const observeRequest = request => {
        if (request.isNavigationRequest() && request.frame() === page.mainFrame()) generation++;
        generations.set(request, generation);
      };
      page.on('request', observeRequest);
      const jobsGate = new Promise(resolve => releaseJobs = resolve);
      await page.route('**/api/jobs', async route => {
        const requestGeneration = generations.get(route.request()) || 0;
        if (!jobsHeld && requestGeneration > 0) {
          jobsHeld = true; await jobsGate;
          await route.continue(); jobsContinued = true;
        } else {
          try { await route.continue(); }
          catch (error) { if (requestGeneration > 0 || !/already handled|cancelled|aborted|closed/i.test(error.message)) throw error; }
        }
      });
      await reload(); await until(() => jobsHeld, 'The first fresh-document job check was not held.'); await openRecord(d.id);
      check((await jobWith(saving.accepted.id, row => row.status === 'running')).status === 'running', 'The server still has actual unfinished work before the reloaded browser receives its first job list');
      check(await page.locator('#approve-button').isDisabled() && await page.locator('#disapprove-button').isDisabled(), 'Filing remains blocked until the fresh document has observed outstanding jobs');
      releaseJobs(); releaseJobs = null; await until(() => jobsContinued, 'The fresh-document job list was not released.'); await page.unroute('**/api/jobs'); page.removeListener('request', observeRequest);
      check((await jobWith(saving.accepted.id, row => row.status === 'running')).status === 'running', 'The pre-reload worker remains active during the fresh-document ownership check');
      await until(async () => await page.locator('#review-save-status').isVisible() && await page.locator('#approve-button').isDisabled() && await page.locator('#disapprove-button').isDisabled(), 'A reloaded page did not guard an existing filing job it did not submit.');
      check(/another session/i.test(await page.locator('#review-save-title').innerText()), 'The reloaded interface explicitly identifies unfinished decisions from another session');
      check((await snapshot()).records.find(row => row.id === c.id).pending, 'Reload does not pretend that an unfinished worker has saved its decision');
      await navigate('reports'); await page.locator('#report-search').fill(d.filename); check(await page.locator('#report-search').isEnabled(), 'Reloaded unknown work still permits saved report browsing');
      releaseBarrier(); await terminal(saving.accepted.id); await savedStatusSettled();
      check((await snapshot()).records.find(row => row.id === c.id).category === 'Other', 'The pre-reload captured decision is durably retained');
      check((await snapshot()).records.find(row => row.id === d.id).filingState === 'NeedsReview', 'The untouched next PDF remains a genuine filing exception after the previous save');
      await openRecord(d.id);
      await until(() => page.locator('#disapprove-button').isEnabled(), 'Filing did not become usable after the rediscovered job finished.', 10000);
      check(true, 'Filing becomes usable after the rediscovered job finishes');
      preserveProtected();
    });
    await scenario('A stale captured filing stamp rejects the queued decision, clears Saving, and remains available for explicit retry', async () => {
      await openRecord(d.id); await chooseType('Daily'); setBarrier(d.id); const from = submissions.length;
      const organizationFile = path.join(root, 'Data/.ctqa/organization.json'), original = fs.readFileSync(organizationFile);
      const core = readJSON(baseline.StatePath).Records.find(row => row.Id === d.id);
      try {
        await page.locator('#approve-button').click(); const failing = await captureSubmission('Approve', from, d.id); await barrierReached(d.id);
        await openRecord(e.id);
        // Model an external, valid organization revision after the captured UI
        // stamp, while the actual worker is still before its fresh preflight.
        const changed = organization();
        changed.Records = changed.Records.filter(row => row.id !== d.id);
        changed.Records.push({ id: d.id, hash: core.Hash, revision: crypto.randomBytes(16).toString('hex'), decision: '', category: '', time: new Date().toISOString(), actor: 'Synthetic test actor', actorKind: 'Synthetic stale-state test only' });
        fs.writeFileSync(organizationFile, JSON.stringify(changed));
        releaseBarrier(); const rejected = await terminal(failing.accepted.id, 'failed');
        check(/changed after it was displayed/i.test(rejected.error || ''), 'The real adapter rejects the captured stale filing stamp');
        fs.writeFileSync(organizationFile, original);
        await savedStatusSettled(); check(await page.locator('#error-banner').isVisible(), 'A failed save is visible instead of being silently treated as approval');
        const value = await snapshot(), row = value.records.find(record => record.id === d.id);
        check(row.pending && row.filingState === 'NeedsReview', 'Rejected work remains an unresolved review exception');
        check(!organization().History.some(history => history.recordId === d.id), 'Failed preflight does not append a false saved decision');
        check(await page.locator('#pdf-area').getAttribute('data-record-id') === e.id, 'A failed earlier decision does not steal the different current PDF');
        await openRecord(d.id); check(await page.locator('#disapprove-button').isEnabled(), 'The rejected PDF can be explicitly retried after the failure is shown');
      } finally { fs.writeFileSync(organizationFile, original); releaseBarrier(); }
      preserveProtected();
    });
    await scenario('Queued cancellation remains pending and a completed filing retains real Undo', async () => {
      await openRecord(e.id); setBarrier(e.id); const from = submissions.length;
      await page.locator('#disapprove-button').click(); const first = await captureSubmission('Disapprove', from, e.id); await barrierReached(e.id);
      await openRecord(f.id); await chooseType('Daily'); await page.locator('#approve-button').click(); const second = await captureSubmission('Approve', from, f.id);
      await jobWith(second.accepted.id, row => row.status === 'queued');
      const cancelled = await api('/api/jobs/' + encodeURIComponent(second.accepted.id) + '/cancel', { method: 'POST' }); check(cancelled.ok, 'The existing job API accepts cancellation while the second decision is still queued');
      await terminal(second.accepted.id, 'cancelled'); await openRecord(g.id); releaseBarrier(); await terminal(first.accepted.id); await savedStatusSettled();
      const value = await snapshot(); check(value.records.find(row => row.id === f.id).pending, 'A cancelled queued decision remains pending and is not shown as saved');
      check(!organization().History.some(history => history.recordId === f.id), 'Cancellation before its mutation slot creates no false approval history');
      await navigate('review'); check(await page.locator('#undo-button').isEnabled(), 'Undo becomes available only after durable completion and queue settlement');
      const undoFrom = submissions.length; await page.locator('#undo-button').click(); const undone = await captureSubmission('Undo', undoFrom, e.id); await terminal(undone.accepted.id); await savedStatusSettled();
      await until(async () => (await snapshot()).records.find(row => row.id === e.id).pending, 'Real Undo did not restore the prior pending filing state.');
      await reviewIdentity(e.id);
      await until(() => page.locator('#refresh-button').isEnabled(), 'The browser did not finish applying the completed Undo.');
      const history = organization().History.filter(row => row.recordId === e.id); check(history.length === 2 && history[0].action === 'Disapprove' && history[1].action === 'Undo', 'Undo retains append-only saved filing history');
      preserveProtected(); await page.screenshot({ path: path.join(output, 'review-queue-settled.png'), fullPage: true });
    });
    await scenario('A committed decision stays guarded during a failed snapshot read and confirms only after recovery', async () => {
      await openRecord(h.id); const from = submissions.length; let rejectSnapshot = true, rejectedReads = 0, savingId;
      await page.route('**/api/snapshot', async route => {
        const complete = savingId && (await jobs()).some(job => job.id === savingId && job.status === 'completed');
        if (rejectSnapshot && complete) { rejectedReads++; await route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Synthetic temporary snapshot read failure' }) }); }
        else await route.continue();
      });
      try {
        await page.locator('#disapprove-button').click(); const saving = await captureSubmission('Disapprove', from, h.id); savingId = saving.accepted.id;
        await terminal(savingId);
        await until(() => rejectedReads > 0, 'The browser did not attempt the deliberately failed post-save snapshot read.');
        check((await snapshot()).records.find(row => row.id === h.id).category === 'Other', 'The actual server has durably saved the file while only its browser snapshot response is unavailable');
        check(await page.locator('#review-save-status').isVisible(), 'An unavailable confirmation snapshot does not clear the saving indicator');
        check(await page.locator('#undo-button').isDisabled() && await page.locator('#refresh-button').isDisabled(), 'Conflicting mutations remain guarded until a successful fresh overview confirms the save');
        await openRecord(h.id);
        check(await page.locator('#disapprove-button').isDisabled(), 'The already submitted PDF cannot be filed a second time during snapshot recovery');
        check(/not yet confirmed/i.test(await page.locator('#preview-filing-note').innerText()), 'The pending overlay explicitly distinguishes the requested filing from confirmed screen state');
        rejectSnapshot = false;
        await savedStatusSettled(); await openRecord(h.id);
        await until(async () => (await page.locator('#review-completed-label').innerText()).includes('Other'), 'The recovered snapshot did not display the actual saved Other classification.');
        check(await page.locator('#undo-button').isEnabled(), 'Real Undo becomes available after confirmed snapshot recovery');
        preserveProtected();
      } finally { rejectSnapshot = false; await page.unroute('**/api/snapshot'); }
    });
    check(errors.length === 0, 'The actual browser workload has no uncaught JavaScript errors'); check(external.length === 0, 'The workload fetches no external runtime assets');
    for (const [name, expected] of Object.entries(testedFiles)) check(sha(fs.readFileSync(path.join(product, name))) === expected, 'Production source remains unchanged during the focused execution: ' + name);
  } catch (error) {
    if (page && ready) {
      try {
        fs.mkdirSync(output, { recursive: true });
        await page.screenshot({ path: path.join(output, 'review-queue-failure.png'), fullPage: true });
        const dom = await page.evaluate(() => ({ selectedId: document.getElementById('pdf-area')?.dataset.recordId, title: document.getElementById('preview-title')?.textContent, saving: { hidden: document.getElementById('review-save-status')?.hidden, title: document.getElementById('review-save-title')?.textContent }, buttons: ['approve-button','disapprove-button','undo-button'].map(id => ({ id, disabled: document.getElementById(id)?.disabled, hidden: document.getElementById(id)?.hidden })), previewMode: document.getElementById('pdf-frame')?.hidden ? 'native' : 'browser' }));
        fs.writeFileSync(path.join(output, 'review-queue-failure-state.json'), JSON.stringify({ dom, jobs: await jobs(), snapshot: await snapshot() }, null, 2));
      } catch {}
    }
    if (!results.some(row => row.result === 'FAIL')) results.push({ name: 'Fixture or runtime setup', result: 'FAIL', details: clean(error.stack) });
    console.error(clean(error.stack)); process.exitCode = 1;
  } finally {
    if (releasePost) releasePost(); if (releaseJobs) releaseJobs(); releaseBarrier();
    if (page) { try { await page.unroute('**/api/actions'); await page.unroute('**/api/jobs'); await page.unroute('**/api/snapshot'); } catch {} }
    if (browser) await browser.close();
    if (host) { try { await stopHost(); } catch { host.kill(); } }
    if (originalService) fs.writeFileSync(serviceFile, originalService);
    fs.mkdirSync(output, { recursive: true });
    const summary = { version: String(observedVersion || 'Unknown'), syntheticOnly: true, platform: process.platform, browserChannel: args['browser-channel'] || 'chromium', actualBrowser: true, actualHost: true, tests: results.length, assertions, failed: results.filter(row => row.result === 'FAIL').length, results, externalAssetRequests: external.length, javascriptErrors: errors, testedFiles, hostSHA256: fs.existsSync(args.host) ? sha(fs.readFileSync(args.host)) : '', scope: 'Actual local host, PowerShell adapter and generated PDFs. A bounded gate is inserted only in the copied fixture before durable preflight, with a separate delayed POST. Checks queued distinct filing, duplicate prevention, truthful saving state, browsing, true reload with the first job-list response held, stale failure, cancellation, Undo, snapshot-read failure/recovery and protected source/clinical/cache bytes. Includes 1024×768 and 683×384 effective-viewport geometry with actual filing progress and a forced synthetic connection notice; this is not actual Windows DPI testing. Does not measure hospital workstation speed or establish Windows execution when run on Linux.' };
    fs.writeFileSync(path.join(output, 'review-queue-summary.json'), JSON.stringify(summary, null, 2) + '\n');
    console.log(JSON.stringify({ tests: summary.tests, assertions, failed: summary.failed }));
  }
})();
