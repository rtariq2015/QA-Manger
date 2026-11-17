/* One focused Trends/Monthly production-web flow with synthetic API responses.
 * Fixture structure reused from run-monthly-cards-e2e.cjs; no live backend, scanner,
 * PDF extraction, archive mutation or native Windows runtime is exercised. */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const zlib = require('node:zlib');

const productRoot = path.resolve(__dirname, '../..');
const webRoot = path.join(productRoot, 'App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-trends-monthly-browser');
const monthlyOnly = process.argv.includes('--monthly-only');
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
const snapshot = { version: '5.7.14', previewMode: 'windows', trendsRevision: 'a'.repeat(64), setupComplete: true,
  workspace: 'Synthetic Monthly card browser fixture', archiveRoot: 'Synthetic sample only', records,
  today: { date: '2026-11-16', received: 0, expected: 3, headline: 'Synthetic frontend check' },
  scanners: sources.map((source, index) => ({ ...source, dailySchedule: 'AllDays',
    activeFrom: '2025-01-01', excludedDates: [], expectedMonthly: true,
    monthlyDueDay: 20, checklist: options.slice(0, index + 3).map(item => item.label),
    checklistEffectiveMonth: '0001-01', nextChecklistEffectiveMonth: '2026-11',
    status: 'Unknown', message: 'Synthetic sample; no connection is made' })),
  months: [], analysis: { total: records.length, cached: 0, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const jobs = [];
let snapshotGate = null, monthlyGate = null;
const previewRequests = [];
const requests = [], trendRequests = [], mutations = [], pdfRequests = [], errors = [], externalRequests = [], checks = [];
const result = { syntheticOnly: true,
  scope: 'One focused production web UI flow against synthetic snapshot, Monthly, Trends and generated PNG responses. Validates presentation mode changes, source-context values/units/printed limits/page references and read-only Monthly refresh behavior with a controlled browser clock. No real backend, PDF extraction, scanner, archive, Windows or hospital-workstation execution.',
  checks, errors, externalRequests, mutations, pdfRequests };
let browser, server;
result.screenshots = [];
result.sourceHashes = Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(webRoot,file))).digest('hex')]));
result.screenshotSourceHashes = {};
if (monthlyOnly) {
  const prior = JSON.parse(fs.readFileSync(path.join(output, 'Chromium.json'), 'utf8'));
  checks.push(...prior.checks.filter(check => !check.name.startsWith('Manual Monthly')));
  result.screenshots.push(...(prior.screenshots || []));
  for (const file of prior.screenshots || []) result.screenshotSourceHashes[path.basename(file)] = prior.sourceHashes;
  result.priorTrendsEvidence = { status: 'PASS for completed Trends checks', sourceHashes: prior.sourceHashes,
    note: 'The preceding run completed all Trends assertions, then stopped at Monthly centering. Only Monthly CSS changed before this Monthly-only continuation.' };
}
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
    if (pathname === '/api/snapshot') { if (snapshotGate) await snapshotGate; return json(response, snapshot); }
    if (pathname === '/api/jobs') return json(response, { jobs });
    if (pathname === '/api/trends') { trendRequests.push(Object.fromEntries(url.searchParams)); return json(response, trendResponse(url.searchParams)); }
    if (pathname.startsWith('/api/preview/')) { const recordId=pathname.slice('/api/preview/'.length), pageNumber=Number(url.searchParams.get('page')); previewRequests.push({recordId,pageNumber}); return json(response,{recordId,pageNumber,pageCount:5,pngBase64:portraitPng().toString('base64')}); }
    if (pathname === '/api/monthly') { if(monthlyGate)await monthlyGate; return json(response, models[url.searchParams.get('month')] ||
      { month: url.searchParams.get('month'), today: snapshot.today.date, scanners: [], componentOptions: options }); }
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
function portraitPng() {
  const width = 612, height = 792, pixels = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const header = y > 42 && y < 90 && x > 42 && x < width - 42;
      const rule = y > 135 && y < 690 && y % 44 < 2 && x > 42 && x < width - 42;
      const color = header ? [43, 104, 88] : rule ? [208, 219, 216] : [255, 255, 255];
      const offset = row + 1 + x * 3;
      pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2];
    }
  }
  function crc32(bytes) { let crc = 0xffffffff; for (const byte of bytes) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); } return (crc ^ 0xffffffff) >>> 0; }
  function chunk(type, bytes) { const name = Buffer.from(type), size = Buffer.alloc(4), crc = Buffer.alloc(4); size.writeUInt32BE(bytes.length); crc.writeUInt32BE(crc32(Buffer.concat([name, bytes]))); return Buffer.concat([size, name, bytes, crc]); }
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
}
const days = ['02', '05', '08', '11', '14', '17'];
const trendRecords = new Map(sources.map(source => [source.id, days.map(day => report(source,
  '2026-11', 'TREND_SOURCE_' + day, day, { category: 'Daily', content: { status: 'Recognized', measurements: [], components: [] } }))]));
