/* Focused frontend browser check using a synthetic HTTP API stub.
 * Uses production web assets, but no live backend, PDFs, archive or clinical data.
 * Export checks inspect requested IDs; this stub does not create an export ZIP.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const productRoot = path.resolve(__dirname, '../..');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-calendar-monthly-browser');
const webRoot = path.join(productRoot, 'App/Web');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-calendar-monthly:' + value).digest('hex');
function report(name, date, category, extra = {}) {
  return { id: id(name), scanner: 'CT_Flash', scannerName: 'CT Flash', date,
    time: '08:00:00', filename: name + '.pdf', title: name, category,
    pending: false, decision: 'Automatic', filingState: 'Filed', stamp: id('stamp:' + name),
    isReference: false, hasReferenceEvidence: false, content: {}, ...extra };
}
const missing = [5, 14, 15];
const daily = Array.from({ length: 30 }, (_, index) => index + 1)
  .filter(day => !missing.includes(day))
  .map(day => report('SYNTHETIC_FLASH_DAILY_2026-09-' + String(day).padStart(2, '0'),
    '2026-09-' + String(day).padStart(2, '0'), 'Daily'));
const monthly = [...missing, 6].map(day => report('SYNTHETIC_FLASH_MONTHLY_2026-09-' + String(day).padStart(2, '0'),
  '2026-09-' + String(day).padStart(2, '0'), 'Monthly'));
const decoys = [
  report('SYNTHETIC_OTHER_SCANNER_MONTHLY', '2026-09-05', 'Monthly', { scanner: 'CT_Edge', scannerName: 'CT Edge' }),
  report('SYNTHETIC_PENDING_MONTHLY', '2026-09-05', 'Monthly', { pending: true, filingState: 'NeedsReview', decision: 'Pending' }),
  report('SYNTHETIC_REFERENCE_MONTHLY', '2026-09-05', 'Monthly', { isReference: true }),
  report('SYNTHETIC_REFERENCE_EVIDENCE_MONTHLY', '2026-09-05', 'Monthly', { hasReferenceEvidence: true }),
  report('SYNTHETIC_OTHER_TYPE', '2026-09-05', 'Other')
];
const snapshot = {
  version: '5.7.1', setupComplete: true, workspace: 'Synthetic browser fixture',
  archiveRoot: 'Synthetic browser fixture only', records: [...daily, ...monthly, ...decoys],
  today: { date: '2026-11-16', received: 0, expected: 1, headline: 'Synthetic frontend calendar check' },
  scanners: [
    { id: 'CT_Flash', name: 'CT Flash', dailySchedule: 'AllDays', activeFrom: '2026-09-01',
      excludedDates: [], expectedMonthly: true, status: 'Unknown', message: 'Synthetic stub; no scanner connection' },
    { id: 'CT_Edge', name: 'CT Edge', dailySchedule: 'Off', activeFrom: '2026-09-01',
      excludedDates: [], expectedMonthly: false, status: 'Unknown', message: 'Synthetic stub; no scanner connection' }
  ],
  months: [], analysis: { total: 36, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 }
};
snapshot.analysis.total = snapshot.records.length;
const originalSnapshot = JSON.stringify(snapshot);
const actionRequests = [], requests = [], jobs = [], checks = [], errors = [], externalRequests = [];
let browser, server;
const result = {
  scope: 'Synthetic HTTP API stub with production frontend assets; no live backend, PDF content, native runtime or archive validation. Export checks inspect submitted IDs only; no ZIP is created.',
  syntheticOnly: true, checks, errors, externalRequests
};
function check(condition, name) { assert.ok(condition, name); checks.push({ name, result: 'PASS' }); }
function equalIds(actual, expected, name) {
  assert.deepEqual([...actual].sort(), [...expected].sort(), name);
  check(new Set(actual).size === actual.length, name + ': no duplicate identities');
  checks.push({ name, result: 'PASS', ids: actual });
}
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
async function startServer() {
  server = http.createServer(async (request, response) => {
    const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
    requests.push({ method: request.method, pathname });
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs });
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      const action = JSON.parse(body); actionRequests.push(action);
      if (action.action !== 'Export') return json(response, { error: 'Synthetic stub only accepts Export ID inspection.' }, 400);
      const jobId = 'synthetic-export-' + actionRequests.length;
      jobs.push({ id: jobId, action: 'Export', status: 'Completed', result: { message: 'Synthetic ID inspection only; no ZIP created.' } });
      return json(response, { id: jobId }, 202);
    }
    if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    const assets = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/app.css': 'app.css', '/trends.js': 'trends.js' };
    const file = assets[pathname];
    if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
    const type = file.endsWith('.html') ? 'text/html' : file.endsWith('.css') ? 'text/css' : 'application/javascript';
    response.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    response.end(fs.readFileSync(path.join(webRoot, file)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
async function reportIds(page) {
  return page.locator('#report-list button[data-record-id]').evaluateAll(nodes => nodes.map(node => node.dataset.recordId));
}
async function openCalendar(page) {
  await page.locator('.main-nav button[data-page="reports"]').click();
  await page.locator('#reports-calendar-view').click();
  await page.locator('#calendar-month').fill('2026-09');
  await page.locator('#calendar-month').dispatchEvent('change');
  await page.locator('#calendar-scanner').selectOption('CT_Flash');
  await page.waitForFunction(() => document.querySelectorAll('#calendar-grid [data-calendar-date]').length === 30);
}
async function checkExport(page, expectedIds) {
  await page.locator('#report-export-shortcut').click();
  check(await page.locator('#export-date-filter').isVisible(), 'Export shortcut keeps the exact calendar date');
  check(Number(await page.locator('#export-count').innerText()) === expectedIds.length, 'Export preview retains the report count');
  const pendingResponse = page.waitForResponse(response => new URL(response.url()).pathname === '/api/actions');
  await page.locator('#export-button').click();
  const accepted = await (await pendingResponse).json();
  equalIds(actionRequests.at(-1).ids, expectedIds, 'Export submits the same original report IDs as the day list');
  await page.waitForResponse(async response => new URL(response.url()).pathname === '/api/jobs' &&
    (await response.json()).jobs.some(job => job.id === accepted.id && job.status === 'Completed'));
  await page.waitForFunction(() => !document.getElementById('export-button').disabled);
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
      headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, locale: 'en-US' });
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) {
        externalRequests.push(url.href); return route.abort();
      }
      return route.continue();
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push({ type: 'pageerror', message: error.message }));
    page.on('console', message => { if (message.type() === 'error') errors.push({ type: 'console', message: message.text() }); });
    await page.goto(origin + '/#session=synthetic-calendar-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(count => Number(document.getElementById('report-total').textContent) === count, snapshot.records.length);
    check(await page.locator('#error-banner').isHidden(), 'Synthetic snapshot loads without an application error');
    await openCalendar(page);
    const summary = await page.locator('#calendar-summary').innerText();
    check(summary.includes('27 of 30 scheduled Daily reports received.'), '27 synthetic Daily PDFs remain 27 of 30 Daily receipts');
    check(summary.includes('3 have no separate Daily PDF.') && summary.includes('Monthly PDFs are available for 3 of those.'), 'Summary distinguishes missing separate Daily PDFs from available Monthly PDFs');
    for (const day of missing) {
      const date = '2026-09-' + String(day).padStart(2, '0');
      const cell = page.locator('[data-calendar-date="' + date + '"]');
      check(await cell.locator('.calendar-day-status').innerText() === 'Monthly PDF available', date + ' shows Monthly PDF available');
      check((await cell.getAttribute('class')).split(' ').includes('not-received'), date + ' does not become a Daily receipt');
    }
    check(await page.locator('[data-calendar-date="2026-09-06"] .calendar-day-status').innerText() === 'Received', 'A day with Daily and Monthly PDFs retains Daily Received status');
    await page.screenshot({ path: path.join(output, 'calendar-monthly-available.png'), fullPage: true });
    result.screenshot = path.join(output, 'calendar-monthly-available.png');
    const sept5 = monthly.find(record => record.date === '2026-09-05');
    await page.locator('[data-calendar-date="2026-09-05"]').click();
    equalIds(await reportIds(page), [sept5.id], 'September 5 opens its original Monthly PDF and excludes other day/scanner/pending/reference/type records');
    check(await page.locator('#report-list .report-item-title').innerText() === sept5.filename, 'September 5 retains the original synthetic Monthly filename');
    check(await page.locator('#report-list .report-row-type').innerText() === 'Monthly QA', 'September 5 Monthly type is unchanged');
    await checkExport(page, [sept5.id]);
    await openCalendar(page);
    await page.locator('[data-calendar-date="2026-09-06"]').click();
    const combined = [...daily, ...monthly].filter(record => record.date === '2026-09-06').map(record => record.id);
    equalIds(await reportIds(page), combined, 'A shared date opens both original Daily and Monthly PDFs');
    assert.deepEqual((await page.locator('#report-list .report-row-type').allInnerTexts()).sort(), ['Daily QA', 'Monthly QA']);
    checks.push({ name: 'Shared-date PDFs retain both original file types', result: 'PASS' });
    await checkExport(page, combined);
    await openCalendar(page);
    check((await page.locator('#calendar-summary').innerText()).includes('27 of 30 scheduled Daily reports received.'), 'Daily totals remain unchanged after list and export navigation');
    check(Number(await page.locator('#report-total').innerText()) === snapshot.records.length, 'Frontend navigation preserves the original total record count');
    check(JSON.stringify(snapshot) === originalSnapshot, 'Synthetic fixture retains every original identity and category');
    check(actionRequests.length === 2 && actionRequests.every(action => action.action === 'Export'), 'Frontend sends only the two expected Export requests; no copy/create/type-change request');
    check(errors.length === 0, 'No JavaScript or browser console errors');
    check(externalRequests.length === 0, 'No external asset requests');
    result.status = 'PASS'; result.recordCount = snapshot.records.length;
    result.dailyReceiptCount = 27; result.scheduledDailyCount = 30;
  } catch (error) {
    result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1;
  } finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    result.actionRequests = actionRequests; result.requests = requests;
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length, output, scope: result.scope, failure: result.failure }, null, 2) + '\n');
  }
})();
