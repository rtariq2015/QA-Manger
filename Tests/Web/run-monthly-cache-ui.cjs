/* One focused synthetic production-web Monthly cache check.
 * Reuses the existing Monthly card fixture. Controlled local response delay is
 * illustrative only; no live archive, scanner, PDF parser or hospital speed test. */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const productRoot = path.resolve(__dirname, '../..');
const webRoot = path.join(productRoot, 'App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-monthly-cache');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-monthly-cards:' + value).digest('hex');
const sources = [
  { id: 'CT_Edge', name: 'CT Edge' },
  { id: 'CT_Flash', name: 'CT Flash' },
  { id: 'CT_Drive', name: 'MDP Building' }
];
const options = ['Noise', 'Slice', 'Homogeneity', 'ExternalLightmarker', 'TopogramPosition']
  .map(code => ({ code, label: code, aliases: [code] }));
const periods = {
  '2026-11': { receipts: [3, 1, 0], found: [2, 1, 0] },
  '2026-12': { receipts: [1, 2, 3], found: [1, 2, 3] },
  '2027-01': { receipts: [0, 0, 0], found: [0, 0, 0] },
  '2025-08': { receipts: [2, 0, 1], found: [3, 0, 1] }
};
const records = [], models = {}, latestByMonth = {};
function report(source, month, name, date, extra = {}) {
  const row = { id: id(source.id + ':' + month + ':' + name), scanner: source.id,
    scannerName: source.name, date: month + '-' + date, time: '08:00:00',
    filename: 'SYNTHETIC_' + source.id + '_' + month + '_' + name + '.pdf',
    title: 'Synthetic Monthly card fixture', category: 'Monthly', pending: false,
    decision: 'Automatic', filingState: 'Filed', stamp: id(name + ':' + month),
    isReference: false, hasReferenceEvidence: false, available: true,
    content: { status: 'NotRead' }, ...extra };
  records.push(row); return row;
}
function monthlyRow(record) {
  return { id: record.id, date: record.date, time: record.time, category: record.category,
    filingState: record.filingState, inferred: false, readStatus: record.content.status,
    available: record.available, detectedCodes: [],
    printedWarnings: record.available ? [] : ['SavedPdfUnavailable'] };
}
for (const [month, expected] of Object.entries(periods)) {
  latestByMonth[month] = {};
  const scanners = sources.map((source, index) => {
    const count = expected.receipts[index], found = expected.found[index], required = index + 3;
    const saved = Array.from({ length: count }, (_, n) => report(source, month, 'FILE_' + n,
      String(10 + Math.floor(n / 2)).padStart(2, '0'), { time: n % 2 ? '10:00:00' : '08:00:00' }));
    latestByMonth[month][source.id] = saved.at(-1) || null;
    const extra = [];
    if (month === '2026-11' && index === 0) {
      extra.push(report(source, month, 'PENDING_DECOY', '28', { pending: true, filingState: 'NeedsReview', decision: 'Pending' }));
      extra.push(report(source, month, 'UNAVAILABLE_DECOY', '27', { available: false }));
      report(source, month, 'REFERENCE_DECOY', '30', { isReference: true });
      report(source, month, 'REFERENCE_EVIDENCE_DECOY', '29', { hasReferenceEvidence: true });
      report(source, month, 'DAILY_DECOY', '30', { category: 'Daily' });
    }
    const reportRows = [...extra, ...saved].map(monthlyRow);
    return { id: source.id, name: source.name, expectedMonthly: true, applicability: 'Required',
      checklist: { effectiveMonth: '0001-01', requiredCount: required, unmatchedItems: [],
        items: options.slice(0, required).map((item, n) => ({ label: item.label, code: item.code,
          found: n < found, reportIds: n < found && saved.length ? [saved[0].id] : [] })) },
      receipt: { count, reportIds: saved.map(row => row.id), waitingCount: 0,
        reviewCount: extra.length },
      detected: { status: found === required ? 'AllItemsFound' : found ? 'Partial' : 'NoneFound',
        foundCount: found, requiredCount: required, allItemsFound: found === required,
        missingItems: options.slice(found, required).map(item => item.label),
        eligibleReportCount: count, printedWarningReportCount: 0 },
      reviewed: { status: 'Partial', confirmedReportCount: index === 0 ? 1 : 0,
        requiredComponents: options.slice(0, required).map(item => item.label),
        confirmedComponents: index === 0 ? ['Noise'] : [],
        missingComponents: options.slice(index === 0 ? 1 : 0, required).map(item => item.label) },
      due: { day: 20, date: month + '-20', timing: 'Upcoming', policy: 'CurrentConfiguration' },
      reports: reportRows, excludedReferenceCount: month === '2026-11' && index === 0 ? 2 : 0 };
  });
  models[month] = { schemaVersion: 1, month, today: '2026-11-16', reportLimit: 1000,
    limitReached: false, componentOptions: options, scanners };
}
const snapshot = { version: '5.7.16', trendsRevision: 'a'.repeat(64), setupComplete: true,
  workspace: 'Synthetic Monthly card browser fixture', archiveRoot: 'Synthetic sample only', records,
  today: { date: '2026-11-16', received: 0, expected: 3, headline: 'Synthetic frontend check' },
  scanners: sources.map((source, index) => ({ ...source, dailySchedule: 'AllDays',
    activeFrom: '2025-01-01', excludedDates: [], expectedMonthly: true,
    monthlyDueDay: 20, checklist: options.slice(0, index + 3).map(item => item.label),
    checklistEffectiveMonth: '0001-01', nextChecklistEffectiveMonth: '2026-11',
    status: 'Unknown', message: 'Synthetic sample; no connection is made' })),
  months: [], analysis: { total: records.length, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const plans = new Map(), expectedHttpFailures = [], networkTimings = [];
const responseDelayMs = 80;
const requests = [], mutations = [], pdfRequests = [], errors = [], externalRequests = [], checks = [];
const result = { syntheticOnly: true,
  scope: 'One production-web Monthly cache flow against reused synthetic snapshot/Monthly fixtures, controlled80ms HTTP delay and test-only Date.now. Checks month/scanner identities, request reuse, invalidation, cancellation/failure/retry and boundedcache behavior. No live backend, archive, scanner, PDF extraction, native runtime or hospital speed validation.',
  checks, errors, externalRequests, mutations, pdfRequests };
let browser, server;
result.sourceHashes = Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(webRoot,file))).digest('hex')]));
function check(condition, name) { assert.ok(condition, name); checks.push({ name, result: 'PASS' }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS' }); }
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
function minimalPdf() {
  const stream = 'BT /F1 16 Tf 40 180 Td (SYNTHETIC frontend selection fixture only) Tj ET';
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 240] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ' + Buffer.byteLength(stream) + ' >>\nstream\n' + stream + '\nendstream'];
  let pdf = '%PDF-1.4\n'; const offsets = [0];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(pdf)); pdf += (index + 1) + ' 0 obj\n' + object + '\nendobj\n'; });
  const xref = Buffer.byteLength(pdf);
  return Buffer.from(pdf + 'xref\n0 6\n0000000000 65535 f \n' + offsets.slice(1).map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('') +
    'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF\n');
}
async function startServer() {
  const pdf = minimalPdf();
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1'), pathname = url.pathname;
    const requestRow={method:request.method,pathname,month:url.searchParams.get('month')||undefined,startedMs:performance.now()};requests.push(requestRow);
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs: [] });
    if (pathname === '/api/monthly') {
      const month=url.searchParams.get('month'),plan=plans.get(month)||{},model=JSON.parse(JSON.stringify(models[month]||{month,today:snapshot.today.date,scanners:[],componentOptions:options}));
      response.on('close',()=>{requestRow.cancelled=!response.writableEnded;});
      await new Promise(resolve=>setTimeout(resolve,responseDelayMs));
      if(plan.gate)await plan.gate;
      if(response.destroyed){requestRow.cancelled=true;return;}
      requestRow.completedMs=performance.now();
      if(plan.failures>0){plan.failures--;expectedHttpFailures.push({month,status:503});return json(response,{error:'Synthetic controlled Monthly failure'},503);}
      if(plan.oversize)model.cacheProbePadding='x'.repeat(4*1024*1024+256);
      requestRow.responseBytes=Buffer.byteLength(JSON.stringify(model));networkTimings.push({month,elapsedMs:requestRow.completedMs-requestRow.startedMs,responseBytes:requestRow.responseBytes});
      return json(response,model);
    }
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      mutations.push({ method: request.method, body });
      return json(response, { error: 'Synthetic navigation check permits no mutation actions.' }, 400);
    }
    if (pathname.startsWith('/api/pdf/')) {
      const reportId = pathname.slice('/api/pdf/'.length);
      if (!records.some(row => row.id === reportId)) return json(response, { error: 'Unknown synthetic report' }, 404);
      pdfRequests.push(reportId); response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': pdf.length });
      return response.end(pdf);
    }
    if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    const file = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/app.css': 'app.css', '/trends.js': 'trends.js' }[pathname];
    if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
    response.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : file.endsWith('.css') ? 'text/css' : 'application/javascript' });
    response.end(fs.readFileSync(path.join(webRoot, file)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
function ensureModel(month) {
  if (models[month]) return models[month];
  const rows = sources.map((source, index) => {
    const count = index === 0 ? Number(month.slice(5)) % 2 + 1 : index === 1 ? 1 : 0;
    const saved = Array.from({ length: count }, (_, n) => report(source, month, 'CACHE_FILE_' + n, String(10 + n)));
    const model = JSON.parse(JSON.stringify(models['2026-12'].scanners[index]));
    model.receipt = { count, reportIds: saved.map(row => row.id), waitingCount: 0, reviewCount: 0 };
    model.reports = saved.map(monthlyRow); model.excludedReferenceCount = 0;
    model.detected.eligibleReportCount = count;
    model.checklist.items.forEach(item => item.reportIds = count && item.found ? [saved[0].id] : []);
    model.reviewed = { status: 'None', confirmedReportCount: 0, requiredComponents: [], confirmedComponents: [], missingComponents: [] };
    model.due.date = month + '-20'; return model;
  });
  return models[month] = { schemaVersion: 1, month, today: snapshot.today.date, reportLimit: 1000,
    limitReached: false, componentOptions: options, scanners: rows };
}
const lruMonths = Array.from({ length: 13 }, (_, index) => {
  const month = index + 1; return month <= 12 ? '2025-' + String(month).padStart(2, '0') : '2026-01';
});
for (const month of [...lruMonths, '2027-01', '2027-02', '2027-03', '2027-04', '2028-01', '2028-02', '2028-03', '2028-04', '2029-01']) ensureModel(month);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const monthlyRequests = month => requests.filter(row => row.pathname === '/api/monthly' && (!month || row.month === month));
const snapshotRequests = () => requests.filter(row => row.pathname === '/api/snapshot');
async function until(test, message, timeout = 10000) { const start = Date.now(); while (Date.now() - start < timeout) { if (await test()) return; await delay(20); } throw Error(message); }
async function settled(page, month) {
  await until(async () => await page.locator('#monthly-period').inputValue() === month &&
    await page.locator('#monthly-workspace-status').getAttribute('data-month') === month &&
    await page.locator('#monthly-workspace-status').getAttribute('data-loading') === 'false' &&
    !(await page.locator('#monthly-workspace-status').innerText()).includes('retry automatically'), month + ' did not settle.');
}
async function picker(page, month, wait = true) {
  await page.locator('#monthly-period').evaluate((node, value) => { node.value = value; node.dispatchEvent(new Event('change', { bubbles: true })); }, month);
  if (wait) await settled(page, month);
}
async function identities(page, month, name) {
  await settled(page, month);
  const selected = await page.locator('#monthly-scanner').inputValue(), expected = models[month].scanners.filter(row => selected === 'all' || row.id === selected);
  same(await page.locator('#monthly-evidence-list article[data-scanner-id]').evaluateAll(nodes => nodes.map(node => node.dataset.scannerId)), expected.map(row => row.id), name + ' preserves scanner identities');
  for (const source of expected) {
    const card = page.locator('#monthly-evidence-list article[data-scanner-id="' + source.id + '"]');
    same(await card.locator('.monthly-card-count strong').innerText(), String(source.receipt.count), name + ' preserves ' + source.id + ' receipt count');
    same((await card.locator('.monthly-report-row button[data-monthly-record-id]').evaluateAll(nodes => nodes.map(node => node.dataset.monthlyRecordId))).sort(), source.reports.map(row => row.id).sort(), name + ' preserves exact ' + source.id + ' source report IDs');
  }
}
function heldPlan(month) { let release; const gate = new Promise(resolve => release = resolve); const plan = { gate }; plans.set(month, plan); return () => { plans.delete(month); release(); }; }
async function invalidate(page, mutate, name) {
  const month = await page.locator('#monthly-period').inputValue(), before = monthlyRequests(month).length, beforeSnapshot = snapshotRequests().length;
  mutate(); await page.evaluate(() => window.__qaNow += 31000);
  await until(() => snapshotRequests().length > beforeSnapshot && monthlyRequests(month).length === before + 1, name + ' did not invalidate the selected month.');
  await settled(page, month); same(monthlyRequests(month).length, before + 1, name + ' reloads once');
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
    await context.addInitScript(() => { window.__qaNow = new Date('2026-11-17T08:00:00Z').getTime(); Date.now = () => window.__qaNow; });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); } return route.continue(); });
    const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() !== 'error') return; if (message.text().includes('503') && message.location().url.includes('/api/monthly')) return; errors.push(message.text()); });
    await page.goto(origin + '/#session=synthetic-monthly-cache-only', { waitUntil: 'networkidle' });
    await page.locator('.main-nav button[data-page="monthly"]').click();
    await identities(page, '2026-11', 'Initial November');
    same(monthlyRequests('2026-11').length, 1, 'Initial month has one cold API read');
    const coldStart = performance.now(); await page.locator('#monthly-next').click(); await identities(page, '2026-12', 'Cold December'); const coldMs = performance.now() - coldStart;
    const beforeWarm = monthlyRequests().length, warmStart = performance.now(); await page.locator('#monthly-previous').click(); await identities(page, '2026-11', 'Warm November'); const warmMs = performance.now() - warmStart;
    same(monthlyRequests().length, beforeWarm, 'A→B→A arrow return uses zero additional Monthly HTTP requests');
    const beforePicker = monthlyRequests().length; await picker(page, '2026-12'); await identities(page, '2026-12', 'Warm picker December');
    same(monthlyRequests().length, beforePicker, 'Picker reuses an already loaded month without a Monthly request');
    await picker(page, '2026-11');
    result.illustrativeTiming = { controlledResponseDelayMs: responseDelayMs, coldArrowDebounceMs: 150, coldArrowAndIdentityCheckMs: coldMs, warmArrowAndIdentityCheckMs: warmMs,
      note: 'One local synthetic observation including browser/DOM checks. Request elimination is asserted; these timings are not a reader or hospital workstation speed benchmark.' };
    const releaseJanuary = heldPlan('2027-01'); await picker(page, '2027-01', false);
    await until(() => monthlyRequests('2027-01').length === 1, 'Held January read did not start.');
    await page.locator('#monthly-scanner-tabs button[data-scanner-id="CT_Flash"]').click(); await delay(190);
    same(monthlyRequests('2027-01').length, 1, 'Changing scanner in the same in-flight month does not duplicate its API request');
    check(monthlyRequests('2027-01')[0].cancelled !== true, 'Changing only scanner does not cancel the shared in-flight model');
    releaseJanuary(); await identities(page, '2027-01', 'January selected scanner');
    same(await page.locator('#monthly-scanner').inputValue(), 'CT_Flash', 'Scanner choice is preserved when the shared response arrives');
    await page.locator('#monthly-scanner-tabs button[data-scanner-id="all"]').click();
    const releaseFebruary = heldPlan('2027-02'); await picker(page, '2027-02', false);
    await until(() => monthlyRequests('2027-02').length === 1, 'Held February read did not start.');
    const beforeLateReturn = monthlyRequests().length; await picker(page, '2026-11');
    same(monthlyRequests().length, beforeLateReturn, 'Leaving an in-flight month can restore a warm month immediately without fetching');
    releaseFebruary(); await delay(140); await identities(page, '2026-11', 'After cancelled late response');
    check(monthlyRequests('2027-02')[0].cancelled === true, 'Navigation away cancels the obsolete month request');
    await picker(page, '2027-02');
    same(monthlyRequests('2027-02').length, 2, 'Cancelled/late response is not inserted as a successful cached model');
    plans.set('2027-03', { failures: 1 }); await picker(page, '2027-03', false);
    await until(async () => (await page.locator('#monthly-workspace-status').innerText()).includes('retry automatically'), 'Failed month did not show retry guidance.');
    await picker(page, '2026-11'); await picker(page, '2027-03');
    same(monthlyRequests('2027-03').length, 2, 'A failed month is fetched again instead of cached as success');
    await identities(page, '2027-03', 'Successful retry after navigation');
    plans.set('2027-04', { failures: 1 }); await picker(page, '2027-04', false);
    await until(async () => (await page.locator('#monthly-workspace-status').innerText()).includes('retry automatically'), 'Stay-in-month failure did not show automatic retry guidance.');
    await page.evaluate(() => window.__qaNow += 31000); await settled(page, '2027-04');
    same(monthlyRequests('2027-04').length, 2, 'Existing due-interval retry still recovers an uncached failed month');
    await picker(page, '2028-01'); const beforeRapid = monthlyRequests().length;
    await page.locator('#monthly-next').evaluate(node => { node.click(); node.click(); node.click(); }); await settled(page, '2028-04');
    same(monthlyRequests().slice(beforeRapid).map(row => row.month), ['2028-04'], 'Rapid uncached arrow changes read only the final month after debounce');
    await picker(page, '2026-11'); await picker(page, '2026-12'); await picker(page, '2026-11');
    const beforeDataB = monthlyRequests('2026-12').length;
    await invalidate(page, () => records[0].stamp = id('changed-synthetic-record-stamp'), 'Saved record change');
    await picker(page, '2026-12'); same(monthlyRequests('2026-12').length, beforeDataB + 1, 'Saved data change invalidates a previously warm alternate month');
    await picker(page, '2026-11'); const beforeConfigB = monthlyRequests('2026-12').length;
    await invalidate(page, () => snapshot.scanners[0].monthlyDueDay = 21, 'Scanner configuration change');
    await picker(page, '2026-12'); same(monthlyRequests('2026-12').length, beforeConfigB + 1, 'Configuration change invalidates a previously warm alternate month');
    await picker(page, '2026-11'); const beforeArchiveB = monthlyRequests('2026-12').length, beforeArchiveA = monthlyRequests('2026-11').length;
    plans.set('2026-11', { failures: 1 }); snapshot.archiveRoot = 'Synthetic alternate archive'; snapshot.libraryRoot = 'Synthetic alternate archive/Report Library';
    await page.evaluate(() => window.__qaNow += 31000);
    await until(async () => monthlyRequests('2026-11').length === beforeArchiveA + 1 && (await page.locator('#monthly-workspace-status').innerText()).includes('retry automatically'), 'Controlled archive-change refresh did not fail as planned.');
    same(await page.locator('#monthly-evidence-list article[data-scanner-id]').count(), 0, 'Failed archive-identity reload never displays cards from the prior archive');
    same(await page.locator('#monthly-receipt-count').innerText(), '—', 'Failed archive-identity reload does not retain stale receipt totals');
    await page.evaluate(() => window.__qaNow += 31000); await settled(page, '2026-11');
    same(monthlyRequests('2026-11').length, beforeArchiveA + 2, 'Archive identity change retries its new model successfully');
    await picker(page, '2026-12'); same(monthlyRequests('2026-12').length, beforeArchiveB + 1, 'Archive identity change invalidates a previously warm alternate month');
    for (const month of lruMonths.slice(0, 12)) await picker(page, month);
    const firstBefore = monthlyRequests(lruMonths[0]).length; await picker(page, lruMonths[0]);
    same(monthlyRequests(lruMonths[0]).length, firstBefore, 'Recent twelve-month cache retains its oldest entry before pressure');
    await picker(page, lruMonths[12]); await picker(page, lruMonths[0]);
    same(monthlyRequests(lruMonths[0]).length, firstBefore, 'A recently touched month survives the thirteenth distinct month');
    const evictedBefore = monthlyRequests(lruMonths[1]).length; await picker(page, lruMonths[1]);
    same(monthlyRequests(lruMonths[1]).length, evictedBefore + 1, 'The least recently used month is evicted at the twelve-month bound');
    plans.set('2029-01', { oversize: true }); await picker(page, '2029-01'); await picker(page, lruMonths[0]); await picker(page, '2029-01');
    same(monthlyRequests('2029-01').length, 2, 'An oversized serialized response remains usable but is not retained for warm navigation');
    check(monthlyRequests('2029-01').every(row => row.responseBytes > 4 * 1024 * 1024), 'Oversize probe really exceeds the four-MiB cache budget');
    const beforeExpired = monthlyRequests(lruMonths[0]).length;
    await page.evaluate(() => window.__qaNow += 300001); await picker(page, lruMonths[0]);
    same(monthlyRequests(lruMonths[0]).length, beforeExpired + 1, 'Five-minute freshness expiry refetches an otherwise warm month');
    same(mutations, [], 'Month caching and invalidation never submit scanner Refresh or another mutation');
    same(pdfRequests, [], 'Monthly navigation never opens or re-parses a PDF');
    same(errors, [], 'No unexpected browser or route errors'); same(externalRequests, [], 'No external requests');
    result.status = 'PASS'; result.assertions = checks.length; result.requests = requests; result.networkTimings = networkTimings; result.expectedHttpFailures = expectedHttpFailures;
    console.log('PASS focused Monthly cache flow: ' + checks.length + ' checks.');
  } catch (error) { result.status = 'FAIL'; result.error = error.stack; console.error(error.stack); process.exitCode = 1; }
  finally { result.sourceHashesAtEnd = Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(webRoot,file))).digest('hex')])); try { assert.deepEqual(result.sourceHashesAtEnd,result.sourceHashes); result.sourceHashesStable=true; } catch(error) { result.status='FAIL'; result.error='Production web files changed during the focused flow: '+error.message; process.exitCode=1; } result.testedFiles = Object.fromEntries(Object.entries(result.sourceHashesAtEnd).map(([name,sha])=>['App/Web/'+name,sha])); fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n'); if (browser) await browser.close(); if (server) { server.closeAllConnections?.(); await new Promise(resolve => server.close(resolve)); } }
})();
