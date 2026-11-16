/* Development-only browser regression. Uses real local host, backend and synthetic PDFs. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { chromium } = require('playwright');
const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const root = path.resolve(args.root || process.env.CTQA_WEB_ROOT || '');
const output = path.resolve(args['output-dir'] || path.join(root, 'web-test-results'));
const readyFile = args['token-file'] || path.join(root, 'Data', 'web-ready.json');
const baseline = JSON.parse(fs.readFileSync(path.join(root, 'fixture-baseline.json'), 'utf8').replace(/^\uFEFF/, ''));
if (!baseline.Synthetic) throw new Error('Browser testing requires an explicitly synthetic fixture.');
fs.mkdirSync(output, { recursive: true });
let ready, child, browser, page, context;
let assertions = 0;
let nativePreviewActuallyRun = false;
let browserBacklogSubmissions=0;
const insightFile=path.join(root,'App/Insights.psm1'),originalInsights=fs.readFileSync(insightFile);
const analyzeHold=path.join(root,'test-analyze-hold'),analyzeReached=path.join(root,'test-analyze-reached');
function analysisBarrier(){
  const source=originalInsights.toString('utf8'),needle='            $readerClock=[Diagnostics.Stopwatch]::StartNew()';
  if(source.split(needle).length!==2)throw Error('Expected exactly one common synthetic analysis checkpoint.');
  const checkpoint="            if($null -ne $Progress -and [IO.File]::Exists((Join-Path $Config.AppRoot 'test-analyze-hold')) -and -not [IO.File]::Exists((Join-Path $Config.AppRoot 'test-analyze-reached'))){[IO.File]::WriteAllText((Join-Path $Config.AppRoot 'test-analyze-reached'),'synthetic checkpoint');while([IO.File]::Exists((Join-Path $Config.AppRoot 'test-analyze-hold')) -and -not [bool]$Progress.Cancel){Start-Sleep -Milliseconds 50}}\n";
  fs.writeFileSync(insightFile,source.replace(needle,checkpoint+needle));
}
function holdAnalysis(){fs.rmSync(analyzeReached,{force:true});fs.writeFileSync(analyzeHold,'synthetic fixture only');}
function releaseAnalysis(){fs.rmSync(analyzeHold,{force:true});}
const results = [], errors = [], externalRequests = [], dialogs = [], previewRequests = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase();
const clean = message => String(message || '').replaceAll(ready?.token || '\u0000', '[redacted session]');
function check(condition, message) { assertions++; if (!condition) throw new Error(message); }
async function until(fn, message, timeout = 60000) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { const value = await fn(); if (value) return value; } catch (error) { if (error.fatal) throw error; last = error; }
    await delay(150);
  }
  throw new Error(message + (last ? ': ' + clean(last.message) : ''));
}
async function api(route, options = {}, authenticated = true) {
  const headers = { ...(authenticated ? { 'X-Qa-Session': ready.token } : {}), ...options.headers };
  return fetch(new URL(route, ready.url), { ...options, headers });
}
async function snapshot() {
  const response = await api('/api/snapshot');
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const detail = typeof payload.error === 'string' ? payload.error : payload.error?.message || payload.message || response.statusText;
    throw new Error('Snapshot HTTP ' + response.status + ': ' + clean(String(detail || 'No error description was returned.').slice(0, 1600)));
  }
  return response.json();
}
async function waitSnapshot(predicate = () => true) { return until(async () => { const value = await snapshot(); return value && predicate(value) && value; }, 'The saved snapshot did not reach the expected state.'); }
async function jobs() { const response = await api('/api/jobs'); const value = await response.json(); return value.jobs || value; }
async function action(request, expected = 'completed') {
  const response = await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request) });
  check(response.status === 202, request.action + ' was accepted as a background job');
  const accepted = await response.json();
  const job = await until(async () => (await jobs()).find(j => j.id === accepted.id && ['completed', 'failed', 'cancelled'].includes(String(j.status).toLowerCase())), request.action + ' did not finish.', 180000);
  check(String(job.status).toLowerCase() === expected, request.action + ' status was ' + job.status + (job.error ? ': ' + clean(typeof job.error === 'string' ? job.error : JSON.stringify(job.error)) : ''));
  return job;
}
async function startHost() {
  if (args.host) {
    const parameters = ['--root', root, '--powershell', args.powershell || '/tmp/ctqa-pwsh', '--no-browser'];
    const command = args.dotnet || args.host;
    child = spawn(command, args.dotnet ? [args.host, ...parameters] : parameters, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let startupError = '';
    child.stdout.on('data', () => {}); child.stderr.on('data', bytes => { startupError = (startupError + bytes.toString()).slice(-3000); });
    await until(() => {
      if (child.exitCode !== null || child.signalCode !== null) { const error = new Error('Host exited: ' + (child.exitCode ?? child.signalCode) + '. ' + clean(startupError)); error.fatal = true; throw error; }
      if (!fs.existsSync(readyFile)) return null;
      const value = JSON.parse(fs.readFileSync(readyFile, 'utf8').replace(/^\uFEFF/, ''));
      return value.pid === child.pid && (ready = value);
    }, 'The local host did not become ready.');
  } else {
    ready = JSON.parse(fs.readFileSync(readyFile, 'utf8').replace(/^\uFEFF/, ''));
    if (args.url) ready.url = args.url;
  }
  await waitSnapshot(value => Array.isArray(value.records) && value.records.length === baseline.RecordCount);
}
async function stopHost() {
  if (!child) return;
  const processHandle = child;
  try { await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'Shutdown' }) }); } catch {}
  const deadline = Date.now() + 15000;
  while (processHandle.exitCode === null && processHandle.signalCode === null && Date.now() < deadline) await delay(100);
  if (processHandle.exitCode === null && processHandle.signalCode === null) processHandle.kill();
  child = null;
}
async function loadBrowserPage() {
  if (page) await page.close();
  page = await context.newPage();
  page.on('pageerror', error => errors.push(clean(error.message)));
  page.on('request', request => { const pathname = new URL(request.url()).pathname; if (pathname.startsWith('/api/preview/')) previewRequests.push(pathname);if(pathname==='/api/actions'&&request.method()==='POST'){try{if(request.postDataJSON().action==='AnalyzeBacklog')browserBacklogSubmissions++;}catch{}} });
  page.on('dialog', async dialog => { dialogs.push(dialog.type()); await dialog.dismiss(); });
  await page.goto(ready.url + '#session=' + encodeURIComponent(ready.token), { waitUntil: 'domcontentloaded' });
  await page.locator('#refresh-button').waitFor({ state: 'visible' });
  await until(async () => Number((await page.locator('#report-total').innerText()).replaceAll(',',''))===baseline.RecordCount&&!(await page.locator('#refresh-button').isDisabled()), 'The browser did not render the saved snapshot.');
}
async function nav(name) { await page.locator('.main-nav button[data-page="' + name + '"]').click(); if(name==='reports')await page.locator('#reports-library-view').click();if(name==='monthly')await until(async()=>await page.locator('#monthly-workspace-status').getAttribute('data-month')===await page.locator('#monthly-period').inputValue()&&await page.locator('#monthly-workspace-status').getAttribute('data-loading')==='false','The Monthly workspace did not accept the selected month model.'); }
async function reviewIdentity(recordId) {
  await until(async()=>await page.locator('#pdf-area').getAttribute('data-record-id')===recordId&&await page.locator('#review-action-file').getAttribute('data-record-id')===recordId,'The displayed PDF and action scope did not agree on the selected report.');
  await until(async()=>{if(await page.locator('#pdf-image').isVisible())return await page.locator('#pdf-pages').getAttribute('data-record-id')===recordId&&await page.locator('#pdf-image').evaluate(image=>image.complete&&image.naturalWidth>0);return await page.locator('#pdf-frame').isVisible()&&(await page.locator('#pdf-frame').getAttribute('src')||'').includes('/api/pdf/'+recordId);},'The preview did not load the PDF named by the decision rail.');
}
async function decisionPair(mode) {
  check(await page.locator('#review-control-rail').isVisible(),'The decision rail remains visible beside the PDF');
  check(await page.locator('#review-current-actions').isVisible()===(mode==='single')&&await page.locator('#review-selection-tools').isVisible()===(mode==='batch'),'Exactly the current single or batch action container is visible');
  check(await page.locator('#review-control-rail #approve-button:visible,#review-control-rail #disapprove-button:visible,#review-control-rail #approve-selected-button:visible,#review-control-rail #disapprove-selected-button:visible').count()===2,'Only one Approve and Disapprove pair is presented');
}
async function settings(tab='connections'){await nav('settings');await page.locator('[data-settings-tab="'+tab+'"]').click();}
async function selectPending(recordId) {
  await nav('reports');
  await page.locator('#clear-filters').click();
  await page.locator('#status-filter').selectOption('pending');
  await page.locator('.report-item[data-record-id="' + recordId + '"]').click();
  await until(async () => (await page.locator('#pdf-frame').isVisible()) || (await page.locator('#pdf-image').isVisible()), 'The selected PDF preview did not become visible.');
  if (await page.locator('#pdf-image').isVisible()) await until(() => page.locator('#pdf-image').evaluate(image => image.complete && image.naturalWidth > 0), 'The native PDF page image did not load.');
  if(await page.locator('#review-target-type').isVisible()&&!(await page.locator('#review-target-type').inputValue())){const record=(await snapshot()).records.find(row=>row.id===recordId);await page.locator('#review-target-type').selectOption(['Daily','Monthly','Other'].includes(record?.category)?record.category:'Other');}
  await reviewIdentity(recordId);
  await until(() => page.locator('#approve-button').isEnabled(), 'The approve button was not available for the pending PDF.');
}
async function enterWithKeyboard(selector, value, paste = false) {
  await page.locator(selector).click();
  await page.keyboard.press('Control+A');
  if (paste) await page.keyboard.insertText(value); else await page.keyboard.type(value);
}
async function scenario(name, fn) {
  try { await fn(); results.push({ name, result: 'PASS' }); process.stdout.write('PASS ' + name + '\n'); }
  catch (error) { results.push({ name, result: 'FAIL', details: clean(error.stack || error.message) }); process.stdout.write('FAIL ' + name + ': ' + clean(error.message) + '\n'); throw error; }
}
function verifyArchivePreserved() {
  const stateBytes = fs.readFileSync(path.join(baseline.ArchiveRoot, '.ctqa', 'state.json'));
  check(sha(stateBytes) === baseline.ArchiveStateSHA256, 'The entire core archive state, including exact clinical timestamps, stays byte-for-byte unchanged');
  const state = JSON.parse(stateBytes.toString('utf8').replace(/^\uFEFF/, ''));
  check(state.Records.length === baseline.RecordCount, 'Every archive record remains present');
  for (const original of baseline.Records) {
    const record = state.Records.find(r => r.Id === original.Id);
    check(!!record, 'An original record identity remains present');
    check(record.Hash === original.Hash && sha(fs.readFileSync(record.DestinationPath || original.DestinationPath)) === original.Hash, 'Original archived PDF bytes remain unchanged');
    for (const field of ['Category', 'ConfirmedBy']) check(String(record[field] || '') === String(original[field] || ''), 'Classification-only review does not rewrite clinical ' + field);
    check(JSON.stringify(record.ConfirmedComponents || []) === JSON.stringify(original.ConfirmedComponents || []), 'Explicit checklist evidence remains unchanged');
  }
  for (const source of baseline.Sources) check(sha(fs.readFileSync(source.Path)) === source.Hash, 'Scanner-source fixture bytes remain unchanged');
}
(async () => {
  let chosen, before;
  try {
    analysisBarrier();
    await startHost();
    await scenario('The local API rejects missing authentication, hostile origins and arbitrary actions', async () => {
      let response = await api('/api/snapshot', {}, false); check([401, 403].includes(response.status), 'Saved data is inaccessible without the session token');
      response = await api('/api/actions', { method: 'POST', headers: { Origin: 'https://untrusted.invalid', 'Content-Type': 'application/json' }, body: '{"action":"Refresh"}' }); check(response.status === 403, 'A different origin cannot invoke local actions');
      response = await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"RunShell","command":"not executed"}' }); check(response.status === 400, 'An arbitrary shell action is rejected');
      response = await api('/api/pdf/not-a-report'); check(response.status === 400, 'PDF access requires a report ID');
      before = await waitSnapshot(); chosen = before.records.find(record => record.pending && record.scanner === 'CT_Edge' && /monthly/i.test(record.category)); check(!!chosen, 'The real imported fixture includes an unresolved Monthly report');
      // Read two generated uncertain files so decision tests exercise genuine
      // exceptions rather than PDFs still waiting in the background queue.
      const decisionFixtures=[chosen,...before.records.filter(record=>record.pending&&record.id!==chosen.id)].slice(0,2);
      for(const record of decisionFixtures)await action({action:'Analyze',id:record.id});
      before=await waitSnapshot(value=>decisionFixtures.every(record=>value.records.some(row=>row.id===record.id&&row.filingState==='NeedsReview')));chosen=before.records.find(record=>record.id===chosen.id);
      check(before.filingSummary.needsReview>=2,'Two completely read uncertain reports are available for the decision and advance workflow');
    });
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (args['browser-channel']) launchOptions.channel = args['browser-channel'];
    else launchOptions.executablePath = args.chromium || process.env.CHROMIUM_PATH || '/usr/bin/chromium';
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, acceptDownloads: true });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) { externalRequests.push(url.hostname); route.abort(); } else route.continue(); });
    await scenario('The eight-tab interface loads locally without external assets', async () => {
      await loadBrowserPage();
      check(JSON.stringify(await page.locator('.main-nav button[data-page]').evaluateAll(nodes=>nodes.map(n=>n.dataset.page)))===JSON.stringify(['today','monthly','reports','review','exports','folders','trends','settings']), 'Today, Monthly, Reports, Review, Exports, Folders, Trends and Settings have separate tabs');
      const reading=(await snapshot()).analysis,coverage=await page.locator('#pdf-reading-coverage').innerText();check(coverage.includes(Number(reading.cached).toLocaleString()+' cached results')&&coverage.includes(Number(reading.pending).toLocaleString()+' need reading'),'Today shows factual PDF-reading coverage independently of filing counts');check(coverage.includes('may overlap')&&coverage.includes('do not mean clinical approval'),'Reading coverage explains overlapping totals and does not imply clinical approval');await page.locator('#pdf-reading-options-button').click();check(await page.locator('[data-settings-section="reading"]').isVisible(),'Reading options opens its dedicated settings section');await nav('today');
      await page.screenshot({ path: path.join(output, 'today-web-demo.png'), fullPage: true });
      await settings(); await page.locator('#connection-scanner').waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'settings-web-demo.png'), fullPage: true });
      await nav('monthly');await page.screenshot({path:path.join(output,'monthly-web-demo.png'),fullPage:true});
      await nav('reports');await page.screenshot({path:path.join(output,'reports-web-demo.png'),fullPage:true});
      await nav('exports');await page.screenshot({path:path.join(output,'exports-web-demo.png'),fullPage:true});
      await nav('folders');await page.screenshot({path:path.join(output,'folders-web-demo.png'),fullPage:true});
      await nav('trends');await page.locator('#trend-chart').waitFor({state:'visible'});await page.screenshot({path:path.join(output,'trends-web-demo.png'),fullPage:true});
      await selectPending(chosen.id);
      check(await page.locator('#page-review input[type=text], #page-review textarea').count() === 0, 'Review requires no typed name, reason or authorization form');
      await decisionPair('single');await reviewIdentity(chosen.id);
      check((await page.locator('#approve-button').innerText()).includes('Approve as Monthly'),'The approval action clearly names its Monthly filing target');
      check((await page.locator('#disapprove-button').innerText()).includes('Other'),'Disapprove states that the PDF will be kept as Other');
      await delay(4000);
      await page.screenshot({ path: path.join(output, 'review-web-demo.png'), fullPage: true });
      check(await page.locator('#review-control-rail').isVisible(),'Decision actions stay visible independently of the report-group list');
      check(await page.locator('#page-review').isVisible()&&!(await page.locator('#page-reports').isVisible()),'Opening a report enters the separate Review workspace');
      check(externalRequests.length === 0, 'All requested interface assets came from the local host');
      check(browserBacklogSubmissions===0,'Rendering and switching tabs never submits repeated automatic reading jobs');
      const filing=await snapshot();check(Number(await page.locator('#nav-pending').innerText())===filing.filingSummary.needsReview,'The Review badge counts file exceptions rather than all unread PDFs');
      await nav('reports');await page.locator('#status-filter').selectOption('waiting');check(await page.locator('.report-item').count()===filing.filingSummary.waitingRead,'Awaiting-reading filter is separate from manual review exceptions');await page.locator('#clear-filters').click();
      await nav('trends');check(await page.locator('#trend-metric option[value=SliceThickness]').innerText()==='Slice thickness','The additional millimetre-based metric is selectable');await selectPending(chosen.id);
    });
    await scenario('Light and Dark appearance apply consistently across all eight tabs and persist in saved settings',async()=>{
      check((await snapshot()).settings.theme==='Light','The imported baseline starts in Light appearance');
      for(const theme of ['Dark','Light']){
        await page.locator('#theme-toggle').click();
        await until(async()=>(await snapshot()).settings.theme===theme,'The appearance preference was not saved.');
        await until(()=>page.locator('#theme-toggle').isEnabled(),'The appearance save did not release its toggle.');
        for(const tab of ['today','monthly','reports','review','exports','folders','trends','settings']){
          await nav(tab);
          check(await page.locator('html').getAttribute('data-theme')===theme.toLowerCase(),'The '+tab+' tab uses the chosen '+theme+' appearance');
          check(await page.locator('#page-'+tab).isVisible(),'The '+tab+' tab is available in '+theme+' appearance');
          await page.screenshot({path:path.join(output,tab+'-'+theme.toLowerCase()+'-web-demo.png'),fullPage:true});
        }
        check(await page.locator('#theme-toggle').getAttribute('aria-pressed')===String(theme==='Dark'),'Appearance toggle describes its current state accessibly');
      }
      await selectPending(chosen.id);verifyArchivePreserved();
    });
    await scenario('The Reports calendar preserves receipt, Library filters and exact-day export scope',async()=>{
      await nav('today');check(await page.locator('#page-today #daily-calendar').count()===0,'Today keeps the full receipt calendar in Reports');await page.locator('#today-calendar-button').click();check(await page.locator('#page-reports').isVisible()&&await page.locator('#daily-calendar').isVisible(),'The Today shortcut opens the Reports receipt calendar');await page.locator('#reports-library-view').click();check(await page.locator('#reports-library-panel').isVisible(),'Reports exposes a separate Library view');await page.locator('#report-search').fill('Quality');await page.locator('#reports-calendar-view').click();check(await page.locator('#daily-calendar').evaluate(node=>node.open),'Selecting Receipt calendar opens its complete month');await page.locator('#reports-library-view').click();check(await page.locator('#report-search').inputValue()==='Quality','Switching calendar views preserves Library search');await page.locator('#clear-filters').click();await page.locator('#reports-calendar-view').click();
      const value=await snapshot(),scanner=value.scanners.find(row=>row.id==='CT_Edge'),receipts=value.records.filter(row=>row.scanner===scanner.id&&row.category==='Daily'&&!row.pending&&!row.isReference&&!row.hasReferenceEvidence),receipt=receipts.find(row=>row.date.slice(0,7)!==value.today.date.slice(0,7))||receipts[0];check(!!receipt,'A saved Daily receipt is available for the calendar flow');const day=receipt.date,month=day.slice(0,7);await page.locator('#calendar-month').fill(month);await page.locator('#calendar-month').dispatchEvent('change');await page.locator('#calendar-scanner').selectOption(scanner.id);
      await until(async()=>await page.locator('#calendar-grid .calendar-day').count()>=28,'The receipt calendar did not build its month');
      const expected=value.records.filter(row=>row.scanner===scanner.id&&row.date===day&&row.category==='Daily'&&!row.pending&&!row.isReference&&!row.hasReferenceEvidence);
      check(expected.length>0,'The actual synthetic archive contains a saved Daily report for the chosen scanner and day');
      check((await page.locator('#calendar-grid [data-calendar-date="'+day+'"]').getAttribute('class')).split(/\s+/).includes('received'),'The calendar identifies the saved Daily receipt');
      const future=new Date(value.today.date.slice(0,7)+'-01T12:00:00');future.setMonth(future.getMonth()+1);const futureMonth=future.getFullYear()+'-'+String(future.getMonth()+1).padStart(2,'0');
      await page.locator('#calendar-month').fill(futureMonth);await page.locator('#calendar-month').dispatchEvent('change');
      check((await page.locator('#calendar-summary').innerText()).includes('not due yet'),'A future month is neutral and described as not due, rather than not scheduled');
      check(await page.locator('#calendar-grid .calendar-day.not-received').count()===0,'Future dates never appear as missing reports');
      await page.locator('#calendar-month').fill(month);await page.locator('#calendar-month').dispatchEvent('change');await page.locator('#calendar-scanner').selectOption('all');await page.screenshot({path:path.join(output,'daily-calendar-web-demo.png'),fullPage:true});await page.locator('#calendar-scanner').selectOption(scanner.id);
      await page.locator('#calendar-grid [data-calendar-date="'+day+'"]').click();check(await page.locator('#page-reports').isVisible()&&await page.locator('#reports-library-panel').isVisible()&&await page.locator('#report-date-filter').isVisible(),'Choosing a day returns to Library with a visible exact-date filter');
      await until(async()=>await page.locator('.report-item').count()===expected.length,'Calendar filtering did not match eligible receipt PDFs');
      const ids=await page.locator('.report-item').evaluateAll(nodes=>nodes.map(node=>node.dataset.recordId));check(JSON.stringify(ids.sort())===JSON.stringify(expected.map(row=>row.id).sort()),'Calendar results include exactly the saved Daily receipts and exclude reference evidence');
      await nav('monthly');const historicalMonthly=value.today.date.slice(0,7)==='2025-02'?'2024-02':'2025-02';await page.locator('#monthly-period').fill(historicalMonthly);await page.locator('#monthly-period').dispatchEvent('change');await page.locator('#monthly-scanner').selectOption(scanner.id);await until(async()=>await page.locator('#monthly-workspace-status').getAttribute('data-month')===historicalMonthly&&await page.locator('#monthly-workspace-status').getAttribute('data-loading')==='false','The historical Monthly scanner view did not load');check(await page.locator('#monthly-period').inputValue()===historicalMonthly&&await page.locator('#monthly-scanner').inputValue()===scanner.id,'Monthly can retain a separately chosen historical month and scanner');await nav('today');await page.locator('#monthly-overview-link').click();await until(async()=>await page.locator('#monthly-workspace-status').getAttribute('data-month')===value.today.date.slice(0,7)&&await page.locator('#monthly-workspace-status').getAttribute('data-loading')==='false','Today did not load the current Monthly model');check(await page.locator('#page-monthly').isVisible()&&await page.locator('#monthly-period').inputValue()===value.today.date.slice(0,7)&&await page.locator('#monthly-scanner').inputValue()==='all','Today opens the current-month all-scanner Monthly workspace instead of the earlier historical or Daily receipt filters');check(await page.locator('#report-date-filter').isHidden(),'The Daily receipt-day filter is not displayed as a Monthly filter');await nav('reports');check(await page.locator('#report-date-filter').isVisible()&&await page.locator('.report-item').count()===expected.length,'Returning to Library retains its independent exact-day receipt selection');
      await page.locator('#report-export-shortcut').click();check(await page.locator('#export-date-filter').isVisible()&&Number((await page.locator('#export-count').innerText()).replaceAll(',',''))===expected.length,'The export shortcut retains the exact calendar-day receipt selection');
      await page.locator('#export-clear-filters').click();await nav('reports');await page.locator('#clear-filters').click();await selectPending(chosen.id);verifyArchivePreserved();
    });
    await scenario('Review selection keeps the visible PDF and the only decision pair in the same scope',async()=>{
      const value=await snapshot(),other=value.records.find(record=>record.filingState==='NeedsReview'&&record.id!==chosen.id);check(!!other,'Two real file exceptions are available for selection scope checks');await selectPending(chosen.id);
      if(await page.locator('#review-queue-toggle').getAttribute('aria-expanded')!=='true')await page.locator('#review-queue-toggle').click();
      const showGroup=async id=>{const details=page.locator('.review-row-checkbox[data-record-id="'+id+'"]').locator('xpath=ancestor::details');if(!(await details.evaluate(node=>node.open)))await details.locator('summary').click();};
      await showGroup(other.id);const focusedRow=page.locator('.review-queue-item[data-record-id="'+other.id+'"]');await focusedRow.focus();check(await focusedRow.evaluate(node=>document.activeElement===node)&&await page.locator('#review-action-file').getAttribute('data-record-id')===chosen.id,'The focused row differs from the currently displayed PDF before Enter');await focusedRow.press('Enter');await reviewIdentity(other.id);check(await page.locator('#review-action-file').getAttribute('data-record-id')===other.id&&(await page.locator('#review-action-scope').innerText()).includes('Current PDF'),'Enter opens the focused report rather than reopening the previously selected PDF');await showGroup(chosen.id);await page.locator('.review-queue-item[data-record-id="'+chosen.id+'"]').click();await reviewIdentity(chosen.id);
      await showGroup(other.id);let checkbox=page.locator('.review-row-checkbox[data-record-id="'+other.id+'"]');await checkbox.focus();await checkbox.press('Space');await reviewIdentity(other.id);check(await checkbox.isChecked(),'Keyboard selection checks the PDF being previewed');check(await checkbox.evaluate(node=>document.activeElement===node),'Checkbox selection retains keyboard focus');await decisionPair('batch');check((await page.locator('#review-action-scope').innerText()).includes('Selected 1'),'The rail names its one-file selected scope');
      await showGroup(chosen.id);checkbox=page.locator('.review-row-checkbox[data-record-id="'+chosen.id+'"]');await checkbox.check();await reviewIdentity(chosen.id);check((await page.locator('#review-selection-count').innerText())==='2 selected','Selecting another report extends the batch and previews that report');await page.locator('.review-queue-item[data-record-id="'+other.id+'"]').click();await reviewIdentity(other.id);check((await page.locator('#review-selection-count').innerText())==='2 selected','Opening a selected row preserves its batch');await decisionPair('batch');
      await page.locator('#review-clear-selection').click();await showGroup(other.id);await page.locator('.review-row-checkbox[data-record-id="'+other.id+'"]').check();await reviewIdentity(other.id);await showGroup(chosen.id);await page.locator('.review-queue-item[data-record-id="'+chosen.id+'"]').click();await reviewIdentity(chosen.id);check((await page.locator('#review-selection-count').innerText())==='0 selected','Opening an unselected report clears the earlier batch');await decisionPair('single');check((await page.locator('#review-action-scope').innerText()).includes('Current PDF'),'The rail explicitly returns to the current PDF scope');check((await page.locator('#approve-button').innerText()).includes('Monthly'),'The single approval names the currently displayed Monthly PDF');verifyArchivePreserved();
    });
    await scenario('Folders exports the entire saved library independently of report and package filters',async()=>{
      await nav('reports');await page.locator('#report-search').fill('No matching synthetic file');await nav('exports');await page.locator('#export-search').fill('No matching synthetic package');
      await nav('folders');const value=await snapshot();check(await page.locator('#page-folders').isVisible(),'The dedicated Folders page is available');check(Number((await page.locator('#folders-pdf-count').innerText()).replaceAll(',',''))===value.records.length,'Folders states the complete saved PDF count');check(await page.locator('.folder-machine').count()===value.scanners.length,'The ordinary folder tree contains every configured machine');
      check((await page.locator('#folders-library-location').innerText())===value.libraryRoot,'The readable library location is shown without needing hidden application data');
      const transfers=page.locator('.folder-transfer-options');if(!(await transfers.evaluate(node=>node.open)))await transfers.locator('summary').click();
      const request=page.waitForRequest(request=>{if(new URL(request.url()).pathname!=='/api/actions'||request.method()!=='POST')return false;try{return request.postDataJSON().action==='Export';}catch{return false;}}),previous=new Set((await jobs()).map(job=>job.id));request.catch(()=>{});await page.locator('#folders-export-all-button').click();const payload=(await request).postDataJSON();check(JSON.stringify(payload.ids.slice().sort())===JSON.stringify(value.records.map(row=>row.id).sort()),'Export full library submits every saved record despite unrelated active filters');
      const job=await until(async()=>(await jobs()).find(job=>!previous.has(job.id)&&job.action==='Export'&&['completed','failed'].includes(job.status)),'The complete folder-library export did not finish',180000);check(job.status==='completed','The actual complete-library package is prepared');await page.locator('#folders-export-download').waitFor({state:'visible'});
      const response=await api(job.result.downloadUrl);check(response.ok,'The complete library download is available through the authenticated route');const zip=path.join(output,'synthetic-full-folder-library.zip');fs.writeFileSync(zip,Buffer.from(await response.arrayBuffer()));
      const contents=JSON.parse(execFileSync(args.python||(process.platform==='win32'?'python':'python3'),['-c','import json,zipfile,sys,hashlib;z=zipfile.ZipFile(sys.argv[1]);p=[n for n in z.namelist() if n.lower().endswith(".pdf")];print(json.dumps({"names":z.namelist(),"count":len(p),"hashes":sorted(hashlib.sha256(z.read(n)).hexdigest().upper() for n in p)}))',zip],{encoding:'utf8'}));check(contents.count===value.records.length,'The ZIP contains every saved PDF');check(JSON.stringify(contents.hashes)===JSON.stringify(baseline.Records.map(row=>row.Hash).sort()),'Every full-library exported PDF matches its preserved original bytes');check(contents.names.some(name=>name.endsWith('Report Summary.html'))&&contents.names.some(name=>name.endsWith('Report list.csv')),'The full library also contains the offline summary and CSV inventory');
      await nav('reports');check(await page.locator('#report-search').inputValue()==='No matching synthetic file','Opening Folders does not discard Reports filters');await page.locator('#clear-filters').click();await nav('exports');check(await page.locator('#export-search').inputValue()==='No matching synthetic package','Full-library export does not overwrite independent Exports filters');await page.locator('#export-clear-filters').click();await selectPending(chosen.id);verifyArchivePreserved();
    });
    await scenario('Normal mouse-release clicks keep settings and search fields focused for real keyboard input', async () => {
      await settings();
      const scanner = before.scanners.find(s => s.id === chosen.scanner);
      await page.locator('#connection-scanner').selectOption(scanner.id);
      const typedPath = scanner.path + ' typed-edit';
      await enterWithKeyboard('#connection-path', typedPath);
      check((await page.locator('#connection-path').inputValue()) === typedPath, 'Folder input accepts keyboard typing after an ordinary released mouse click');
      check(await page.evaluate(() => document.activeElement.id) === 'connection-path', 'Folder typing retains focus instead of redirecting it to the main workspace');
      await enterWithKeyboard('#connection-username', 'Synthetic Typed User');
      check((await page.locator('#connection-username').inputValue()) === 'Synthetic Typed User', 'Username accepts normal mouse-click then keyboard typing');
      check(await page.evaluate(() => document.activeElement.id) === 'connection-username', 'Username remains focused after the click and keystrokes');
      await enterWithKeyboard('#connection-password', 'Synthetic typed secret');
      check((await page.locator('#connection-password').inputValue()) === 'Synthetic typed secret', 'Password accepts keyboard typing without holding the mouse button');
      check(await page.evaluate(() => document.activeElement.id) === 'connection-password', 'Password remains focused after the normal mouse release');
      await enterWithKeyboard('#connection-path', scanner.path);
      await enterWithKeyboard('#connection-username', scanner.username);
      await page.locator('#connection-password').click(); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
      await nav('reports'); await page.locator('#report-search').click(); await page.keyboard.type('Monthly');
      check((await page.locator('#report-search').inputValue()) === 'Monthly', 'Report search accepts typing after a real released mouse click');
      check(await page.evaluate(() => document.activeElement.id) === 'report-search', 'Search input keeps keyboard focus');
      await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
      await selectPending(chosen.id);
    });
    if (args['focus-only'] === 'true') return;
    await scenario('Connection drafts survive blur, unrelated job completion and scanner switching', async () => {
      await settings();
      const scannerA = before.scanners.find(s => s.id === chosen.scanner);
      const scannerB = before.scanners.find(s => s.id !== scannerA.id);
      await page.locator('#connection-scanner').selectOption(scannerA.id);
      const draftPath = 'Synthetic pasted folder draft';
      const draftUsername = 'Synthetic Draft User';
      const secret = 'Synthetic unsaved secret - not a credential';
      await enterWithKeyboard('#connection-path', draftPath, true);
      await enterWithKeyboard('#connection-username', draftUsername);
      await enterWithKeyboard('#connection-password', secret);
      await page.getByRole('heading', { name: 'Connections', exact: true }).click();
      let browserSnapshots = 0;
      const observeSnapshot = response => { if (new URL(response.url()).pathname === '/api/snapshot' && response.status() === 200) browserSnapshots++; };
      page.on('response', observeSnapshot);
      const previousJobs = new Set((await jobs()).map(job => job.id));
      await settings('support');
      await page.locator('#diagnostics-button').click();
      await until(async () => (await jobs()).some(job => !previousJobs.has(job.id) && job.action === 'Diagnostics' && job.status === 'completed'), 'The unrelated diagnostics job did not finish.', 180000);
      await until(() => browserSnapshots > 0, 'The browser did not refresh its saved snapshot after diagnostics');
      await until(async () => !(await page.locator('#connect-button').isDisabled()), 'The connection form did not become available after diagnostics');
      page.off('response', observeSnapshot);
      await settings();
      check((await page.locator('#connection-path').inputValue()) === draftPath, 'Pasted folder draft survives blur and the unrelated job snapshot');
      check((await page.locator('#connection-username').inputValue()) === draftUsername, 'Typed username survives blur and the unrelated job snapshot');
      check((await page.locator('#connection-password').inputValue()) === secret, 'Same-scanner snapshot rendering does not erase an unsaved password');
      await nav('today'); await settings();
      check((await page.locator('#connection-path').inputValue()) === draftPath && (await page.locator('#connection-username').inputValue()) === draftUsername, 'Unsaved nonsecret connection fields survive navigation');
      await page.locator('#connection-scanner').selectOption(scannerB.id);
      check((await page.locator('#connection-password').inputValue()) === '', 'Switching scanners clears the password field');
      await enterWithKeyboard('#connection-username', 'Synthetic second-scanner draft');
      await page.locator('#connection-scanner').selectOption(scannerA.id);
      check((await page.locator('#connection-path').inputValue()) === draftPath && (await page.locator('#connection-username').inputValue()) === draftUsername, 'Each scanner retains its own nonsecret draft');
      check((await page.locator('#connection-password').inputValue()) === '', 'Returning to a scanner does not restore a secret from a draft map');
      await enterWithKeyboard('#connection-password', secret);
      const submitted = page.waitForRequest(request => { if (new URL(request.url()).pathname !== '/api/actions' || request.method() !== 'POST') return false; try { return request.postDataJSON().action === 'Reconnect'; } catch { return false; } });
      const jobsBeforeSave = new Set((await jobs()).map(job => job.id));
      await page.locator('#connect-button').click();
      const payload = (await submitted).postDataJSON();
      check(payload.path === draftPath && payload.username === draftUsername && payload.password === secret, 'An actual Save click sends the current visible connection draft');
      const rejected = await until(async () => (await jobs()).find(job => !jobsBeforeSave.has(job.id) && job.action === 'Reconnect' && ['completed', 'failed'].includes(job.status)), 'The synthetic draft validation did not finish.', 180000);
      check(rejected.status === 'failed', 'The deliberately invalid synthetic path is rejected without making a scanner connection');
      await until(async () => (await page.locator('#connection-password').inputValue()) === '', 'Saving did not clear the password input');
      check(!JSON.stringify(await jobs()).includes(secret), 'Draft password text does not appear in public job records');
      await enterWithKeyboard('#connection-path', scannerA.path); await enterWithKeyboard('#connection-username', scannerA.username);
      await page.locator('#connection-scanner').selectOption(scannerB.id); await enterWithKeyboard('#connection-username', scannerB.username);
      await page.locator('#connection-scanner').selectOption(scannerA.id);
      check(await page.locator('#monthly-due-day,#expected-monthly,#monthly-checklist,#checklist-effective-month').count()===0,'Connections has no duplicate Monthly setup controls');
      const cleanScanner=(await snapshot()).scanners.find(scanner=>![scannerA.id,scannerB.id].includes(scanner.id));check(!!cleanScanner,'A third scanner has no unsaved connection drafts');const monthlyFields=scanner=>Object.fromEntries(Object.keys(scanner).filter(key=>/monthly|checklist/i.test(key)).sort().map(key=>[key,scanner[key]])),monthlyUnchanged=JSON.stringify(monthlyFields(cleanScanner));await page.locator('#connection-scanner').selectOption(cleanScanner.id);const dailyDetails=page.locator('#save-scanner-options').locator('xpath=ancestor::details');if(!(await dailyDetails.evaluate(node=>node.open)))await dailyDetails.locator('summary').click();
      for(const [id,value]of[['connection-path',cleanScanner.path],['connection-username',cleanScanner.username],['scanner-display-name',cleanScanner.name],['scanner-drive',cleanScanner.drive],['scanner-active-from',cleanScanner.activeFrom]])check(await page.locator('#'+id).inputValue()===String(value||''),'The clean Daily setup uses its saved '+id+' value');
      const dailyRequest=page.waitForRequest(request=>{if(new URL(request.url()).pathname!=='/api/actions'||request.method()!=='POST')return false;try{const payload=request.postDataJSON();return payload.action==='ScannerSettings'&&payload.scanner===cleanScanner.id;}catch{return false;}});dailyRequest.catch(()=>{});const previousDailyJobs=new Set((await jobs()).map(job=>job.id));await page.locator('#save-scanner-options').click();const dailyPayload=(await dailyRequest).postDataJSON();check(['expectedMonthly','monthlyDueDay','checklist','checklistEffectiveMonth'].every(key=>!Object.prototype.hasOwnProperty.call(dailyPayload,key)),'Saving Daily options omits all Monthly setup fields');check(dailyPayload.path===cleanScanner.path&&dailyPayload.username===cleanScanner.username&&dailyPayload.name===cleanScanner.name&&dailyPayload.drive===String(cleanScanner.drive||'')&&dailyPayload.activeFrom===String(cleanScanner.activeFrom||''),'The Daily save retains valid scanner connection and source-folder values');const dailyJob=await until(async()=>(await jobs()).find(job=>!previousDailyJobs.has(job.id)&&job.action==='ScannerSettings'&&['completed','failed'].includes(job.status)),'The real Daily scanner-options save did not finish.',180000);check(dailyJob.status==='completed','The Daily scanner-options action completes');const dailySavedSnapshot=await snapshot(),dailySaved=dailySavedSnapshot.scanners.find(scanner=>scanner.id===cleanScanner.id);check(JSON.stringify(monthlyFields(dailySaved))===monthlyUnchanged,'Daily setup leaves every Monthly field and checklist-history version unchanged');await until(()=>page.locator('#save-scanner-options').isEnabled(),'The Daily scanner-options form did not finish its completed save');await page.locator('#connection-monthly-shortcut').click();await until(async()=>await page.locator('#monthly-workspace-status').getAttribute('data-month')===dailySavedSnapshot.today.date.slice(0,7)&&await page.locator('#monthly-workspace-status').getAttribute('data-loading')==='false','The selected scanner Monthly shortcut did not load its current-month model');check(await page.locator('#page-monthly').isVisible()&&await page.locator('#monthly-scanner').inputValue()===cleanScanner.id&&await page.locator('#monthly-setup-panel').evaluate(node=>node.open),'The connection shortcut opens Monthly setup for its selected scanner');verifyArchivePreserved();
      const monthlyBefore=(await snapshot()).scanners.find(scanner=>scanner.id===scannerA.id),originalChecklist=monthlyBefore.checklist.slice(),effectiveMonth=monthlyBefore.nextChecklistEffectiveMonth;check(/^\d{4}-\d{2}$/.test(effectiveMonth),'The actual scanner supplies its next valid checklist save month');await nav('monthly');await page.locator('#monthly-scanner').selectOption(scannerA.id);const setup=page.locator('#monthly-setup-panel');if(!(await setup.evaluate(node=>node.open)))await setup.locator('summary').click();await page.locator('#monthly-setup-due-day').fill('24');if(await page.locator('#monthly-effective-month').inputValue()!==effectiveMonth){await page.locator('#monthly-effective-month').fill(effectiveMonth);await page.locator('#monthly-effective-month').dispatchEvent('change');}
      await nav('today');await nav('monthly');check(await page.locator('#monthly-scanner').inputValue()===scannerA.id&&await page.locator('#monthly-setup-due-day').inputValue()==='24','An unsaved Monthly due-day draft survives leaving and returning to its scanner');check(await page.locator('#monthly-effective-month').inputValue()===effectiveMonth,'The Monthly draft retains the valid checklist effective month');if(!(await setup.evaluate(node=>node.open)))await setup.locator('summary').click();const setupRequest=page.waitForRequest(request=>{if(new URL(request.url()).pathname!=='/api/actions'||request.method()!=='POST')return false;try{const payload=request.postDataJSON();return payload.action==='ScannerSettings'&&payload.scanner===scannerA.id&&Object.prototype.hasOwnProperty.call(payload,'checklist');}catch{return false;}});setupRequest.catch(()=>{});const previousSetupJobs=new Set((await jobs()).map(job=>job.id));await page.locator('#monthly-configure-button').click();const setupPayload=(await setupRequest).postDataJSON();check(setupPayload.monthlyDueDay===24&&setupPayload.checklistEffectiveMonth===effectiveMonth,'The Monthly setup form submits the visible due day and valid effective month');check(JSON.stringify(setupPayload.checklist.slice().sort())===JSON.stringify(originalChecklist.slice().sort()),'Changing only the due day preserves every original checklist label');const setupJob=await until(async()=>(await jobs()).find(job=>!previousSetupJobs.has(job.id)&&job.action==='ScannerSettings'&&['completed','failed'].includes(job.status)),'The actual Monthly setup save did not finish.',180000);check(setupJob.status==='completed','The Monthly setup save completes through the real scanner-settings action');const monthlySaved=(await waitSnapshot(value=>value.scanners.some(scanner=>scanner.id===scannerA.id&&Number(scanner.monthlyDueDay)===24))).scanners.find(scanner=>scanner.id===scannerA.id);check(JSON.stringify(monthlySaved.checklist.slice().sort())===JSON.stringify(originalChecklist.slice().sort()),'Saved Monthly setup retains the unchanged department checklist');await until(async()=>(await page.locator('#monthly-save-status').innerText()).includes('saved'),'The Monthly setup form did not report its successful save');
      verifyArchivePreserved();
      await selectPending(chosen.id);
    });
    await scenario('The PDF preview returns the selected verified local report', async () => {
      const response = await api('/api/pdf/' + chosen.id);
      check(response.ok && /application\/pdf/.test(response.headers.get('content-type') || ''), 'Actual saved PDF bytes are available through the authenticated route');
      check((response.headers.get('content-security-policy') || '').includes("frame-ancestors 'self'"), 'The PDF response explicitly permits its same-origin preview frame');
      const bytes = Buffer.from(await response.arrayBuffer()); const original = baseline.Records.find(r => r.Id === chosen.id);
      check(bytes.subarray(0, 5).toString() === '%PDF-' && sha(bytes) === original.Hash, 'Preview bytes match the original indexed SHA-256');
      if (String(before.previewMode || '').toLowerCase() === 'windows') {
        check(await page.locator('#pdf-image').isVisible(), 'Windows shows the rendered PDF page inside the review pane');
        const source = await page.locator('#pdf-image').getAttribute('src');
        check(source && source.startsWith('blob:'), 'The native review uses a local revocable image URL');
        const decoded=await page.locator('#pdf-image').evaluate(image=>({complete:image.complete,width:image.naturalWidth,height:image.naturalHeight}));
        check(decoded.complete&&decoded.width>0&&decoded.height>0,'The local Blob image has actually decoded into visible PDF pixels');
        // Browser connect-src intentionally excludes blob:. Verify the renderer's
        // PNG through its authenticated API, without broadening production CSP.
        const renderedResponse=await api('/api/preview/'+chosen.id+'?page=0');
        check(renderedResponse.ok,'The authenticated selected-page renderer returns successfully');
        const rendered=await renderedResponse.json(),field=name=>rendered[Object.keys(rendered).find(key=>key.toLowerCase()===name.toLowerCase())];
        check(field('RecordId')===chosen.id&&field('Hash')===original.Hash&&field('PageNumber')===0,'The native PNG is bound to the selected indexed PDF fingerprint and page');
        const bytes=Buffer.from(field('PngBase64'),'base64');
        check(bytes.length>=24&&bytes.subarray(0,8).toString('hex')==='89504e470d0a1a0a','The authenticated renderer supplies a PNG page');
        check(bytes.readUInt32BE(16)===decoded.width&&bytes.readUInt32BE(20)===decoded.height,'The visible decoded image dimensions match the authenticated PNG page');
        check(previewRequests.includes('/api/preview/' + chosen.id), 'The rendered preview was requested for the selected report ID');
        check(!(await page.locator('#preview-previous-page').isVisible())&&!(await page.locator('#preview-next-page').isVisible()), 'Continuous PDF review does not require Previous or Next page buttons');
        check(await page.locator('#pdf-pages .pdf-page').count()===1,'The one-page synthetic document has exactly one page in the scrolling preview');
        nativePreviewActuallyRun = true;
      } else {
        const frameSrc = await page.locator('#pdf-frame').getAttribute('src'); check(frameSrc && frameSrc.includes('/api/pdf/' + chosen.id), 'The browser preview is bound to the selected report ID');
      }
      const bounds = await api('/api/preview/' + chosen.id + '?page=-1'); check(bounds.status === 400, 'Invalid native preview page numbers are rejected before rendering');
    });
    await scenario('Approve removes one pending suggestion without names or confirmation dialogs', async () => {
      const pendingBefore = before.records.filter(r => r.pending).length;
      await page.locator('#approve-button').click();
      const after = await waitSnapshot(s => s.records.some(r => r.id === chosen.id && !r.pending && /^approved$/i.test(r.decision)));
      check(after.records.filter(r => r.pending).length === pendingBefore - 1, 'Only the chosen report leaves pending');
      check(after.records.length === before.records.length, 'Approving preserves the entire report library');
      await page.locator('#undo-button').waitFor({ state: 'visible' });
      const next=await page.locator('#report-content-panel').getAttribute('data-record-id');
      check(next!==chosen.id&&after.records.some(row=>row.id===next&&row.pending),'Review automatically advances to another pending PDF outside the filtered Reports list');
      verifyArchivePreserved(); check(dialogs.length === 0, 'No modal confirmation dialog appeared');
    });
    await scenario('Undo restores pending and Disapprove keeps the PDF as Other', async () => {
      await page.locator('#undo-button').click();
      const restored = await waitSnapshot(s => s.records.some(r => r.id === chosen.id && r.pending));
      check(restored.records.find(r => r.id === chosen.id).pending, 'Undo restores the original pending state');
      await selectPending(chosen.id); await page.locator('#disapprove-button').click();
      const declined = await waitSnapshot(s => s.records.some(r => r.id === chosen.id && !r.pending && /^disapproved$/i.test(r.decision)));
      const record = declined.records.find(r => r.id === chosen.id);
      check(/^other$/i.test(record.category), 'Disapproved suggestion becomes an Other document');
      check(declined.records.length === baseline.RecordCount, 'Disapprove does not delete a record');
      verifyArchivePreserved(); check(dialogs.length === 0, 'Disapprove needs no additional form or confirmation');
      const history = JSON.parse(fs.readFileSync(path.join(baseline.ArchiveRoot, '.ctqa', 'organization.json'), 'utf8').replace(/^\uFEFF/, ''));
      check(history.History.filter(h => h.recordId === chosen.id).length === 3, 'Approve, Undo and Disapprove all remain in activity history');
    });
    await scenario('A stale approval cannot overwrite a later organization decision', async () => {
      await action({ action: 'Approve', id: chosen.id, stamp: chosen.stamp }, 'failed');
      const after = await waitSnapshot(); check(/^disapproved$/i.test(after.records.find(r => r.id === chosen.id).decision), 'The rejected stale action leaves the latest decision intact');
    });
    await scenario('Filtering and export use the matching saved PDFs', async () => {
      await nav('reports'); await page.locator('#clear-filters').click();
      await page.locator('#scanner-filter').selectOption(chosen.scanner); await page.locator('#type-filter').selectOption('monthly');
      const expected = (await waitSnapshot()).records.filter(r => r.scanner === chosen.scanner && /^monthly$/i.test(r.category));
      check(expected.length > 0, 'The export filter has actual imported Monthly documents');
      await until(async () => (await page.locator('.report-item').count()) === expected.length, 'The filtered report list did not match the saved snapshot');
      check(await page.locator('.report-item').count() === expected.length, 'Scanner/type filtering has the exact expected count');
      await page.locator('#report-export-shortcut').click();
      check(await page.locator('#page-exports').isVisible(),'The Reports export shortcut opens the separate Exports tab');
      check(await page.locator('#export-scanner-filter').inputValue()===chosen.scanner&&await page.locator('#export-type-filter').inputValue()==='monthly','The explicit export shortcut copies current report filters');
      check(Number((await page.locator('#export-count').innerText()).replaceAll(',',''))===expected.length,'The export package previews every matching report');
      await page.locator('#export-choose-years').click();
      check(await page.locator('#year-choices input[type="checkbox"]').count()>=2,'The export fixture includes reports from multiple real indexed years');
      for(const box of await page.locator('#year-choices input[type="checkbox"]').all())await box.check();
      await page.locator('#apply-years').click();
      check(await page.locator('#export-year-filter').inputValue()==='multiple','Exports retain an explicit multiple-year selection');
      const previousExport=new Set((await jobs()).map(job=>job.id));await page.locator('#export-button').click();
      const job=await until(async()=>(await jobs()).find(job=>!previousExport.has(job.id)&&job.action==='Export'&&['completed','failed'].includes(job.status)),'The report ZIP did not finish.',180000);check(job.status==='completed','The newly requested filtered export finishes successfully');
      check(!!job.result?.downloadUrl, 'A completed export exposes an authenticated download');
      const response = await api(job.result.downloadUrl); check(response.ok, 'The exported ZIP can be downloaded');
      const destination = path.join(output, 'synthetic-filtered-export.zip'); fs.writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
      const verification = JSON.parse(execFileSync(args.python || (process.platform === 'win32' ? 'python' : 'python3'), ['-c', 'import json,zipfile,sys,hashlib;z=zipfile.ZipFile(sys.argv[1]);pdf=[i for i in z.namelist() if i.lower().endswith(".pdf")];print(json.dumps({"pdfs":len(pdf),"hashes":[hashlib.sha256(z.read(i)).hexdigest().upper() for i in pdf],"summary":any(i.endswith(".html") for i in z.namelist())}))', destination], { encoding: 'utf8' }));
      check(verification.pdfs === expected.length && verification.summary, 'The ZIP includes exactly the filtered PDFs and an offline summary');
      check(verification.hashes.every(hash => expected.some(r => baseline.Records.find(b => b.Id === r.id).Hash === hash)), 'Every exported PDF retains its original fingerprint');
      await nav('reports');await page.locator('#report-search').fill('No synthetic report has this phrase');
      await until(async()=>await page.locator('.report-item').count()===0,'The independent Reports search did not apply.');
      await nav('exports');
      check(Number((await page.locator('#export-count').innerText()).replaceAll(',',''))===expected.length&&await page.locator('#export-search').inputValue()==='','Changing Reports search does not silently change the prepared export package');
    });
    await scenario('Saved organization decisions survive a full host restart', async () => {
      if (!args.host) { check(false, 'Supply --host for the required restart persistence regression'); }
      await page.locator('#theme-toggle').click();
      await until(async()=>(await snapshot()).settings.theme==='Dark','Dark appearance did not save before restart.');
      await until(()=>page.locator('#theme-toggle').isEnabled(),'Appearance toggle did not finish saving before restart.');
      const oldToken = ready.token; await stopHost(); await startHost();
      check(oldToken !== ready.token, 'A restarted host gets a fresh authentication token');
      const oldResponse = await api('/api/snapshot', { headers: { 'X-Qa-Session': oldToken } }); check(oldResponse.status === 401, 'The previous process token cannot access the restarted host');
      const after = await waitSnapshot(); check(after.records.some(r => r.id === chosen.id && !r.pending && /^disapproved$/i.test(r.decision)), 'The saved Disapprove state survives a new process');
      check(after.settings.theme==='Dark','The saved Dark preference survives a full host restart');
      await loadBrowserPage();check(await page.locator('html').getAttribute('data-theme')==='dark','A fresh session on a new local port loads the saved Dark appearance');
      await page.locator('#theme-toggle').click();await until(async()=>(await snapshot()).settings.theme==='Light','The test could not restore Light appearance.');
      await nav('reports'); await page.locator('#status-filter').selectOption('disapproved');
      await page.locator('.report-item[data-record-id="' + chosen.id + '"]').waitFor({ state: 'visible' });
      await nav('review');
      check(await page.locator('#undo-button').isVisible(), 'Undo remains available from persisted last-decision metadata');
      verifyArchivePreserved();
    });
    await scenario('Connection failures remain visible and job records do not expose entered passwords', async () => {
      await settings(); await page.locator('#connection-scanner').selectOption(chosen.scanner);
      const canary = 'Synthetic test password - not a real credential';
      await page.locator('#connection-password').fill(canary);
      await page.locator('#remember-credentials').uncheck();
      const previousReconnect=new Set((await jobs()).map(job=>job.id));await page.locator('#connect-button').click();
      const job = await until(async () => (await jobs()).find(j => !previousReconnect.has(j.id)&&j.action === 'Reconnect' && ['completed', 'failed'].includes(j.status)), 'The synthetic connection test did not finish.', 180000);
      const after = await waitSnapshot(); const scanner = after.scanners.find(s => s.id === chosen.scanner);
      check(String(scanner.status).toLowerCase() !== 'connected', 'An inaccessible local fixture is not represented as a successful scanner sign-in');
      if (job.status === 'completed') {
        check(!!scanner.message, 'The connection result explains the scanner access failure');
        await until(async () => (await page.locator('#connection-result').innerText()).includes(scanner.message), 'The specific scanner failure message was not displayed');
      } else {
        const errorText = typeof job.error === 'string' ? job.error : job.error?.message;
        check(!!errorText, 'A failed connection job includes a readable error');
        await until(async () => (await page.locator('body').innerText()).includes(errorText), 'The connection job error was not displayed');
      }
      check(true, 'The specific scanner result or failure message is visible');
      check(!JSON.stringify(await jobs()).includes(canary), 'Entered password text is absent from public job results');
      await until(async () => (await page.locator('#connection-password').inputValue()) === '', 'The password field was not cleared after the connection attempt');
      check((await page.locator('#connection-password').inputValue()) === '', 'The entered password is not left displayed in the form');
      verifyArchivePreserved();
    });
    await scenario('Background PDF reading pauses at a saved boundary and allows review, settings and exports to continue',async()=>{
      holdAnalysis();await settings('reading');
      const previous=new Set((await jobs()).map(job=>job.id));await page.locator('#analyze-button').click();
      await until(()=>fs.existsSync(analyzeReached),'The real PDF analysis did not reach its disposable test checkpoint.');
      const running=await until(async()=>(await jobs()).find(job=>!previous.has(job.id)&&job.action==='Analyze'&&job.status==='running'),'The background reader was not visible.');
      check(running.background&&running.pausable,'Whole-library analysis is identified as pausable background work');
      await page.locator('#background-reading-band').waitFor({state:'visible'});
      await page.locator('#background-reading-toggle').click();
      await until(async()=>(await jobs()).some(job=>job.id===running.id&&job.pauseRequested),'Pause did not reach the host.');
      releaseAnalysis();
      const paused=await until(async()=>(await jobs()).find(job=>job.id===running.id&&job.paused),'Background reading did not pause after its current PDF.');
      check(paused.stage==='Paused'&&paused.completed>=1,'Pause retains a factual saved PDF checkpoint');
      await settings('reading');check(await page.locator('#pdf-reader-mode').isEnabled(),'Reading preferences stay editable while background analysis is paused');
      await nav('reports');await page.locator('#clear-filters').click();await page.locator('#report-search').fill('Monthly');
      check(await page.locator('.report-item').count()>0,'Reports stay searchable while the reader is paused');
      const pending=(await snapshot()).records.find(row=>row.filingState==='NeedsReview');check(!!pending,'A file exception remains for the foreground review test');
      await selectPending(pending.id);check(await page.locator('#approve-button').isEnabled(),'Approve stays available during background work');
      let foreground=new Set((await jobs()).map(job=>job.id));await page.locator('#approve-button').click();
      await until(async()=>(await jobs()).some(job=>!foreground.has(job.id)&&job.action==='Approve'&&job.status==='completed'),'Foreground review did not finish while background analysis was paused.');
      await nav('exports');await page.locator('#export-clear-filters').click();
      await until(()=>page.locator('#export-button').isEnabled(),'Exports did not become available while background reading stayed paused.');
      check(true,'Exports stay available during paused background reading');
      foreground=new Set((await jobs()).map(job=>job.id));await page.locator('#export-button').click();
      await until(async()=>(await jobs()).some(job=>!foreground.has(job.id)&&job.action==='Export'&&job.status==='completed'),'Foreground export did not finish while background analysis was paused.');
      check((await jobs()).find(job=>job.id===running.id)?.paused,'Foreground work does not silently resume the background reader');
      const completed=paused.completed;
      holdAnalysis();await page.locator('#background-reading-toggle').click();
      await until(()=>fs.existsSync(analyzeReached),'Resume did not start the next PDF chunk.');
      check((await jobs()).find(job=>job.id===running.id)?.id===running.id,'Resume continues the same background job');
      await page.locator('#background-reading-cancel').click();
      const cancelled=await until(async()=>(await jobs()).find(job=>job.id===running.id&&['completed','failed','cancelled'].includes(job.status)),'Cancelling the resumed background reader did not finish.');
      check(cancelled.status==='cancelled'&&cancelled.cancelRequested,'Cancellation finishes as cancelled and starts no further batch');
      check(cancelled.completed>=completed,'Cancellation retains already saved PDF progress');
      releaseAnalysis();await until(async()=>!(await page.locator('#background-reading-band').isVisible()),'The completed reader left its background controls visible.');
      await nav('review');await until(()=>page.locator('#undo-button').isEnabled(),'The saved foreground decision was not available for Undo.');
      await page.locator('#undo-button').click();await waitSnapshot(value=>value.records.some(row=>row.id===pending.id&&row.pending));
      check(true,'Undo remains usable after background cancellation and restores the pending filing decision');
      verifyArchivePreserved();
    });
    await scenario('One support export includes detailed scrubbed activity, report reasons and a separately printable report',async()=>{
      await settings('support');
      const previous=new Set((await jobs()).map(job=>job.id));
      await page.locator('#diagnostics-button').click();
      const bundled=await until(async()=>(await jobs()).find(job=>!previous.has(job.id)&&job.action==='Diagnostics'&&['completed','failed'].includes(job.status)),'The detailed diagnostic ZIP did not finish.',180000);
      check(bundled.status==='completed','The diagnostic ZIP finishes successfully');
      const zipUrl=bundled.result?.downloadUrl;check(!!zipUrl,'A completed diagnostic export exposes its authenticated ZIP');
      await until(async()=>await page.locator('#support-download-link').isVisible()&&(await page.locator('#support-download-link').getAttribute('href')).endsWith(zipUrl),'The diagnostic ZIP link was not retained in Support.');
      const zipResponse=await api(zipUrl);check(zipResponse.ok,'The detailed diagnostic ZIP downloads successfully');
      const zipPath=path.join(output,'synthetic-detailed-diagnostics.zip');fs.writeFileSync(zipPath,Buffer.from(await zipResponse.arrayBuffer()));
      const contents=JSON.parse(execFileSync(args.python||(process.platform==='win32'?'python':'python3'),['-c','import json,zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);print(json.dumps({n:z.read(n).decode("utf-8-sig") for n in z.namelist()}))',zipPath],{encoding:'utf8'}));
      const expectedEntries=['READ ME.txt','Report-Diagnostics.csv','Report-Diagnostics.jsonl','Scrubbed-Activity.csv','Scrubbed-Activity.jsonl','Support-Summary.json','SupportReport.html'];
      check(JSON.stringify(Object.keys(contents).sort())===JSON.stringify(expectedEntries),'The ZIP contains the printable report, structured summary and complete CSV/JSONL report and activity details');
      const support=JSON.parse(contents['Support-Summary.json']),reportRows=contents['Report-Diagnostics.jsonl'].trim().split(/\r?\n/).filter(Boolean).map(line=>JSON.parse(line)),events=contents['Scrubbed-Activity.jsonl'].trim().split(/\r?\n/).filter(Boolean).map(line=>JSON.parse(line));
      check(support.ArchiveRecords===baseline.RecordCount&&reportRows.length===baseline.RecordCount,'Diagnostic detail accounts for every archived synthetic PDF without bundling its contents');
      check(new Set(reportRows.map(row=>row.Reference)).size===baseline.RecordCount&&reportRows.every(row=>/^Report[0-9]{4,}$/.test(row.Reference)),'Each report gets a unique per-export reference instead of its filename, path or fingerprint');
      check(reportRows.every(row=>/^Scanner [0-9]+$/.test(row.Scanner)),'Configured scanners use anonymous ordinal labels');
      check(events.some(event=>event.Operation==='PdfRead')&&events.some(event=>event.Operation==='Reconnect'&&event.Outcome==='Failed'),'Activity retains PDF work and failed connection attempts for diagnosis');
      const combined=Object.values(contents).join('\n');
      for(const canary of ['Synthetic Draft User','Synthetic test password - not a real credential','Synthetic unsaved secret - not a credential','Synthetic evidence reviewer',baseline.FixtureRoot,baseline.ArchiveRoot,...baseline.Records.map(row=>row.Hash)])check(!combined.includes(canary),'The shareable ZIP excludes a private sentinel, workstation path or original report fingerprint');
      check(!Object.keys(contents).some(name=>/\.(pdf|log|ps1)$/i.test(name)),'Raw reports, startup logs and commands are not included');
      check(/UnknownTemplate|MissingFormatRule|Unread|MeasurementUpgradePending|NoSupportedTables/.test(combined),'The diagnostic export explains unread, unsupported or rule-dependent evidence instead of only a pending total');
      const html=contents['SupportReport.html'];
      check(/Diagnostic report/i.test(html)&&/@media\s+print/i.test(html)&&/Ctrl\s*\+\s*P/i.test(html),'The bundled report has readable headings, print CSS and printing instructions');
      check(!/<script\b/i.test(html)&&!/\b(?:src|href)=["'](?:https?:)?\/\//i.test(html),'The printable report uses no script or remote assets');
      const beforePrint=new Set((await jobs()).map(job=>job.id));await page.locator('#print-diagnostics-button').click();
      const printable=await until(async()=>(await jobs()).find(job=>!beforePrint.has(job.id)&&job.action==='PrintDiagnostics'&&['completed','failed'].includes(job.status)),'The standalone printable report did not finish.',180000);
      check(printable.status==='completed'&&!!printable.result?.downloadUrl,'The print action creates a separate authenticated HTML report');
      const printUrl=printable.result.downloadUrl;
      await until(async()=>await page.locator('#print-support-download-link').isVisible()&&(await page.locator('#print-support-download-link').getAttribute('href')).endsWith(printUrl),'The printable report link was not retained in Support.');
      check((await page.locator('#support-download-link').getAttribute('href')).endsWith(zipUrl),'Creating a printable report preserves the existing diagnostic ZIP link');
      check((await page.locator('#print-support-download-link').getAttribute('target'))==='_blank','The print link can open independently without replacing the application');
      const printResponse=await api(printUrl);check(printResponse.ok&&/text\/html/i.test(printResponse.headers.get('content-type')||''),'The print artifact is served as HTML for browser printing');
      const printedHtml=await printResponse.text();check(/Diagnostic report/i.test(printedHtml)&&/@media\s+print/i.test(printedHtml)&&!/<script\b/i.test(printedHtml),'The standalone HTML retains the complete script-free printable report');
      const printPage=await context.newPage();await printPage.goto(new URL(printUrl,ready.url).href,{waitUntil:'domcontentloaded'});await printPage.emulateMedia({media:'print'});check((await printPage.locator('body').innerText()).includes('Diagnostic report'),'The authenticated printable page opens in the existing browser session');await printPage.screenshot({path:path.join(output,'support-print-web-demo.png'),fullPage:true});await printPage.close();
      await action({action:'Settings',theme:'Light'});await settings('support');
      check((await page.locator('#support-download-link').getAttribute('href')).endsWith(zipUrl)&&(await page.locator('#print-support-download-link').getAttribute('href')).endsWith(printUrl),'Both support links survive an unrelated completed operation and fresh snapshot');
      await page.screenshot({path:path.join(output,'support-activity-web-demo.png'),fullPage:true});verifyArchivePreserved();
    });
    await scenario('The interface remains usable at a smaller workstation size', async () => {
      await page.setViewportSize({ width: 1024, height: 768 }); await nav('reports'); await page.locator('#clear-filters').click(); await page.locator('#status-filter').selectOption('pending');
      const pending = (await waitSnapshot()).records.find(r => r.filingState==='NeedsReview'); await page.locator('.report-item[data-record-id="' + pending.id + '"]').click();
      await decisionPair('single');const rail=await page.locator('#review-control-rail').boundingBox(),documentPane=await page.locator('#pdf-area').boundingBox();check(rail&&documentPane&&rail.x+rail.width<=documentPane.x+1,'The always-visible decision rail sits to the left of the PDF at 1024 pixels');
      const approve = await page.locator('#approve-button').boundingBox(); check(approve && approve.x >= 0 && approve.x + approve.width <= 1024, 'The primary review control fits the smaller screen horizontally');
      check(approve && approve.y >= 0 && approve.y + approve.height <= 768, 'Approve stays visible without scrolling the smaller workstation window');
      const disapprove = await page.locator('#disapprove-button').boundingBox();
      check(disapprove && disapprove.y >= 0 && disapprove.y + disapprove.height <= 768, 'Disapprove stays visible beside Approve without scrolling');
      await page.screenshot({ path: path.join(output, 'reports-small-web-demo.png'), fullPage: true });
      await page.locator('#approve-button').click();
      await waitSnapshot(s => s.records.some(record => record.id === pending.id && !record.pending && /^approved$/i.test(record.decision)));
      check(true, 'A scanner connection failure does not obstruct approving another saved PDF offline');
      verifyArchivePreserved();
      check(errors.length === 0, 'No JavaScript page errors occurred'); check(externalRequests.length === 0, 'No internet asset request was attempted');
    });
  } catch (error) { if (page) try { await page.screenshot({ path: path.join(output, 'failure-web-demo.png'), fullPage: true }); } catch {} if (!results.some(r => r.result === 'FAIL')) results.push({ name: 'Test setup or completion', result: 'FAIL', details: clean(error.stack || error.message) }); process.exitCode = 1; }
  finally {
    releaseAnalysis();
    if (browser) await browser.close(); await stopHost();
    fs.writeFileSync(insightFile,originalInsights);
    const summary = { version: '5.7.0', syntheticOnly: true, browser: 'Chromium via Playwright', browserChannel: args['browser-channel'] || 'chromium', nativePdfPreviewActuallyRun: nativePreviewActuallyRun, tests: results.length, assertions, failed: results.filter(r => r.result === 'FAIL').length, externalAssetRequests: externalRequests.length, javascriptErrors: errors, results, scope: 'Actual local host, PowerShell adapter and synthetic archived PDFs. Does not establish hospital network access or workstation endpoint-policy approval.' };
    fs.writeFileSync(path.join(output, 'browser-summary.json'), JSON.stringify(summary, null, 2) + '\n');
    process.stdout.write('Result: ' + (summary.tests - summary.failed) + '/' + summary.tests + ' scenarios; ' + assertions + ' assertions.\n');
  }
})();
