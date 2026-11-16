/* Focused frontend check with synthetic Monthly/snapshot API responses.
 * Production web assets only; no live backend, archive, PDF reading or clinical QA.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const productRoot = path.resolve(__dirname, '../..');
const webRoot = path.join(productRoot, 'App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-monthly-cards-browser');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-monthly-cards:' + value).digest('hex');
const sources = [
  { id: 'CT_Edge', name: 'CT Edge' },
  { id: 'CT_Flash', name: 'CT Flash' },
  { id: 'CT_Drive', name: 'CT Drive' }
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
const snapshot = { version: '5.7.4', setupComplete: true,
  workspace: 'Synthetic Monthly card browser fixture', archiveRoot: 'Synthetic sample only', records,
  today: { date: '2026-11-16', received: 0, expected: 3, headline: 'Synthetic frontend check' },
  scanners: sources.map((source, index) => ({ ...source, dailySchedule: 'AllDays',
    activeFrom: '2025-01-01', excludedDates: [], expectedMonthly: true,
    monthlyDueDay: 20, checklist: options.slice(0, index + 3).map(item => item.label),
    checklistEffectiveMonth: '0001-01', nextChecklistEffectiveMonth: '2026-11',
    status: 'Unknown', message: 'Synthetic sample; no connection is made' })),
  months: [], analysis: { total: records.length, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const original = JSON.stringify({ snapshot, models });
const requests = [], mutations = [], pdfRequests = [], errors = [], externalRequests = [], checks = [];
const result = { syntheticOnly: true,
  scope: 'Synthetic HTTP snapshot/Monthly API and minimal sample PDF with production frontend assets. Checks cover browser navigation, card labels/counts and selected original IDs only; no live backend, archive, scanner, PDF extraction, native runtime or clinical QA validation.',
  checks, errors, externalRequests, mutations, pdfRequests };
let browser, server;
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
    requests.push({ method: request.method, pathname, month: url.searchParams.get('month') || undefined });
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs: [] });
    if (pathname === '/api/monthly') return json(response, models[url.searchParams.get('month')] ||
      { month: url.searchParams.get('month'), today: snapshot.today.date, scanners: [], componentOptions: options });
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
const card = (page, root, scanner) => page.locator(root + ' article[data-scanner-id="' + scanner + '"]');
async function cards(page, root, month) {
  const expected = periods[month];
  await page.waitForFunction(({ root, sources, expected }) => sources.every((source, index) => {
    const node = document.querySelector(root + ' article[data-scanner-id="' + source.id + '"] .monthly-card-count');
    return node && Number.parseInt(node.textContent, 10) === expected.receipts[index];
  }), { root, sources, expected });
  same(await page.locator(root + ' article[data-scanner-id]').count(), 3, root + ' has all three scanner cards for ' + month);
  for (const [index, source] of sources.entries()) {
    const scannerCard = card(page, root, source.id), body = await scannerCard.innerText();
    check(body.includes(source.name), source.name + ' card keeps its scanner label in ' + month);
    if (root === '#monthly-evidence-list') check(body.includes(expected.found[index] + ' of ' + (index + 3)), source.name + ' card coverage uses the selected API month ' + month);
    const button = scannerCard.locator('.monthly-open-latest');
    same(await button.isEnabled(), expected.receipts[index] > 0, source.name + ' latest-PDF availability in ' + month);
    if (!expected.receipts[index]) check(body.includes('No Monthly PDF saved'), source.name + ' explicitly labels the empty month ' + month);
  }
}
async function monthlyMonth(page, month, selector) {
  const response = page.waitForResponse(response => {
    const url = new URL(response.url()); return url.pathname === '/api/monthly' && url.searchParams.get('month') === month;
  });
  if (selector) await page.locator(selector).click();
  else { await page.locator('#monthly-period').fill(month); await page.locator('#monthly-period').dispatchEvent('change'); }
  check((await response).ok(), month + ' loads through the read-only Monthly API');
  await page.waitForFunction(month => document.getElementById('monthly-workspace-status').dataset.month === month &&
    document.getElementById('monthly-workspace-status').dataset.loading === 'false', month);
  same(await page.locator('#monthly-period').inputValue(), month, 'Month picker agrees with requested month ' + month);
  await cards(page, '#monthly-evidence-list', month);
}
async function selected(page, record, label) {
  await page.waitForFunction(reportId => document.getElementById('pdf-area').dataset.recordId === reportId, record.id);
  same(await page.locator('body').getAttribute('data-page'), 'review', label + ' opens the existing Review workspace');
  same(await page.locator('#pdf-frame').getAttribute('src'), '/api/pdf/' + record.id, label + ' targets the original synthetic PDF ID');
  same(await page.locator('#open-pdf-link').getAttribute('href'), '/api/pdf/' + record.id, label + ' agrees with Open PDF link');
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
      headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, locale: 'en-US' });
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); }
      return route.continue();
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push({ type: 'pageerror', message: error.message }));
    page.on('console', message => { if (message.type() === 'error') errors.push({ type: 'console', message: message.text() }); });
    await page.goto(origin + '/#session=synthetic-monthly-cards-only', { waitUntil: 'networkidle' });
    await cards(page, '#today-monthly-cards', '2026-11');
    same(await page.locator('#scanner-cards .scanner-card').count(), 3, 'Today retains all three existing Daily scanner cards');
    same(await page.locator('#scanner-cards .scanner-daily-link').count(), 3, 'Today retains the Daily shortcut controls');
    same(await page.locator('#scanner-cards .scanner-monthly-link').count(), 0, 'Today has one separate Monthly row without duplicate Monthly shortcuts inside Daily cards');
    const dailyBounds = await page.locator('#scanner-cards').boundingBox();
    const monthlyBounds = await page.locator('#today-monthly-cards').boundingBox();
    check(monthlyBounds.y >= dailyBounds.y + dailyBounds.height, 'Today Monthly cards form a separate row below the Daily scanner cards');
    check(await page.locator('#reports-calendar-view').evaluate(node => Boolean(node.compareDocumentPosition(document.getElementById('reports-library-view')) & Node.DOCUMENT_POSITION_FOLLOWING)),
      'Reports places Receipt calendar before Report library');
    await page.locator('.main-nav button[data-page="reports"]').click();
    check(await page.locator('#daily-calendar').isVisible(), 'Reports sidebar opens Receipt calendar');
    await page.locator('#reports-library-view').click();
    check(await page.locator('#reports-library-panel').isVisible(), 'Report library tab still opens the list');
    await page.locator('.main-nav button[data-page="today"]').click();
    await page.locator('.main-nav button[data-page="reports"]').click();
    check(await page.locator('#daily-calendar').isVisible(), 'Reports sidebar returns to Receipt calendar after a Library selection');
    await page.locator('.main-nav button[data-page="monthly"]').click();
    await cards(page, '#monthly-evidence-list', '2026-11');
    const details = card(page, '#monthly-evidence-list', 'CT_Edge').locator('.monthly-report-details');
    check(await details.evaluate(node => !node.open), 'Monthly report details start collapsed');
    await details.locator('summary').click();
    check(await details.evaluate(node => node.open), 'View all expands the existing report details');
    same(await details.locator('.monthly-report-row').count(), models['2026-11'].scanners[0].reports.length, 'Expanded details retain all saved/pending/unavailable report rows');
    check((await details.innerText()).includes('Saved PDF unavailable') && (await details.innerText()).includes('File type needs review'), 'Expanded details preserve filing exceptions and unavailable evidence');
    await details.locator('summary').click();
    for (const selector of ['#monthly-reviewed-details', '#monthly-setup-panel']) {
      check(await page.locator(selector).evaluate(node => !node.open), selector + ' remains in its collapsed section');
      await page.locator(selector + ' > summary').click();
      check(await page.locator(selector).evaluate(node => node.open), selector + ' still expands');
      await page.locator(selector + ' > summary').click();
    }
    same(await page.locator('#monthly-reviewed-evidence').getAttribute('data-confirmed-count'), '1', 'Existing reviewed report evidence is retained separately');
    await page.screenshot({ path: path.join(output, 'monthly-scanner-cards.png'), fullPage: true });
    result.screenshot = path.join(output, 'monthly-scanner-cards.png');
    await card(page, '#monthly-evidence-list', 'CT_Edge').locator('.monthly-open-latest').click();
    await selected(page, latestByMonth['2026-11'].CT_Edge, 'Monthly latest eligible report');
    check(!records.filter(row => row.pending || row.isReference || row.hasReferenceEvidence || !row.available).some(row => row.id === latestByMonth['2026-11'].CT_Edge.id), 'Latest target excludes newer pending, reference and unavailable synthetic decoys');
    await page.locator('.main-nav button[data-page="monthly"]').click();
    await monthlyMonth(page, '2026-12', '#monthly-next');
    await monthlyMonth(page, '2027-01', '#monthly-next');
    await monthlyMonth(page, '2026-12', '#monthly-previous');
    await monthlyMonth(page, '2025-08');
    await card(page, '#monthly-evidence-list', 'CT_Drive').locator('.monthly-open-latest').click();
    await selected(page, latestByMonth['2025-08'].CT_Drive, 'Historical Monthly latest report');
    await page.locator('.main-nav button[data-page="today"]').click();
    await cards(page, '#today-monthly-cards', '2026-11');
    await card(page, '#today-monthly-cards', 'CT_Flash').locator('.monthly-view-all').click();
    same(await page.locator('body').getAttribute('data-page'), 'reports', 'Today Monthly View all opens the existing Reports Library');
    for (const [name, value] of Object.entries({ scanner: 'CT_Flash', year: '2026', month: '11', type: 'monthly', status: 'all' })) {
      same(await page.locator('#' + name + '-filter').inputValue(), value, 'Today Monthly View all selects current-month ' + name + ' filter');
    }
    same(await page.locator('#report-list button[data-record-id]').evaluateAll(nodes => nodes.map(node => node.dataset.recordId)),
      models['2026-11'].scanners[1].receipt.reportIds, 'Today Monthly View all lists every original current-month PDF for the chosen scanner');
    check(await page.locator('#reports-library-panel').isVisible(), 'Today Monthly View all displays the Reports Library list');
    await page.locator('.main-nav button[data-page="today"]').click();
    await cards(page, '#today-monthly-cards', '2026-11');
    await card(page, '#today-monthly-cards', 'CT_Edge').locator('.monthly-open-latest').click();
    await selected(page, latestByMonth['2026-11'].CT_Edge, 'Today current-month Monthly report after historical browsing');
    await page.locator('.main-nav button[data-page="monthly"]').click();
    same(await page.locator('#monthly-period').inputValue(), '2025-08', 'Monthly tab retains its browsed historical month independently of Today');
    await cards(page, '#monthly-evidence-list', '2025-08');
    check(await page.locator('#error-banner').isHidden(), 'Monthly navigation finishes without an application error');
    check(mutations.length === 0, 'Monthly/Today navigation and existing PDF opening send no mutation actions');
    check(JSON.stringify({ snapshot, models }) === original, 'Synthetic source identities, categories and evidence remain unchanged');
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
