/* One focused frontend browser check with synthetic HTTP API/PDF stubs.
 * Production web assets are exercised. No live backend, archive, scanner,
 * clinical PDF content, parser, native runtime or mutations are exercised.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const productRoot = path.resolve(__dirname, '../..');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-today-shortcuts-browser');
const webRoot = path.join(productRoot, 'App/Web');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-today-shortcuts:' + value).digest('hex');
function report(name, scanner, date, time, category, extra = {}) {
  return { id: id(name), scanner, scannerName: scanner.replace('_', ' '), date, time,
    filename: name + '.pdf', title: name, category, pending: false, decision: 'Automatic',
    filingState: 'Filed', stamp: id('stamp:' + name), isReference: false,
    hasReferenceEvidence: false, content: {}, ...extra };
}
const edgeDaily = report('SYNTHETIC_EDGE_DAILY_LATEST', 'CT_Edge', '2026-09-15', '10:00:00', 'Daily');
const edgeDailyEarlier = report('SYNTHETIC_EDGE_DAILY_EARLIER_SESSION', 'CT_Edge', '2026-09-15', '08:00:00', 'Daily');
const flashDaily = report('SYNTHETIC_FLASH_DAILY_LATEST', 'CT_Flash', '2026-09-14', '11:00:00', 'Daily');
const driveDaily = report('SYNTHETIC_DRIVE_DAILY_LATEST', 'CT_Drive', '2026-09-15', '09:00:00', 'Daily');
const edgeMonthly = report('SYNTHETIC_EDGE_MONTHLY_LATEST', 'CT_Edge', '2026-09-15', '10:00:00', 'Monthly');
const records = [
  edgeDailyEarlier, flashDaily, edgeMonthly, driveDaily, edgeDaily,
  report('SYNTHETIC_EDGE_MONTHLY_EARLIER_SESSION', 'CT_Edge', '2026-09-15', '08:00:00', 'Monthly'),
  report('SYNTHETIC_EDGE_MONTHLY_OLDER', 'CT_Edge', '2026-09-10', '11:00:00', 'Monthly'),
  report('SYNTHETIC_FLASH_MONTHLY_PRIOR_MONTH', 'CT_Flash', '2026-08-31', '10:00:00', 'Monthly'),
  report('SYNTHETIC_OLD_DAILY', 'CT_Flash', '2025-08-31', '10:00:00', 'Daily')
];
for (const scanner of ['CT_Edge', 'CT_Flash', 'CT_Drive']) {
  records.push(
    report('SYNTHETIC_' + scanner + '_DAILY_FUTURE', scanner, '2026-09-17', '12:00:00', 'Daily'),
    report('SYNTHETIC_' + scanner + '_DAILY_PENDING', scanner, '2026-09-16', '12:00:00', 'Daily', { pending: true, filingState: 'NeedsReview', decision: 'Pending' }),
    report('SYNTHETIC_' + scanner + '_DAILY_REFERENCE', scanner, '2026-09-16', '11:00:00', 'Daily', { isReference: true }),
    report('SYNTHETIC_' + scanner + '_DAILY_REFERENCE_EVIDENCE', scanner, '2026-09-16', '10:00:00', 'Daily', { hasReferenceEvidence: true })
  );
}
records.push(
  report('SYNTHETIC_EDGE_MONTHLY_FUTURE', 'CT_Edge', '2026-09-17', '12:00:00', 'Monthly'),
  report('SYNTHETIC_FLASH_MONTHLY_PENDING', 'CT_Flash', '2026-09-16', '12:00:00', 'Monthly', { pending: true, filingState: 'NeedsReview', decision: 'Pending' }),
  report('SYNTHETIC_FLASH_MONTHLY_REFERENCE', 'CT_Flash', '2026-09-16', '11:00:00', 'Monthly', { isReference: true }),
  report('SYNTHETIC_FLASH_MONTHLY_REFERENCE_EVIDENCE', 'CT_Flash', '2026-09-16', '10:00:00', 'Monthly', { hasReferenceEvidence: true })
);
const snapshot = {
  version: '5.7.3', setupComplete: true, workspace: 'Synthetic frontend fixture',
  archiveRoot: 'Synthetic frontend fixture only', records,
  today: { date: '2026-09-16', received: 0, expected: 3,
    headline: 'Synthetic Today shortcuts check',
    scanners: ['CT_Edge', 'CT_Flash', 'CT_Drive'].map(scanner => ({ scanner, received: false, required: true, dailyStatus: 'Awaiting today’s report' })) },
  scanners: ['CT_Edge', 'CT_Flash', 'CT_Drive'].map(scanner => ({ id: scanner,
    name: scanner.replace('_', ' '), dailySchedule: 'AllDays', activeFrom: '2025-01-01',
    excludedDates: [], expectedMonthly: true, status: 'Unknown',
    message: 'Synthetic fixture; no connection is made' })),
  months: [], analysis: { total: records.length, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 }
};
const original = JSON.stringify(snapshot);
const requests = [], mutationRequests = [], pdfRequests = [], errors = [], externalRequests = [], checks = [];
const result = { syntheticOnly: true,
  scope: 'Production frontend assets with synthetic snapshot/jobs/Monthly API and a minimal synthetic PDF. Checks establish frontend navigation and selected report identities only; no real backend, archive, scanner, PDF reading or clinical QA validation.',
  checks, errors, externalRequests, mutationRequests, pdfRequests };
let browser, server;
function check(value, name) { assert.ok(value, name); checks.push({ name, result: 'PASS' }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS', actual }); }
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
function minimalPdf() {
  const stream = 'BT /F1 16 Tf 40 180 Td (SYNTHETIC frontend selection fixture only) Tj ET';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 240] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ' + Buffer.byteLength(stream) + ' >>\nstream\n' + stream + '\nendstream'
  ];
  let pdf = '%PDF-1.4\n'; const offsets = [0];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(pdf)); pdf += (index + 1) + ' 0 obj\n' + object + '\nendobj\n'; });
  const xref = Buffer.byteLength(pdf);
  pdf += 'xref\n0 6\n0000000000 65535 f \n' + offsets.slice(1).map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('');
  pdf += 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF\n';
  return Buffer.from(pdf);
}
async function startServer() {
  const pdf = minimalPdf();
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1'), pathname = url.pathname;
    requests.push({ method: request.method, pathname });
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs: [] });
    if (pathname === '/api/monthly') return json(response, { month: url.searchParams.get('month'), today: snapshot.today.date, scanners: [], componentOptions: [] });
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      mutationRequests.push(body); return json(response, { error: 'No mutations are allowed in this synthetic navigation check.' }, 400);
    }
    if (pathname.startsWith('/api/pdf/')) {
      const reportId = pathname.slice('/api/pdf/'.length);
      if (!records.some(record => record.id === reportId)) return json(response, { error: 'Unknown synthetic report' }, 404);
      pdfRequests.push(reportId);
      response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': pdf.length });
      return response.end(pdf);
    }
    if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    const assets = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/app.css': 'app.css', '/trends.js': 'trends.js' };
    const file = assets[pathname];
    if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
    response.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : file.endsWith('.css') ? 'text/css' : 'application/javascript' });
    response.end(fs.readFileSync(path.join(webRoot, file)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
const card = (page, scanner) => page.locator('#scanner-cards .scanner-card[data-scanner-id="' + scanner + '"]');
async function today(page) { await page.locator('.main-nav button[data-page="today"]').click(); }
async function selection(page, record) {
  await page.waitForFunction(reportId => document.getElementById('pdf-area').dataset.recordId === reportId, record.id);
  same(await page.locator('body').getAttribute('data-page'), 'review', 'Shortcut opens the existing report preview');
  same(await page.locator('#pdf-frame').getAttribute('src'), '/api/pdf/' + record.id, 'Preview targets the expected original synthetic report ID');
  same(await page.locator('#open-pdf-link').getAttribute('href'), '/api/pdf/' + record.id, 'Open PDF link agrees with the selected report');
}
async function library(page) {
  check(await page.locator('#reports-library-panel').isVisible() && await page.locator('#daily-calendar').isHidden(), 'Open library always opens the list and closes the receipt calendar');
  same(await page.locator('#type-filter').inputValue(), 'daily', 'Open library selects Daily reports');
  for (const name of ['scanner', 'year', 'month', 'status']) same(await page.locator('#' + name + '-filter').inputValue(), 'all', 'Open library resets the stale ' + name + ' filter');
  same(await page.locator('#report-search').inputValue(), '', 'Open library clears stale search text');
  check(await page.locator('#report-date-filter').isVisible(), 'Latest Daily date filter is visible');
  const label = await page.locator('#report-date-label').innerText();
  check(label.includes('Sep 15, 2026') && !label.includes('Calendar day'), 'Latest eligible global Daily date replaces the calendar receipt scope');
  same(await page.locator('#report-list button[data-record-id]').evaluateAll(nodes => nodes.map(node => node.dataset.recordId)),
    [edgeDaily.id, driveDaily.id, edgeDailyEarlier.id], 'Latest Daily date is listed newest first across scanners');
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, locale: 'en-US' });
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); }
      return route.continue();
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push({ type: 'pageerror', message: error.message }));
    page.on('console', message => { if (message.type() === 'error') errors.push({ type: 'console', message: message.text() }); });
    await page.goto(origin + '/#session=synthetic-today-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(count => Number(document.getElementById('report-total').textContent) === count, records.length);
    check(await page.locator('#error-banner').isHidden(), 'Synthetic Today snapshot loads without an application error');
    check((await card(page, 'CT_Edge').locator('.scanner-daily-link').innerText()).includes('Open latest PDF · Sep 15, 2026'), 'Daily card clearly dates its previous-day fallback');
    check(await card(page, 'CT_Edge').locator('.scanner-monthly-link').isEnabled(), 'Current snapshot-month Monthly receipt is an enabled link');
    check((await card(page, 'CT_Edge').locator('.scanner-monthly-link').innerText()).includes('Monthly PDF received'), 'Received Monthly PDF is labelled as a file receipt');
    for (const scanner of ['CT_Flash', 'CT_Drive']) {
      const link = card(page, scanner).locator('.scanner-monthly-link');
      check(await link.isDisabled(), scanner + ' Monthly link remains disabled for missing or prior/pending/reference-only evidence');
      const label = await link.innerText();
      check(label.includes('×') && label.includes('No Monthly PDF yet') && label.includes('September 2026'), scanner + ' missing Monthly state has a cross and the snapshot month');
    }
    await page.screenshot({ path: path.join(output, 'today-shortcuts.png'), fullPage: true });
    result.screenshot = path.join(output, 'today-shortcuts.png');

    await page.locator('.main-nav button[data-page="reports"]').click();
    await page.locator('#scanner-filter').selectOption('CT_Flash');
    await page.locator('#year-filter').selectOption('2025');
    await page.locator('#month-filter').selectOption('08');
    await page.locator('#type-filter').selectOption('monthly');
    await page.locator('#status-filter').selectOption('pending');
    await page.locator('#report-search').fill('STALE SYNTHETIC QUERY');
    await page.locator('#reports-calendar-view').click();
    await today(page);
    await page.locator('#today-library-button').click();
    await library(page);

    await today(page);
    await page.locator('#today-calendar-button').click();
    await page.locator('#calendar-month').fill('2026-08');
    await page.locator('#calendar-month').dispatchEvent('change');
    await page.locator('#calendar-scanner').selectOption('CT_Flash');
    await page.locator('[data-calendar-date="2026-08-31"]').click();
    check((await page.locator('#report-date-label').innerText()).includes('Calendar day'), 'Fixture establishes a real stale calendar-day filter');
    await today(page);
    await page.locator('#today-library-button').focus();
    await page.keyboard.press('Enter');
    await library(page);

    for (const record of [edgeDaily, flashDaily, driveDaily]) {
      await today(page);
      const link = card(page, record.scanner).locator('.scanner-daily-link');
      if (record === edgeDaily) { await link.focus(); await page.keyboard.press('Enter'); }
      else await link.click();
      await selection(page, record);
    }
    await today(page);
    const monthlyLink = card(page, 'CT_Edge').locator('.scanner-monthly-link');
    await monthlyLink.focus(); await page.keyboard.press('Space');
    await selection(page, edgeMonthly);
    check(await page.locator('#pdf-area').getAttribute('data-record-id') !== edgeDaily.id, 'Monthly activation opens Monthly without triggering the Daily shortcut');
    await today(page);
    await page.locator('.main-nav button[data-page="monthly"]').click();
    await page.waitForFunction(() => document.getElementById('monthly-workspace-status').dataset.loading === 'false');
    check(await page.locator('#page-monthly').isVisible(), 'The main Monthly tab remains available');
    check(await page.locator('#error-banner').isHidden(), 'Shortcut navigation finishes without an application error');
    check(mutationRequests.length === 0, 'Shortcut navigation sends no mutation action requests');
    check(JSON.stringify(snapshot) === original, 'Synthetic original report identities and file types remain unchanged');
    check(errors.length === 0, 'No JavaScript or browser console errors');
    check(externalRequests.length === 0, 'No external asset requests');
    result.status = 'PASS';
  } catch (error) { result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1; }
  finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    result.requests = requests;
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length, output, scope: result.scope, failure: result.failure }, null, 2) + '\n');
  }
})();
