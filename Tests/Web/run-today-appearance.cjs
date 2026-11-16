/* Development-only appearance check using production frontend assets and static
 * synthetic HTTP/PDF responses. No live backend, archive, scanner, PDF reading,
 * native runtime, clinical QA validation, mutations or broad functional flow.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const webRoot = path.resolve(__dirname, '../../App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-today-appearance');
fs.mkdirSync(output, { recursive: true });
const fixtureDate = '2026-11-16';
const month = fixtureDate.slice(0, 7);
const sources = [{ id: 'CT_Edge', name: 'CT Edge' }, { id: 'CT_Flash', name: 'CT Flash' },
  { id: 'CT_Drive', name: 'CT Drive' }];
const id = value => crypto.createHash('sha256').update('synthetic-today-appearance:' + value).digest('hex');
const records = [];
for (const [index, scanner] of sources.entries()) {
  for (const category of ['Daily', 'Monthly']) {
    const count = category === 'Daily' ? 1 : [3, 1, 1][index];
    for (let n = 0; n < count; n++) {
      const name = 'SYNTHETIC_' + scanner.id + '_' + category.toUpperCase() + '_' + n;
      records.push({ id: id(name), scanner: scanner.id, scannerName: scanner.name,
        date: category === 'Daily' ? fixtureDate : month + '-' + String(10 + n).padStart(2, '0'),
        time: '08:00:00', filename: name + '.pdf', title: 'Synthetic appearance fixture',
        category, pending: false, decision: 'Automatic', filingState: 'Filed', stamp: id(name + ':stamp'),
        isReference: false, hasReferenceEvidence: false, available: true,
        content: { status: 'Read', completeRead: true, pages: 1, readPages: 1 } });
    }
  }
}
const snapshot = { version: '5.7.5', setupComplete: true, workspace: 'Synthetic appearance fixture',
  archiveRoot: 'Synthetic sample only', records,
  today: { date: fixtureDate, received: 3, expected: 3, headline: 'All Daily reports received',
    scanners: sources.map(source => ({ scanner: source.id, received: true, required: true,
      dailyStatus: 'Daily report received' })) },
  scanners: sources.map(source => ({ ...source, dailySchedule: 'AllDays', activeFrom: '2025-01-01',
    excludedDates: [], expectedMonthly: true, monthlyDueDay: 20, checklist: ['Noise', 'Slice'],
    checklistEffectiveMonth: '0001-01', status: 'Connected', message: 'Synthetic sample; no connection is made' })),
  months: [], analysis: { total: records.length, cached: records.length, pending: 0,
    errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const checks = [], errors = [], externalRequests = [], mutationRequests = [], pdfRequests = [];
const result = { syntheticOnly: true,
  scope: 'Development appearance check: production frontend with static synthetic snapshot/Monthly/jobs responses and a minimal sample PDF. Desktop light/dark, one narrow viewport and three existing navigation targets only. No live backend, archive, scanner, PDF extraction, native runtime or clinical QA validation.',
  checks, errors, externalRequests, mutationRequests, pdfRequests, screenshots: [] };
let browser, server;
function check(value, name) { assert.ok(value, name); checks.push({ name, result: 'PASS' }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS' }); }
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
function minimalPdf() {
  const stream = 'BT /F1 16 Tf 40 180 Td (SYNTHETIC frontend fixture only) Tj ET';
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
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs: [] });
    if (pathname === '/api/monthly') return json(response, { month: url.searchParams.get('month'),
      today: fixtureDate, scanners: [], componentOptions: [] });
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      mutationRequests.push(body); return json(response, { error: 'Synthetic check permits no mutations.' }, 400);
    }
    if (pathname.startsWith('/api/pdf/')) {
      const reportId = pathname.slice('/api/pdf/'.length);
      if (!records.some(row => row.id === reportId)) return json(response, { error: 'Unknown synthetic report' }, 404);
      pdfRequests.push(reportId);
      response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': pdf.length });
      return response.end(pdf);
    }
    if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    const file = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js',
      '/app.css': 'app.css', '/trends.js': 'trends.js' }[pathname];
    if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
    response.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : file.endsWith('.css') ? 'text/css' : 'application/javascript' });
    response.end(fs.readFileSync(path.join(webRoot, file)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
const scannerCard = (page, source) => page.locator('#scanner-cards article.scanner-card[data-scanner-id="' + source.id + '"]');
const monthlyCard = (page, source) => scannerCard(page, source).locator('.today-monthly-block');
async function screenshot(page, name) {
  const filename = path.join(output, name);
  await page.screenshot({ path: filename, fullPage: true }); result.screenshots.push(filename);
}
async function actionAvailable(page, selector) {
  const action = page.locator(selector);
  await action.scrollIntoViewIfNeeded();
  check(await action.isVisible() && await action.isEnabled(), selector + ' is visible and enabled at 1024px');
  await action.focus();
  check(await action.evaluate(node => node === document.activeElement && node.getBoundingClientRect().left >= 0 &&
    node.getBoundingClientRect().right <= innerWidth), selector + ' is keyboard focusable and inside the narrow viewport');
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
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await page.goto(origin + '/#session=synthetic-appearance-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(count => Number(document.getElementById('report-total').textContent) === count, records.length);
    same(await page.locator('#scanner-cards .scanner-daily-link').count(), 3, 'Today keeps three Daily shortcuts');
    check((await page.locator('#scanner-cards').innerText()).includes('Daily report received'), 'Daily receipt labels remain');
    same(await page.locator('#scanner-cards .today-monthly-block').count(), 3, 'Today keeps Monthly directly inside each scanner card');
    for (const [index, source] of sources.entries()) {
      same(await scannerCard(page, source).locator('h3').count(), 1, source.name + ' has one shared scanner name');
      same(await scannerCard(page, source).locator('.scanner-icon').count(), 1, source.name + ' has one shared scanner image');
      same(await monthlyCard(page, source).locator('.monthly-card-heading').count(), 0, source.name + ' Monthly block does not repeat the scanner heading');
      const dailyBounds = await scannerCard(page, source).locator('.scanner-daily-link').boundingBox();
      const monthlyBounds = await monthlyCard(page, source).boundingBox();
      check(monthlyBounds.y >= dailyBounds.y + dailyBounds.height, source.name + ' Monthly block follows Daily vertically');
      same(Number(await monthlyCard(page, source).locator('.monthly-card-count strong').innerText()), [3, 1, 1][index], source.name + ' Monthly count');
      check(await monthlyCard(page, source).locator('.monthly-open-latest').isEnabled(), source.name + ' Monthly latest PDF remains available');
    }
    check((await page.locator('#pdf-reading-coverage-label').innerText()).includes('8 cached results'), 'Cached reading status remains visible');
    same(await page.locator('html').getAttribute('data-theme'), 'light', 'Light appearance loads');
    await screenshot(page, 'today-light-1440.png');
    // Select the other fixture theme directly; the Settings write flow is outside this check.
    snapshot.settings.theme = 'Dark';
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
    same(await page.locator('html').getAttribute('data-theme'), 'dark', 'Dark appearance loads');
    await screenshot(page, 'today-dark-1440.png');
    await page.setViewportSize({ width: 1024, height: 1100 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Today has no horizontal overflow at 1024px');
    for (const selector of ['#refresh-button', '#today-library-button', '#today-calendar-button',
      '#today-monthly-library', '#scanner-cards .scanner-daily-link >> nth=0',
      '#scanner-cards .today-monthly-block .monthly-open-latest >> nth=0']) await actionAvailable(page, selector);
    await page.evaluate(() => scrollTo(0, 0));
    await screenshot(page, 'today-dark-1024.png');
    await page.setViewportSize({ width: 1440, height: 1100 });
    await page.locator('#today-library-button').click();
    check(await page.locator('#reports-library-panel').isVisible() && await page.locator('#daily-calendar').isHidden(), 'Open library still opens the PDF list');
    same(await page.locator('#type-filter').inputValue(), 'daily', 'Open library keeps Daily filter');
    same(await page.locator('#report-list button[data-record-id]').count(), 3, 'Open library lists three synthetic Daily PDFs');
    await page.locator('.main-nav button[data-page="today"]').click();
    await monthlyCard(page, sources[0]).locator('.monthly-view-all').click();
    check(await page.locator('#reports-library-panel').isVisible(), 'Today Monthly View all opens the PDF list');
    for (const [name, value] of Object.entries({ scanner: 'CT_Edge', year: '2026', month: '11', type: 'monthly', status: 'all' })) {
      same(await page.locator('#' + name + '-filter').inputValue(), value, 'Monthly View all keeps ' + name + ' filter');
    }
    same(await page.locator('#report-list button[data-record-id]').count(), 3, 'Monthly View all lists all three scanner PDFs');
    await page.locator('.main-nav button[data-page="today"]').click();
    await page.locator('#scanner-cards article[data-scanner-id="CT_Edge"] .scanner-daily-link').click();
    const daily = records.find(row => row.scanner === 'CT_Edge' && row.category === 'Daily');
    await page.waitForFunction(reportId => document.getElementById('pdf-area').dataset.recordId === reportId, daily.id);
    same(await page.locator('#pdf-frame').getAttribute('src'), '/api/pdf/' + daily.id, 'Daily latest still targets its original synthetic PDF');
    check(await page.locator('#error-banner').isHidden(), 'No application error banner');
    same(mutationRequests.length, 0, 'Appearance/navigation checks send no mutations');
    same(errors.length, 0, 'No browser or JavaScript errors');
    same(externalRequests.length, 0, 'No external asset requests');
    result.status = 'PASS';
  } catch (error) { result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1; }
  finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length,
      output, screenshots: result.screenshots, scope: result.scope, failure: result.failure }, null, 2) + '\n');
  }
})();
