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
  page.on('request', request => { const pathname = new URL(request.url()).pathname; if (pathname.startsWith('/api/preview/')) previewRequests.push(pathname); });
  page.on('dialog', async dialog => { dialogs.push(dialog.type()); await dialog.dismiss(); });
  await page.goto(ready.url + '#session=' + encodeURIComponent(ready.token), { waitUntil: 'domcontentloaded' });
  await page.locator('#refresh-button').waitFor({ state: 'visible' });
  await until(async () => !(await page.locator('#refresh-button').isDisabled()), 'The browser did not load the saved snapshot.');
}
async function nav(name) { await page.locator('.main-nav button[data-page="' + name + '"]').click(); }
async function selectPending(recordId) {
  await nav('reports');
  await page.locator('#clear-filters').click();
  await page.locator('#status-filter').selectOption('pending');
  await page.locator('.report-item[data-record-id="' + recordId + '"]').click();
  await until(async () => (await page.locator('#pdf-frame').isVisible()) || (await page.locator('#pdf-image').isVisible()), 'The selected PDF preview did not become visible.');
  if (await page.locator('#pdf-image').isVisible()) await until(() => page.locator('#pdf-image').evaluate(image => image.complete && image.naturalWidth > 0), 'The native PDF page image did not load.');
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
    await startHost();
    await scenario('The local API rejects missing authentication, hostile origins and arbitrary actions', async () => {
      let response = await api('/api/snapshot', {}, false); check([401, 403].includes(response.status), 'Saved data is inaccessible without the session token');
      response = await api('/api/actions', { method: 'POST', headers: { Origin: 'https://untrusted.invalid', 'Content-Type': 'application/json' }, body: '{"action":"Refresh"}' }); check(response.status === 403, 'A different origin cannot invoke local actions');
      response = await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"RunShell","command":"not executed"}' }); check(response.status === 400, 'An arbitrary shell action is rejected');
      response = await api('/api/pdf/not-a-report'); check(response.status === 400, 'PDF access requires a report ID');
      before = await waitSnapshot(); chosen = before.records.find(record => record.pending && record.scanner === 'CT_Edge' && /monthly/i.test(record.category)); check(!!chosen, 'The real imported fixture includes a pending Monthly report');
    });
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (args['browser-channel']) launchOptions.channel = args['browser-channel'];
    else launchOptions.executablePath = args.chromium || process.env.CHROMIUM_PATH || '/usr/bin/chromium';
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, acceptDownloads: true });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) { externalRequests.push(url.hostname); route.abort(); } else route.continue(); });
    await scenario('The three-screen interface loads locally without external assets', async () => {
      await loadBrowserPage();
      check(await page.locator('.main-nav button[data-page]').count() === 3, 'Only Today, Reports and Settings appear as primary navigation');
      await page.screenshot({ path: path.join(output, 'today-web-demo.png'), fullPage: true });
      await nav('settings'); await page.locator('#connection-scanner').waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'settings-web-demo.png'), fullPage: true });
      await selectPending(chosen.id);
      check(await page.locator('#review-actions input, #review-actions textarea, #review-actions select').count() === 0, 'Pending review has no name, reason or authorization field');
      check(await page.locator('#review-actions button').count() === 2, 'Pending review has exactly Approve and Disapprove as its primary actions');
      await delay(4000);
      await page.screenshot({ path: path.join(output, 'reports-web-demo.png'), fullPage: true });
      check(externalRequests.length === 0, 'All requested interface assets came from the local host');
    });
    await scenario('Normal mouse-release clicks keep settings and search fields focused for real keyboard input', async () => {
      await nav('settings');
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
      await nav('settings');
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
      await page.locator('#diagnostics-button').click();
      await until(async () => (await jobs()).some(job => !previousJobs.has(job.id) && job.action === 'Diagnostics' && job.status === 'completed'), 'The unrelated diagnostics job did not finish.', 180000);
      await until(() => browserSnapshots > 0, 'The browser did not refresh its saved snapshot after diagnostics');
      await until(async () => !(await page.locator('#connect-button').isDisabled()), 'The connection form did not become available after diagnostics');
      page.off('response', observeSnapshot);
      check((await page.locator('#connection-path').inputValue()) === draftPath, 'Pasted folder draft survives blur and the unrelated job snapshot');
      check((await page.locator('#connection-username').inputValue()) === draftUsername, 'Typed username survives blur and the unrelated job snapshot');
      check((await page.locator('#connection-password').inputValue()) === secret, 'Same-scanner snapshot rendering does not erase an unsaved password');
      await nav('today'); await nav('settings');
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
        check(source && source.startsWith('data:image/png;base64,'), 'The native review preview is an actual decoded PNG');
        const bytes = Buffer.from(source.split(',')[1], 'base64');
        check(bytes.subarray(0, 8).toString('hex') === '89504e470d0a1a0a', 'The preview page has a PNG signature');
        check(previewRequests.includes('/api/preview/' + chosen.id), 'The rendered preview was requested for the selected report ID');
        check(await page.locator('#preview-previous-page').isDisabled() && await page.locator('#preview-next-page').isDisabled(), 'One-page synthetic PDFs do not offer nonexistent pages');
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
      await page.locator('#export-button').click();
      await until(async () => (await jobs()).some(j => j.action === 'Export' && j.status === 'completed'), 'The report ZIP did not finish.', 180000);
      const job = (await jobs()).find(j => j.action === 'Export' && j.status === 'completed');
      check(!!job.result?.downloadUrl, 'A completed export exposes an authenticated download');
      const response = await api(job.result.downloadUrl); check(response.ok, 'The exported ZIP can be downloaded');
      const destination = path.join(output, 'synthetic-filtered-export.zip'); fs.writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
      const verification = JSON.parse(execFileSync(args.python || (process.platform === 'win32' ? 'python' : 'python3'), ['-c', 'import json,zipfile,sys,hashlib;z=zipfile.ZipFile(sys.argv[1]);pdf=[i for i in z.namelist() if i.lower().endswith(".pdf")];print(json.dumps({"pdfs":len(pdf),"hashes":[hashlib.sha256(z.read(i)).hexdigest().upper() for i in pdf],"summary":any(i.endswith(".html") for i in z.namelist())}))', destination], { encoding: 'utf8' }));
      check(verification.pdfs === expected.length && verification.summary, 'The ZIP includes exactly the filtered PDFs and an offline summary');
      check(verification.hashes.every(hash => expected.some(r => baseline.Records.find(b => b.Id === r.id).Hash === hash)), 'Every exported PDF retains its original fingerprint');
    });
    await scenario('Saved organization decisions survive a full host restart', async () => {
      if (!args.host) { check(false, 'Supply --host for the required restart persistence regression'); }
      const oldToken = ready.token; await stopHost(); await startHost();
      check(oldToken !== ready.token, 'A restarted host gets a fresh authentication token');
      const oldResponse = await api('/api/snapshot', { headers: { 'X-Qa-Session': oldToken } }); check(oldResponse.status === 401, 'The previous process token cannot access the restarted host');
      const after = await waitSnapshot(); check(after.records.some(r => r.id === chosen.id && !r.pending && /^disapproved$/i.test(r.decision)), 'The saved Disapprove state survives a new process');
      await loadBrowserPage(); await nav('reports'); await page.locator('#status-filter').selectOption('disapproved');
      await page.locator('.report-item[data-record-id="' + chosen.id + '"]').waitFor({ state: 'visible' });
      check(await page.locator('#undo-button').isVisible(), 'Undo remains available from persisted last-decision metadata');
      verifyArchivePreserved();
    });
    await scenario('Connection failures remain visible and job records do not expose entered passwords', async () => {
      await nav('settings'); await page.locator('#connection-scanner').selectOption(chosen.scanner);
      const canary = 'Synthetic test password - not a real credential';
      await page.locator('#connection-password').fill(canary);
      await page.locator('#remember-credentials').uncheck();
      await page.locator('#connect-button').click();
      const job = await until(async () => (await jobs()).find(j => j.action === 'Reconnect' && ['completed', 'failed'].includes(j.status)), 'The synthetic connection test did not finish.', 180000);
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
    await scenario('The interface remains usable at a smaller workstation size', async () => {
      await page.setViewportSize({ width: 1024, height: 768 }); await nav('reports'); await page.locator('#clear-filters').click(); await page.locator('#status-filter').selectOption('pending');
      const pending = (await waitSnapshot()).records.find(r => r.pending); await page.locator('.report-item[data-record-id="' + pending.id + '"]').click();
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
    if (browser) await browser.close(); await stopHost();
    const summary = { version: '5.0.1', syntheticOnly: true, browser: 'Chromium via Playwright', browserChannel: args['browser-channel'] || 'chromium', nativePdfPreviewActuallyRun: nativePreviewActuallyRun, tests: results.length, assertions, failed: results.filter(r => r.result === 'FAIL').length, externalAssetRequests: externalRequests.length, javascriptErrors: errors, results, scope: 'Actual local host, PowerShell adapter and synthetic archived PDFs. Does not establish hospital network access or workstation endpoint-policy approval.' };
    fs.writeFileSync(path.join(output, 'browser-summary.json'), JSON.stringify(summary, null, 2) + '\n');
    process.stdout.write('Result: ' + (summary.tests - summary.failed) + '/' + summary.tests + ' scenarios; ' + assertions + ' assertions.\n');
  }
})();
