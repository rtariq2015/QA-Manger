/* One focused frontend flow with synthetic API responses and a generated PNG.
 * No live backend, archive, scanner, PDF extraction or clinical QA is exercised.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const zlib = require('node:zlib');
const { chromium } = require('playwright');

const webRoot = path.resolve(__dirname, '../../App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-reader-controls-browser');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-reader-controls:' + value).digest('hex');
const sources = ['CT_Edge', 'CT_Flash', 'CT_Drive'].map(scanner => ({ id: scanner, name: scanner.replace('_', ' ') }));
function report(name, scanner, category, date, extra = {}) {
  return { id: id(name), scanner, scannerName: scanner.replace('_', ' '), date, time: '08:00:00',
    filename: 'SYNTHETIC_' + name + '.pdf', title: 'Synthetic reader controls fixture ' + name,
    category, pending: false, decision: 'Automatic', filingState: 'Filed', stamp: id('stamp:' + name),
    isReference: false, hasReferenceEvidence: false, available: true, content: { status: 'NotRead' }, ...extra };
}
const saved = report('EDGE_MONTHLY_LATEST', 'CT_Edge', 'Monthly', '2026-11-16');
const earlier = report('EDGE_MONTHLY_EARLIER', 'CT_Edge', 'Monthly', '2026-11-10');
const single = report('FLASH_MONTHLY', 'CT_Flash', 'Monthly', '2026-11-15');
const pending = report('PENDING_DAILY', 'CT_Edge', 'Daily', '2026-11-15', {
  pending: true, decision: 'Pending', filingState: 'NeedsReview', filingReason: 'Synthetic filing question',
  filingBasis: 'ManualReview', groupingReason: 'ManualReview', approvalCategory: 'Daily' });
const records = [saved, earlier, single, pending, report('EDGE_DAILY', 'CT_Edge', 'Daily', '2026-11-16')];
const snapshot = { version: '5.7.4', setupComplete: true, previewMode: 'windows',
  workspace: 'Synthetic frontend controls fixture', archiveRoot: 'Synthetic sample only', records,
  today: { date: '2026-11-16', received: 1, expected: 3, headline: 'Synthetic reader controls check',
    scanners: sources.map(source => ({ scanner: source.id, received: source.id === 'CT_Edge', required: true })) },
  scanners: sources.map(source => ({ ...source, dailySchedule: 'AllDays', activeFrom: '2026-01-01',
    excludedDates: [], expectedMonthly: true, monthlyDueDay: 20, status: 'Unknown', message: 'Synthetic fixture only' })),
  months: [], analysis: { total: records.length, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const original = JSON.stringify(snapshot);
const requests = [], mutations = [], previewRequests = [], errors = [], externalRequests = [], checks = [];
const result = { syntheticOnly: true,
  scope: 'One frontend controls flow using production web assets, a synthetic snapshot, and a generated portrait PNG. Covers Monthly list controls, Today clutter, view-only PDF layout, page fitting, and return to filing review. No real backend, PDF extraction, archive, scanner, native runtime or clinical QA validation.',
  checks, errors, externalRequests, mutations, previewRequests };
let browser, server;
function check(condition, name) { assert.ok(condition, name); checks.push({ name, result: 'PASS' }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS', actual }); }
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
function portraitPng() {
  const width = 612, height = 792, pixels = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1); pixels[row] = 0;
    for (let x = 0; x < width; x++) {
      const header = y > 42 && y < 90 && x > 42 && x < width - 42;
      const rule = y > 135 && y < 690 && y % 44 < 2 && x > 42 && x < width - 42;
      const color = header ? [43, 104, 88] : rule ? [208, 219, 216] : [255, 255, 255];
      const offset = row + 1 + x * 3;
      pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2];
    }
  }
  function crc32(bytes) {
    let crc = 0xffffffff;
    for (const byte of bytes) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
    return (crc ^ 0xffffffff) >>> 0;
  }
  function chunk(type, bytes) {
    const name = Buffer.from(type), size = Buffer.alloc(4), crc = Buffer.alloc(4);
    size.writeUInt32BE(bytes.length); crc.writeUInt32BE(crc32(Buffer.concat([name, bytes])));
    return Buffer.concat([size, name, bytes, crc]);
  }
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
}
async function startServer() {
  const pngBase64 = portraitPng().toString('base64');
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1'), pathname = url.pathname;
    requests.push({ method: request.method, pathname });
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs: [] });
    if (pathname === '/api/monthly') return json(response, { month: url.searchParams.get('month'),
      today: snapshot.today.date, scanners: [], componentOptions: [] });
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      mutations.push(body); return json(response, { error: 'This synthetic controls check permits no actions.' }, 400);
    }
    if (pathname.startsWith('/api/preview/')) {
      const recordId = pathname.slice('/api/preview/'.length), pageNumber = Number(url.searchParams.get('page'));
      if (!records.some(record => record.id === recordId) || pageNumber !== 0) return json(response, { error: 'Unknown synthetic page' }, 404);
      previewRequests.push({ recordId, pageNumber });
      return json(response, { recordId, pageNumber, pageCount: 1, pngBase64 });
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
const nav = (page, name) => page.locator('.main-nav button[data-page="' + name + '"]');
const card = (page, scanner) => page.locator('#scanner-cards .monthly-scanner-card[data-scanner-id="' + scanner + '"]');
async function identity(page, record) {
  await page.waitForFunction(reportId => document.getElementById('pdf-area').dataset.recordId === reportId, record.id);
  const target = new URL(await page.locator('#open-pdf-link').getAttribute('href'), page.url());
  same(target.pathname, '/api/pdf/' + record.id, 'Open PDF retains the selected original report identity');
  same(target.hash, '#view=Fit', 'Open PDF asks the browser to fit the page');
}
async function loaded(page) {
  await page.waitForFunction(() => { const image = document.getElementById('pdf-image'); return image && !image.hidden && image.complete && image.naturalWidth === 612; });
}
async function fitsPage(page) {
  await page.waitForFunction(() => {
    const scroller = document.getElementById('pdf-image-scroller'), figure = document.querySelector('.pdf-page');
    if (!figure) return false;
    const style = getComputedStyle(scroller), height = scroller.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
    return figure.getBoundingClientRect().height > 100 && figure.getBoundingClientRect().height <= height + 2;
  });
  return page.locator('.pdf-page').boundingBox();
}
async function openPending(page) {
  await nav(page, 'reports').click(); await page.locator('#reports-library-view').click();
  await page.locator('#clear-filters').click(); await page.locator('#report-search').fill(pending.filename);
  await page.locator('#report-list button[data-record-id="' + pending.id + '"]').click();
  await identity(page, pending); await loaded(page);
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
      headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); }
      return route.continue();
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push({ type: 'pageerror', message: error.message }));
    page.on('console', message => { if (message.type() === 'error') errors.push({ type: 'console', message: message.text() }); });
    await page.goto(origin + '/#session=synthetic-reader-controls-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(count => Number(document.getElementById('report-total').textContent) === count, records.length);
    for (const [index, source] of sources.entries()) {
      const monthly = card(page, source.id), count = [2, 1, 0][index], button = monthly.locator('.monthly-view-reports');
      same(await button.count(), 1, source.name + ' has one primary Monthly report-list control');
      same(await monthly.locator('.monthly-card-count strong').innerText(), String(count), source.name + ' Monthly card states the matching file count');
      same(await button.innerText(), count === 0 ? 'View Monthly reports' : count === 1 ? 'View 1 Monthly PDF' : 'View all ' + count + ' Monthly PDFs', source.name + ' Monthly list label matches its saved files');
      same(await button.isEnabled(), count > 0, source.name + ' Monthly list availability follows its saved file count');
      check(await button.evaluate(node => node.classList.contains('button-primary')), source.name + ' Monthly report-list control is primary');
      same(await monthly.locator('.monthly-open-latest, .monthly-card-all').count(), 0, source.name + ' has no duplicate latest/all Monthly controls');
    }
    const circle = await page.evaluate(() => {
      const daily = document.querySelector('#scanner-cards .scanner-card[data-scanner-id="CT_Edge"] .receipt-icon');
      const monthly = document.querySelector('#scanner-cards .monthly-scanner-card[data-scanner-id="CT_Edge"] .receipt-icon');
      if (!daily || !monthly) return null;
      const d = getComputedStyle(daily), m = getComputedStyle(monthly);
      return { dailyRadius: d.borderRadius, monthlyRadius: m.borderRadius,
        dailyBackground: d.backgroundColor, monthlyBackground: m.backgroundColor,
        dailySvg: daily.querySelector('svg')?.innerHTML, monthlySvg: monthly.querySelector('svg')?.innerHTML };
    });
    check(circle && circle.monthlyRadius === circle.dailyRadius && circle.monthlyRadius !== '0px' &&
      circle.monthlyBackground === circle.dailyBackground && circle.monthlySvg === circle.dailySvg,
    'Monthly received state uses the same circled green check as Daily');
    check(await page.locator('#today-library-button').isHidden() && await page.locator('#today-calendar-button').isHidden(),
      'Today hides the redundant library and receipt-calendar links');
    check(await page.locator('#pdf-reading-coverage').evaluate(node => Boolean(node.closest('.today-archive-details'))),
      'PDF cache details live inside Today archive details');
    await card(page, 'CT_Edge').locator('.monthly-view-reports').click();
    check(await page.locator('#reports-library-panel').isVisible(), 'Primary Monthly control opens the Reports list');
    for (const [name, value] of Object.entries({ scanner: 'CT_Edge', year: '2026', month: '11', type: 'monthly', status: 'all' })) {
      same(await page.locator('#' + name + '-filter').inputValue(), value, 'Monthly list sets the ' + name + ' filter');
    }
    same(await page.locator('#report-list button[data-record-id]').evaluateAll(nodes => nodes.map(node => node.dataset.recordId)),
      [saved.id, earlier.id], 'Monthly list includes both matching saved PDFs');
    await page.locator('#report-list button[data-record-id="' + saved.id + '"]').click();
    await identity(page, saved); await loaded(page);
    check(await page.locator('body').evaluate(node => node.classList.contains('pdf-viewing')), 'Saved report opens in view-only mode');
    same(await page.locator('#page-title').innerText(), 'PDF viewer', 'Saved PDF heading identifies the viewer');
    check(await page.locator('#review-control-rail').isHidden() && await page.locator('.review-workspace-heading').isHidden(),
      'View-only layout hides filing rail and toolbar');
    same(await page.locator('#preview-zoom').inputValue(), 'page', 'Saved PDF defaults to Fit page');
    same(await page.locator('#preview-zoom option:checked').innerText(), 'Fit page', 'Fit page option has a clear label');
    const initial = await fitsPage(page);
    check(initial.height > 300, 'Loaded portrait page fits the available viewer height');
    await page.setViewportSize({ width: 1440, height: 850 });
    const resized = await fitsPage(page);
    check(resized.width < initial.width, 'Fit page refits when the viewer height changes');
    await page.locator('#preview-zoom').selectOption('fit');
    await page.waitForFunction(previous => document.querySelector('.pdf-page').getBoundingClientRect().width > previous + 100, resized.width);
    check((await page.locator('.pdf-page').boundingBox()).width > resized.width + 100, 'Fit width remains available and enlarges the portrait page');
    await page.locator('#preview-zoom').selectOption('page'); await fitsPage(page);
    result.screenshot = path.join(output, 'viewer-fit-page.png');
    await page.screenshot({ path: result.screenshot, fullPage: true });
    await openPending(page);
    check(await page.locator('body').evaluate(node => node.classList.contains('pdf-viewing')), 'Pending report opened from Reports also starts in viewer mode');
    check(await page.locator('#viewer-review-filing').isVisible(), 'Pending viewer offers Review filing');
    await page.locator('#viewer-review-filing').click();
    check(!await page.locator('body').evaluate(node => node.classList.contains('pdf-viewing')) && await page.locator('#review-control-rail').isVisible() &&
      await page.locator('#review-actions').isVisible(), 'Review filing restores pending file controls');
    await identity(page, pending);
    same(await page.locator('#review-action-file').getAttribute('data-record-id'), pending.id, 'Restored filing rail targets the same pending PDF');
    await openPending(page); await nav(page, 'review').click();
    check(!await page.locator('body').evaluate(node => node.classList.contains('pdf-viewing')) && await page.locator('#review-control-rail').isVisible(),
      'Sidebar Review restores the filing workspace from viewer mode');
    await identity(page, pending);
    same(await page.locator('#review-action-file').getAttribute('data-record-id'), pending.id, 'Sidebar Review preserves the selected pending PDF');
    check(await page.locator('#error-banner').isHidden(), 'Focused controls flow finishes without an application error');
    check(mutations.length === 0 && JSON.stringify(snapshot) === original, 'Navigation changes neither synthetic source records nor filing decisions');
    check(errors.length === 0 && externalRequests.length === 0, 'Focused controls flow has no browser errors or external requests');
    result.status = 'PASS';
  } catch (error) { result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1; }
  finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    result.requests = requests;
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length, output, failure: result.failure }, null, 2) + '\n');
  }
})();
