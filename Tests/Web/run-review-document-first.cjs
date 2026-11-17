/* One focused frontend flow against production web assets and synthetic API/PNG
 * fixtures. Filing jobs below are simulated responses, not backend validation.
 * No real PDFs, archives, scanner connections or Windows runtime are exercised.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const zlib = require('node:zlib');
const { chromium } = require('playwright');
const product = path.resolve(__dirname, '../..');
const webRoot = path.join(product, 'App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-review-document-first');
fs.mkdirSync(output, { recursive: true });
const id = value => crypto.createHash('sha256').update('synthetic-document-first:' + value).digest('hex');
const sources = [{ id: 'CT_Edge', name: 'CT Edge' }, { id: 'CT_Flash', name: 'CT Flash' }, { id: 'CT_Drive', name: 'MDP Building' }];
function report(name, scanner, category, extra = {}) {
  return { id: id(name), scanner, scannerName: sources.find(source => source.id === scanner).name,
    date: '2026-11-17', time: '08:00:00', filename: 'SYNTHETIC_' + name + '.pdf',
    title: sources.find(source => source.id === scanner).name + ' — Synthetic ' + category + ' QA',
    category, pending: false, decision: 'Automatic', filingState: 'Filed', stamp: id('stamp:' + name),
    isReference: false, hasReferenceEvidence: false, available: true,
    content: { status: 'Recognized', profileName: 'Synthetic constancy example', components: [], measurements: [] }, ...extra };
}
const daily = report('DAILY_FILING_QUESTION', 'CT_Edge', 'Daily', {
  pending: true, decision: 'Pending', filingState: 'NeedsReview', approvalCategory: 'Daily',
  filingReason: 'Synthetic filing question only', filingBasis: 'ManualReview', groupingReason: 'ManualReview' });
const monthly = report('MONTHLY_FILING_QUESTION', 'CT_Flash', 'Monthly', {
  pending: true, decision: 'Pending', filingState: 'NeedsReview', approvalCategory: 'Monthly',
  filingReason: 'Synthetic filing question only', filingBasis: 'ManualReview', groupingReason: 'ManualReview' });
const unknown = report('UNLABELLED_FILING_QUESTION', 'CT_Edge', 'Needs_Review', {
  pending: true, decision: 'Pending', filingState: 'NeedsReview', approvalCategory: '', approvalNeedsCategory: true,
  filingReason: 'Synthetic unknown layout', filingBasis: 'Unsupported', groupingReason: 'Unsupported' });
const filed = report('AUTOMATIC_DAILY', 'CT_Drive', 'Daily', { inferred: true, filingReason: 'Synthetic inferred filing; not clinical approval' });
const records = [daily, monthly, unknown, filed];
const snapshot = { version: '5.7.11', setupComplete: true, previewMode: 'windows',
  workspace: 'Synthetic frontend fixture only', archiveRoot: 'Synthetic sample only', records,
  today: { date: '2026-11-17', received: 1, expected: 3, headline: 'Synthetic UI check',
    scanners: sources.map(source => ({ scanner: source.id, received: source.id === filed.scanner, required: true })) },
  scanners: sources.map(source => ({ ...source, status: 'Unknown', message: 'Synthetic fixture only', dailySchedule: 'AllDays', activeFrom: '2026-01-01', excludedDates: [], expectedMonthly: true, monthlyDueDay: 20 })),
  months: [], analysis: { total: records.length, cached: records.length, pending: 0, errors: 0, backlogPending: 0 },
  undoBatch: { batchId: id('prior-batch'), batchStamp: id('prior-batch-stamp'), count: 2, action: 'Approve' },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const checks = [], errors = [], externalRequests = [], mutations = [], previews = [], jobs = [], screenshots = [];
const beforeDecisions = new Map();
const result = { syntheticOnly: true, scope: 'One synthetic Chromium frontend flow. Production HTML/CSS/JS with generated PNG previews and simulated API filing jobs. Covers document-first Review layout and existing guarded request payloads; does not validate actual backend transactions, Windows PDF rendering, hospital deployment, scanner I/O, clinical evidence or performance.', checks, errors, externalRequests, mutations, screenshots };
let browser, server;
function check(condition, name, actual) { assert.ok(condition, name); checks.push({ name, result: 'PASS', ...(actual === undefined ? {} : { actual }) }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS', actual }); }
function json(response, value, status = 200) { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify(value)); }
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
function simulatedAction(body) {
  const jobId = id('job:' + jobs.length), record = records.find(row => row.id === body.id);
  let decision = {};
  if (body.action === 'Settings') Object.assign(snapshot.settings, body);
  else if (['Approve', 'Disapprove'].includes(body.action) && !body.selections) {
    assert.ok(record && record.pending && record.stamp === body.stamp, 'Synthetic server accepts only matching pending identities');
    const previous = { ...record }, reviewId = id('review:' + jobs.length);
    beforeDecisions.set(reviewId, previous);
    record.category = body.action === 'Disapprove' ? 'Other' : body.category || record.approvalCategory;
    record.pending = false; record.filingState = 'Filed'; record.decision = body.action === 'Approve' ? 'Approved' : 'Disapproved';
    record.stamp = id('new-stamp:' + jobs.length);
    decision = { recordId: record.id, reviewId, stamp: record.stamp, action: body.action };
    snapshot.lastDecision = decision;
  } else if (body.action === 'Undo' && body.id) {
    assert.ok(record && record.stamp === body.stamp && beforeDecisions.has(body.reviewId), 'Synthetic Undo identifies its simulated filing decision');
    Object.assign(record, beforeDecisions.get(body.reviewId)); snapshot.lastDecision = null;
  } else throw Error('Unexpected synthetic action: ' + JSON.stringify(body));
  jobs.push({ id: jobId, action: body.action, status: 'Completed', result: { decision, message: 'Synthetic frontend job only' } });
  return { id: jobId };
}
async function startServer() {
  const pngBase64 = portraitPng().toString('base64');
  server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1'), pathname = url.pathname;
      if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
      if (pathname === '/api/snapshot') return json(response, snapshot);
      if (pathname === '/api/jobs') return json(response, { jobs });
      if (pathname === '/api/monthly') return json(response, { month: url.searchParams.get('month'), today: snapshot.today.date, scanners: [], componentOptions: [] });
      if (pathname === '/api/actions') { let text = ''; for await (const chunk of request) text += chunk; const body = JSON.parse(text); mutations.push(body); return json(response, simulatedAction(body)); }
      if (pathname.startsWith('/api/preview/')) {
        const recordId = pathname.slice('/api/preview/'.length), pageNumber = Number(url.searchParams.get('page'));
        if (!records.some(row => row.id === recordId) || ![0, 1, 2].includes(pageNumber)) return json(response, { error: 'Unknown synthetic preview' }, 404);
        previews.push({ recordId, pageNumber }); return json(response, { recordId, pageNumber, pageCount: 3, pngBase64 });
      }
      if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
      const file = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/app.css': 'app.css', '/trends.js': 'trends.js' }[pathname];
      if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
      response.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : file.endsWith('.css') ? 'text/css' : 'application/javascript' });
      response.end(fs.readFileSync(path.join(webRoot, file)));
    } catch (error) { errors.push({ type: 'synthetic-server', message: error.message }); json(response, { error: error.message }, 400); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
const nav = (page, name) => page.locator('.main-nav button[data-page="' + name + '"]');
async function loaded(page, record) {
  await page.waitForFunction(recordId => {
    const image = document.getElementById('pdf-image');
    return document.getElementById('pdf-area').dataset.recordId === recordId && image && !image.hidden && image.complete && image.naturalWidth === 612;
  }, record.id);
}
async function openRecord(page, record, filing = true) {
  await nav(page, 'reports').click(); await page.locator('#reports-library-view').click(); await page.locator('#clear-filters').click();
  await page.locator('#report-search').fill(record.filename);
  await page.locator('#report-list button[data-record-id="' + record.id + '"]').click(); await loaded(page, record);
  if (filing) { await nav(page, 'review').click(); await loaded(page, record); }
}
async function settle(page) { await page.waitForFunction(() => document.getElementById('review-save-status').hidden && document.getElementById('refresh-button').textContent.includes('Update reports')); }
async function reachable(page, selector) {
  const element = page.locator(selector); await element.scrollIntoViewIfNeeded(); const box = await element.boundingBox(), viewport = page.viewportSize();
  return box && box.width >= 30 && box.height >= 24 && box.x >= -1 && box.x + box.width <= viewport.width + 1 && box.y >= -1 && box.y + box.height <= viewport.height + 1;
}
async function screenshot(page, name) { const file = path.join(output, name + '.png'); await page.screenshot({ path: file, fullPage: true }); screenshots.push(file); }
(async () => {
  try {
    const origin = await startServer();
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    const context = await browser.newContext({ viewport: { width: 1366, height: 768 }, locale: 'en-US' });
    await context.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && url.origin !== origin) { externalRequests.push(url.href); return route.abort(); } return route.continue(); });
    const page = await context.newPage(); page.on('pageerror', error => errors.push({ type: 'pageerror', message: error.message }));
    page.on('console', message => { if (message.type() === 'error') errors.push({ type: 'console', message: message.text() }); });
    await page.goto(origin + '/#session=synthetic-document-first-only', { waitUntil: 'networkidle' });
    await openRecord(page, daily);
    check(await page.locator('#review-control-rail').isHidden() && await page.locator('#review-actions').isVisible(), 'Pending Review starts with its queue closed and filing controls available');
    const documentGeometry = await page.locator('.review-document').boundingBox();
    check(documentGeometry.width >= 800, 'Closed queue gives the PDF a broad document area at1366px', documentGeometry);
    check(await page.locator('#review-current-actions').evaluate(node => Boolean(node.closest('#review-filing-bar')) && Boolean(node.closest('.review-document'))), 'Single-file actions live in the document filing bar');
    check(await page.locator('#review-filing-bar').evaluate(node => {
      const area = document.getElementById('pdf-area'); return Boolean(area.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING);
    }), 'Filing bar follows the continuous PDF preview');
    same(await page.locator('#preview-zoom').inputValue(), '100', 'New PDFs retain100% default zoom');
    same(await page.locator('.pdf-page').count(), 3, 'Continuous preview retains all three generated pages');
    await page.locator('#review-queue-toggle').click();
    const queuedGeometry = await page.locator('.review-document').boundingBox();
    check(await page.locator('#review-control-rail').isVisible() && queuedGeometry.width < documentGeometry.width, 'Opening review groups reveals the existing queue beside the document');
    await page.locator('#review-queue-toggle').click();
    await page.locator('#review-change-type').click();
    same(await page.locator('#review-target-type option').evaluateAll(nodes => nodes.map(node => node.value).filter(Boolean)), ['Daily', 'Monthly', 'Other'], 'Choose another type exposes existing Daily/Monthly/Other choices');
    for (const category of ['Daily', 'Monthly', 'Other']) {
      if (!await page.locator('#review-target-type').isVisible()) await page.locator('#review-change-type').click();
      await page.locator('#review-target-type').selectOption(category);
      check((await page.locator('#approve-button').innerText()).includes(category), 'File action identifies the explicit ' + category + ' target');
    }
    if (!await page.locator('#review-target-type').isVisible()) await page.locator('#review-change-type').click();
    await page.locator('#review-target-type').selectOption('Monthly');
    check(await reachable(page, '#approve-button') && await reachable(page, '#review-change-type'), 'File and Choose another type are reachable below the PDF');
    await page.evaluate(() => { const button = document.getElementById('approve-button'); button.click(); button.click(); });
    await page.waitForFunction(() => !document.getElementById('undo-bar').hidden); await settle(page);
    const filings = mutations.filter(body => body.action === 'Approve');
    same(filings, [{ action: 'Approve', id: daily.id, stamp: id('stamp:DAILY_FILING_QUESTION'), category: 'Monthly' }], 'Repeated current-file clicks submit exactly one guarded explicit filing payload');
    check(await reachable(page, '#undo-button') && await reachable(page, '#undo-batch-button'), 'Single Undo and existing batch Undo remain reachable');
    await page.locator('#undo-button').click(); await settle(page); await loaded(page, daily);
    const undos = mutations.filter(body => body.action === 'Undo');
    check(undos.length === 1 && undos[0].id === daily.id && undos[0].reviewId && undos[0].stamp, 'Undo preserves the same record, saved decision reference and stamp');
    await openRecord(page, unknown);
    check(await page.locator('#review-target-type').isVisible() && await page.locator('#approve-button').isDisabled(), 'Uncertain type still requires an explicit choice before filing');
    await openRecord(page, filed);
    check(await page.locator('#review-type-choices').isHidden(), 'Switching from an untyped PDF to an already filed PDF hides the stale type chooser');
    await openRecord(page, unknown);
    await page.locator('#disapprove-button').click(); await settle(page);
    same(mutations.filter(body => body.action === 'Disapprove'), [{ action: 'Disapprove', id: unknown.id, stamp: id('stamp:UNLABELLED_FILING_QUESTION') }], 'Keep as Other sends the existing guarded decline payload');
    await openRecord(page, daily); await page.locator('#review-queue-toggle').click();
    for (const record of [daily, monthly]) {
      const checkbox = page.locator('.review-row-checkbox[data-record-id="' + record.id + '"]');
      const group = page.locator('.review-reason-group').filter({ has: checkbox });
      if (!await group.evaluate(node => node.open)) await group.locator(':scope>summary').click();
      await checkbox.check();
    }
    check(await page.locator('#review-selection-tools').isVisible() && await reachable(page, '#approve-selected-button') && await reachable(page, '#disapprove-selected-button'), 'Existing batch choices are available when reports are selected');
    await page.locator('#review-clear-selection').click(); await page.locator('#review-queue-toggle').click();
    for (const theme of ['Light', 'Dark']) {
      if (await page.locator('html').getAttribute('data-theme') !== theme.toLowerCase()) { await page.locator('#theme-toggle').click(); await settle(page); }
      await openRecord(page, daily); await page.locator('#approve-button').scrollIntoViewIfNeeded();
      check(await reachable(page, '#approve-button') && await reachable(page, '#review-change-type') && await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1), theme + ' Review keeps both primary controls reachable without horizontal overflow at1366×768');
      await screenshot(page, 'review-pending-' + theme.toLowerCase() + '-1366x768');
    }
    await page.setViewportSize({ width: 1024, height: 768 });
    check(await reachable(page, '#approve-button') && await reachable(page, '#review-change-type') && await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1), 'Narrow1024×768 Review keeps both primary controls reachable without document overflow');
    await screenshot(page, 'review-pending-dark-1024x768');
    await page.setViewportSize({ width: 1366, height: 768 }); await openRecord(page, filed);
    check(await page.locator('#review-actions').isHidden() && await page.locator('#review-target-panel').isHidden() && await page.locator('#review-completed').isVisible(), 'Automatically filed PDF displays a filed status without new decision controls');
    await screenshot(page, 'review-filed-dark-1366x768');
    await page.locator('.review-more-options>summary').click(); await page.locator('#viewer-open').click();
    check(await page.locator('#review-filing-bar').isHidden() && await page.locator('#review-control-rail').isHidden(), 'Existing full-view mode hides all filing controls');
    const link = page.locator('#open-pdf-link');
    check((await link.innerText()).includes('Open in new tab') && await link.getAttribute('target') === '_blank' && (await link.getAttribute('href')) === '/api/pdf/' + filed.id + '#zoom=100', 'External PDF control clearly labels a new tab and retains selected identity100%');
    await page.locator('#review-evidence-toggle').click();
    check(await page.locator('#review-evidence-drawer').isVisible(), 'Existing Report details drawer remains available in full view');
    await page.locator('#review-evidence-close').click(); await page.locator('#viewer-back').click();
    check(await page.locator('#review-filing-bar').isVisible() && await page.locator('#review-actions').isHidden(), 'Back restores filed Review without enabling filing actions');
    check(errors.length === 0 && externalRequests.length === 0 && await page.locator('#error-banner').isHidden(), 'Focused frontend flow has no browser errors, unexpected API calls or external requests');
    result.status = 'PASS';
  } catch (error) { result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1; }
  finally {
    if (browser) await browser.close(); if (server) await new Promise(resolve => server.close(resolve));
    result.testedFiles = Object.fromEntries(['App/Web/app.js', 'App/Web/app.css', 'App/Web/index.html'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(product, file))).digest('hex')]));
    result.previews = previews;
    fs.writeFileSync(path.join(output, 'Chromium.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length, output, failure: result.failure }, null, 2) + '\n');
  }
})();