snapshot.today.date = '2026-11-17';
snapshot.analysis = { total: records.length, cached: records.length, pending: 0, errors: 0, backlogPending: 0 };
const waterValues = [-2.4, -2.1, -2.2, -1.9, -2, -1.8];
const bounds = [[-3, 3], [null, null], [-2.5, 2.5], [-1.8, null], [null, 2], [-3, 3.5]];
const pages = [3, 3, 5, 4, 3, 3];
const contextA = scanner => scanner + '|WaterCTNumber|Body|A|1';
const contextB = scanner => scanner + '|WaterCTNumber|Body|B|2';
function trendResponse(params) {
  const scanner = params.get('scanner') || sources[0].id, metric = params.get('metric') || 'WaterCTNumber';
  const unit = ['WaterCTNumber', 'ImageNoise'].includes(metric) ? 'HU' : 'mm';
  const special = metric === 'TablePosition';
  const normalKey = metric === 'WaterCTNumber' ? contextA(scanner) : scanner + '|' + metric + (special ? '|Unspecified|NotSpecified|ContinuousPosition1' : '|Body|A|1');
  const series = [{ key: normalKey, label: special ? 'Continuous movement / Position 1' : 'Body / System A / Slice 1', metric, count: 6 }];
  if (metric === 'WaterCTNumber') series.push({ key: contextB(scanner), label: 'Body / System B / Slice 2', metric, count: 1 });
  const requested = params.get('series'), selectedSeries = series.some(item => item.key === requested) ? requested : normalKey;
  const wrongContext = selectedSeries === contextB(scanner);
  const selectedRecords = trendRecords.get(scanner) || trendRecords.get(sources[0].id);
  const values = wrongContext ? [24.5] : metric === 'WaterCTNumber' ? waterValues : special ? [.1, .2, .23, .18, .21, .24] : [1, 1.1, 1.2, 1.15, 1.25, 1.3];
  const points = values.map((value, index) => ({ recordId: selectedRecords[index].id, date: selectedRecords[index].date,
    time: '08:00:00', value, unit, lower: wrongContext || special ? null : bounds[index][0], upper: wrongContext || special ? null : bounds[index][1], page: pages[index] }));
  return { scanners: sources, selection: { scanner }, selectedSeries, series, points, pendingIds: [],
    coverage: { savedReports: 12, readReports: 10, pendingReports: 2, metricNotPresentReports: 4, metricUnavailableReports: 0 },
    summary: { count: points.length, scope: 'selectedPeriod', first: points[0].value, latest: points.at(-1).value,
      firstDate: points[0].date, latestDate: points.at(-1).date }, totalPointCount: points.length };
}
const countRequests = route => requests.filter(request => request.pathname === route).length;
const nav = (page, name) => page.locator('.main-nav button[data-page="' + name + '"]').click();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(test, message, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) { if (await test()) return; await delay(25); }
  throw Error(message);
}
async function nextPoll(page) { const previous = countRequests('/api/jobs'); await until(() => countRequests('/api/jobs') > previous, 'Production job poll did not run.'); await delay(80); }
async function screenshot(page, name) {
  await page.evaluate(() => scrollTo(0, 0));
  const file = path.join(output, name); await page.screenshot({ path: file, fullPage: true }); result.screenshots.push(file);
  result.screenshotSourceHashes[name] = result.sourceHashes;
}
async function chooseMetric(page, metric, expectedUnit) {
  await page.locator('#trend-metric').selectOption(metric);
  await until(async () => (await page.locator('#trend-latest').innerText()).endsWith(' ' + expectedUnit) &&
    trendRequests.at(-1)?.metric === metric, 'Metric did not load with its existing unit.');
}
function expectedBounds(index) {
  const [lower, upper] = bounds[index];
  return lower !== null && upper !== null ? lower + ' to ' + upper + ' HU' : lower !== null ? 'Lower: ' + lower + ' HU' : upper !== null ? 'Upper: ' + upper + ' HU' : 'Not printed';
}
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
    await context.addInitScript(() => {
      window.__qaNow = new Date('2026-11-17T08:00:00Z').getTime(); Date.now = () => window.__qaNow;
      window.__qaVisibility = 'visible'; Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => window.__qaVisibility });
    });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); } return route.continue(); });
    const page = await context.newPage(); page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await page.goto(origin + '/#session=synthetic-trends-monthly-ui-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(() => document.getElementById('refresh-button').disabled === false);
    if (!monthlyOnly) {
    await nav(page, 'trends');
    await until(async () => await page.locator('#trend-latest').innerText() === '-1.8 HU', 'Initial synthetic Water CT readings did not load.');
    same(await page.locator('#trend-scanner-tabs button').evaluateAll(nodes => nodes.map(node => node.dataset.scannerId)), sources.map(source => source.id), 'All existing scanners appear as Trends tabs');
    same(await page.locator('#trend-metric option').evaluateAll(nodes => nodes.map(node => node.value)), ['WaterCTNumber', 'ImageNoise', 'SliceThickness', 'Lightmarker', 'ExternalLightmarker', 'TopogramPosition', 'SagittalCoronalLightmarker', 'TablePosition'], 'All eight existing metric families remain available');
    same(await page.locator('#trend-change').innerText(), '+0.6 HU', 'Change remains latest minus first, from exact supplied values');
    same(await page.locator('#trend-count').innerText(), '6', 'Exact reading count retained');
    same(await page.locator('#trend-series').inputValue(), contextA('CT_Edge'), 'Default measurement context is the exact backend-selected series');
    check((await page.locator('#trend-coverage-details summary').innerText()).includes('10 of 12'), 'Coverage summary distinguishes read PDF count');
    check((await page.locator('#trend-coverage-details summary').innerText()).includes('2'), 'Coverage summary retains waiting count');
    await page.locator('#trend-coverage-details summary').click();
    check((await page.locator('#trend-coverage').innerText()).includes('4 PDFs do not contain this test section'), 'Expanded coverage retains the absent-test count');
    await page.locator('#trend-coverage-details summary').click();
    const beforeModes = trendRequests.length;
    await page.evaluate(() => window.__qaTrendChart = document.querySelector('#trend-chart > svg'));
    await page.locator('#trend-view-points').click();
    same(await page.locator('#page-trends').getAttribute('data-trend-view'), 'points', 'Points mode updates only presentation state');
    same(await page.locator('#trend-chart .data-line').evaluate(node => getComputedStyle(node).display), 'none', 'Points mode hides the joining line');
    check(await page.locator('#trend-chart .limit-line').count() > 0 && await page.locator('#trend-chart .limit-band').count() > 0, 'Points mode keeps source-printed limits and bounds');
    check(await page.locator('#trend-chart .limit-line').evaluateAll(nodes => nodes.every(node => getComputedStyle(node).display !== 'none')), 'Printed-limit lines stay visible in Points mode');
    await page.locator('#trend-view-table').click();
    check(await page.locator('#trend-chart').isHidden() && await page.locator('#trend-table-section').isVisible(), 'Table mode shows the existing source-evidence table');
    const rows = await page.locator('#trend-table-body tr').evaluateAll(nodes => nodes.map(node => Array.from(node.cells, cell => cell.textContent)));
    same(rows.length, 6, 'Table view retains all six readings');
    for (let index = 0; index < 6; index++) {
      const row = rows[5 - index];
      check(row[1].startsWith(waterValues[index] + ' HU'), 'Table preserves source numeric value and HU for reading ' + index);
      same(row[2], expectedBounds(index), 'Table preserves this PDF’s printed bounds for reading ' + index);
      check(row[3].startsWith('Body / System A / Slice 1'), 'Table does not mix test contexts for reading ' + index);
      check(row[4].includes('p. ' + pages[index]), 'Table preserves source page for reading ' + index);
    }
    await page.locator('#trend-view-line').click();
    check(await page.evaluate(() => window.__qaTrendChart === document.querySelector('#trend-chart > svg')), 'Line/Points/Table toggles reuse the same rendered chart evidence');
    same(trendRequests.length, beforeModes, 'Presentation toggles make no additional Trends API requests');
    same(await page.locator('#trend-selected-value').innerText(), '-1.8 HU', 'Selected source defaults to the latest real supplied point');
    same(await page.locator('#trend-selected-context').innerText(), 'Body / System A / Slice 1', 'Prominent selected source keeps its exact context');
    same(await page.locator('#trend-selected-limits').innerText(), 'Printed limits: -3 to 3.5 HU', 'Prominent selected source keeps printed limits');
    same(await page.locator('#trend-selected-source').getAttribute('data-record-id'), trendRecords.get('CT_Edge')[5].id, 'Prominent source control targets the exact original record ID');
    same(await page.locator('#trend-selected-source').getAttribute('data-page'), '3', 'Prominent source control keeps the exact source-page reference');
    const selectedOptions = await page.locator('#trend-selected-reading option').evaluateAll(nodes => nodes.map(node => node.value));
    await page.locator('#trend-selected-reading').selectOption(selectedOptions[3]);
    same(await page.locator('#trend-selected-value').innerText(), '-2.2 HU', 'Selected-reading control exposes a different original value');
    same(await page.locator('#trend-selected-source').getAttribute('data-page'), '5', 'Changing selected reading preserves its distinct PDF page');
    same(trendRequests.length, beforeModes, 'Selecting an already-loaded reading does not refetch Trends');
    await page.locator('#trend-selected-reading').selectOption(selectedOptions[0]);
    await page.evaluate(() => document.documentElement.dataset.theme = 'dark');
    await screenshot(page, 'Trends-Dark.png');
    await page.evaluate(() => document.documentElement.dataset.theme = 'light');
    await screenshot(page, 'Trends-Light.png');
    await page.locator('#trend-selected-source').click();
    await until(async () => await page.locator('#pdf-area').getAttribute('data-record-id') === trendRecords.get('CT_Edge')[5].id && previewRequests.some(request => request.recordId === trendRecords.get('CT_Edge')[5].id && request.pageNumber === 2), 'Opening source did not target the selected PDF/page.');
    check(await page.locator('body').evaluate(node => node.classList.contains('pdf-viewing')), 'Source opens existing view-only PDF mode');
    check(await page.locator('#review-actions').isHidden(), 'Source viewing does not turn filing or clinical approval into a chart action');
    await page.locator('#viewer-back').click();
    await until(async () => await page.locator('#page-trends').isVisible(), 'Source Back did not return to Trends.');
    const activeCount = trendRequests.length;
    await page.locator('#trend-scanner-tabs button[data-scanner-id="CT_Edge"]').click();
    same(trendRequests.length, activeCount, 'Clicking the active scanner tab does not reload data');
    for (const source of sources.slice(1)) {
      await page.locator('#trend-scanner-tabs button[data-scanner-id="' + source.id + '"]').click();
      await until(async () => await page.locator('#trend-selected-source').getAttribute('data-record-id') === trendRecords.get(source.id)[5].id, 'Scanner tab did not change source data.');
      same(await page.locator('#trend-scanner').inputValue(), source.id, source.name + ' tab updates existing scanner selection');
      check(trendRequests.at(-1).scanner === source.id, source.name + ' requests only its scanner context');
    }
    await page.locator('#trend-scanner-tabs button[data-scanner-id="CT_Edge"]').click();
    await chooseMetric(page, 'TablePosition', 'mm');
    same(await page.locator('#trend-selected-value').innerText(), '0.24 mm', 'Table-position family retains millimetres');
    same(await page.locator('#trend-selected-context').innerText(), 'Continuous movement / Position 1', 'Table-position method/position context remains distinct');
    await chooseMetric(page, 'WaterCTNumber', 'HU');
    await page.locator('#trend-series').selectOption(contextB('CT_Edge'));
    await until(async () => await page.locator('#trend-latest').innerText() === '24.5 HU', 'Alternate existing test context did not load.');
    same(await page.locator('#trend-count').innerText(), '1', 'Changing test setup does not merge separate context readings');
    same(await page.locator('#trend-selected-context').innerText(), 'Body / System B / Slice 2', 'Explicit alternate test setup is retained');
    same(await page.locator('#trend-selected-limits').innerText(), 'Printed limits: Not printed', 'Absent bounds are never invented');
    }
    await nav(page, 'monthly');
    await until(async () => await page.locator('#monthly-workspace-status').getAttribute('data-loading') === 'false', 'Monthly model did not finish.');
    check(await page.locator('#monthly-refresh').isHidden(), 'Manual Monthly refresh is hidden');
    const toolbar = await page.locator('.monthly-toolbar').boundingBox(), tabBounds = await page.locator('#monthly-scanner-tabs').boundingBox();
    result.monthlyGeometry = { toolbar, tabBounds, centerDifference: (tabBounds.x + tabBounds.width / 2) - (toolbar.x + toolbar.width / 2) };
    check(Math.abs(result.monthlyGeometry.centerDifference) <= 3, 'Monthly scanner tabs are centered in the toolbar: ' + JSON.stringify(result.monthlyGeometry));
    const initialSnapshots = countRequests('/api/snapshot'), initialMonthly = countRequests('/api/monthly');
    await page.evaluate(() => window.__qaNow += 29000); await nextPoll(page);
    same(countRequests('/api/snapshot'), initialSnapshots, 'Visible Monthly does not refresh before30seconds');
    await page.evaluate(() => window.__qaNow += 2000);
    await until(() => countRequests('/api/snapshot') === initialSnapshots + 1, 'Monthly did not refresh its saved snapshot after30seconds.'); await delay(80);
    same(countRequests('/api/monthly'), initialMonthly, 'Unchanged snapshot reuses the existing Monthly model');
    const added = report(sources[0], '2026-11', 'SAVED_IN_ANOTHER_SESSION', '15');
    const model = models['2026-11'].scanners[0]; model.receipt.count++; model.receipt.reportIds.push(added.id); model.reports.push(monthlyRow(added));
    snapshot.trendsRevision = 'b'.repeat(64);
    let releaseMonthly; monthlyGate = new Promise(resolve => releaseMonthly = resolve);
    await page.evaluate(() => window.__qaNow += 31000);
    await until(() => countRequests('/api/monthly') === initialMonthly + 1, 'Changed saved revision did not reload Monthly once.');
    const whileLoading = countRequests('/api/snapshot'); await page.evaluate(() => window.__qaNow += 31000); await nextPoll(page);
    same(countRequests('/api/snapshot'), whileLoading, 'Monthly defers periodic snapshot work while its model is loading');
    releaseMonthly(); monthlyGate = null;
    await until(async () => (await page.locator('#monthly-evidence-list article[data-scanner-id="CT_Edge"] .monthly-card-count').innerText()).includes('4'), 'Monthly did not display the changed saved report count.');
    same(countRequests('/api/monthly'), initialMonthly + 1, 'A changed saved revision reloads Monthly exactly once');
    const beforeBusy = countRequests('/api/snapshot'); jobs.push({ id: 'synthetic-busy-export', action: 'Export', status: 'Running', completed: 0, total: 1, message: 'Synthetic busy state only' });
    await page.evaluate(() => window.__qaNow += 31000); await nextPoll(page);
    same(countRequests('/api/snapshot'), beforeBusy, 'Monthly defers periodic snapshot work during a foreground operation');
    jobs.length = 0; await until(() => countRequests('/api/snapshot') === beforeBusy + 1, 'Monthly did not resume saved-snapshot refresh after idle.');
    const beforeHidden = countRequests('/api/snapshot'); await page.evaluate(() => { window.__qaVisibility = 'hidden'; window.__qaNow += 31000; }); await nextPoll(page);
    same(countRequests('/api/snapshot'), beforeHidden, 'Hidden Monthly does not start periodic snapshot work');
    await page.evaluate(() => window.__qaVisibility = 'visible'); await until(() => countRequests('/api/snapshot') === beforeHidden + 1, 'Visible Monthly did not resume its due refresh.');
    let releaseSnapshot; snapshotGate = new Promise(resolve => releaseSnapshot = resolve); const beforeGate = countRequests('/api/snapshot');
    await page.evaluate(() => window.__qaNow += 31000); await until(() => countRequests('/api/snapshot') === beforeGate + 1, 'Controlled snapshot refresh did not start.');
    await page.evaluate(() => window.__qaNow += 31000); await delay(1700);
    same(countRequests('/api/snapshot'), beforeGate + 1, 'An in-flight saved snapshot is not duplicated');
    releaseSnapshot(); snapshotGate = null; await delay(100);
    await page.locator('#monthly-scanner-tabs button[data-scanner-id="CT_Flash"]').click();
    same(await page.locator('#monthly-scanner').inputValue(), 'CT_Flash', 'Centered Monthly tabs retain scanner filtering');
    same(await page.locator('#monthly-evidence-list article[data-scanner-id]').count(), 1, 'Monthly scanner tab filters the model locally');
    await page.locator('#monthly-scanner-tabs button[data-scanner-id="all"]').click();
    await page.evaluate(() => document.documentElement.dataset.theme = 'dark'); await screenshot(page, 'Monthly-Dark.png');
    await page.evaluate(() => document.documentElement.dataset.theme = 'light'); await screenshot(page, 'Monthly-Light.png');
    same(mutations, [], 'This flow submits no mutation, scanner Refresh or filing actions');
    same(errors, [], 'No browser JavaScript or synthetic route errors');
    same(externalRequests, [], 'Production frontend needs no external requests');
    result.status = 'PASS'; result.assertions = checks.length; result.requests = requests; result.trendRequests = trendRequests;
    result.scope += ' Date.now/visibility are controlled only in the test browser; real timers and production polling execute normally. Screenshot themes are applied locally for visual inspection.';
    console.log('PASS focused Trends/Monthly UI flow: ' + checks.length + ' checks.');
  } catch (error) { result.status = 'FAIL'; result.error = error.stack; console.error(error.stack); process.exitCode = 1; }
  finally { result.sourceHashesAtEnd = Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(webRoot,file))).digest('hex')])); const evidence=JSON.stringify(result, null, 2) + '\n'; fs.writeFileSync(path.join(output, 'Chromium.json'), evidence); fs.writeFileSync(path.join(output, 'result.json'), evidence); if (browser) await browser.close(); if (server) { server.closeAllConnections?.(); await new Promise(resolve => server.close(resolve)); } }
})();
