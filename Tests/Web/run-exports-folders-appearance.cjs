/* Development-only presentation check with production frontend assets and static
 * synthetic API responses. Submitted Export/Browse actions are recorded only;
 * no backend, files, ZIPs, scanner access, PDF reading or native runtime runs.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const webRoot = path.resolve(__dirname, '../../App/Web');
const output = path.resolve(process.argv[2] || '/tmp/ctqa-exports-folders-browser');
fs.mkdirSync(output, { recursive: true });
const fixtureDate = '2026-11-16';
const sources = [{ id: 'CT_Edge', name: 'CT Edge' }, { id: 'CT_Flash', name: 'CT Flash' }];
const hash = value => crypto.createHash('sha256').update('synthetic-exports-folders:' + value).digest('hex');
const records = [];
for (const scanner of sources) for (const year of ['2025', '2026']) for (const month of ['05', '11']) {
  for (const [index, category] of ['Daily', 'Monthly', 'Other'].entries()) {
    const name = `SYNTHETIC_${scanner.id}_${year}_${month}_${category}`;
    records.push({ id: hash(name), scanner: scanner.id, scannerName: scanner.name,
      date: `${year}-${month}-${String(index + 1).padStart(2, '0')}`, time: '08:00:00',
      filename: name + '.pdf', title: 'Synthetic presentation fixture', category,
      pending: false, decision: 'Automatic', filingState: 'Filed', stamp: hash(name + ':stamp'),
      isReference: false, hasReferenceEvidence: false, available: true,
      content: { status: 'Read', completeRead: true, pages: 1, readPages: 1 } });
  }
}
const sorted = records.slice().sort((a, b) => b.date.localeCompare(a.date) ||
  b.time.localeCompare(a.time) || a.scanner.localeCompare(b.scanner));
const snapshot = { version: '5.7.7', setupComplete: true, workspace: 'Synthetic presentation fixture',
  archiveRoot: 'Synthetic sample only', libraryRoot: 'Synthetic sample/Report Library', records,
  today: { date: fixtureDate, received: 0, expected: 2, headline: 'Synthetic saved report library',
    scanners: sources.map(source => ({ scanner: source.id, received: false, required: true })) },
  scanners: sources.map(source => ({ ...source, dailySchedule: 'AllDays', activeFrom: '2025-01-01',
    excludedDates: [], expectedMonthly: true, monthlyDueDay: 20, checklist: ['Noise', 'Slice'],
    checklistEffectiveMonth: '0001-01', status: 'Connected', message: 'Synthetic sample; no connection is made' })),
  months: [], analysis: { total: records.length, cached: records.length, pending: 0, errors: 0, backlogPending: 0 },
  settings: { theme: 'Light', autoAnalyze: false, autoUpdateOnOpen: false, monitorMinutes: 0 } };
const checks = [], errors = [], externalRequests = [], submitted = [], jobs = [];
const result = { syntheticOnly: true,
  scope: 'Focused presentation check of production Exports/Folders frontend, Monthly panel visibility and Reports calendar/library reachability using static synthetic HTTP responses. Export and Browse payloads are recorded by the stub; no backend, ZIP creation, archive, scanner, PDF reader, native Windows runtime or clinical QA validation runs.',
  checks, errors, externalRequests, submitted, screenshots: [], sourceHashes: Object.fromEntries(
    ['index.html', 'app.css', 'app.js', 'trends.js'].map(file => [file, crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(webRoot, file))).digest('hex')])) };
let browser, server;
function check(value, name) { assert.ok(value, name); checks.push({ name, result: 'PASS' }); }
function same(actual, expected, name) { assert.deepEqual(actual, expected, name); checks.push({ name, result: 'PASS' }); }
function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
async function startServer() {
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1'), pathname = url.pathname;
    if (pathname === '/api/session' || pathname === '/api/heartbeat') return json(response, { ok: true });
    if (pathname === '/api/snapshot') return json(response, snapshot);
    if (pathname === '/api/jobs') return json(response, { jobs });
    if (pathname === '/api/monthly') return json(response, { month: url.searchParams.get('month'),
      today: fixtureDate, scanners: [], componentOptions: [] });
    if (pathname === '/api/actions') {
      let body = ''; for await (const chunk of request) body += chunk;
      const payload = JSON.parse(body); submitted.push(payload);
      if (!['Export', 'Browse'].includes(payload.action)) return json(response, { error: 'Unexpected synthetic action' }, 400);
      const id = 'synthetic-recorded-' + submitted.length;
      jobs.push({ id, action: payload.action, status: 'Completed',
        result: { message: 'Synthetic action recorded only; no files written.' } });
      return json(response, { id }, 202);
    }
    if (pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    const file = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js',
      '/app.css': 'app.css', '/trends.js': 'trends.js' }[pathname];
    if (!file) return json(response, { error: 'Unexpected synthetic route: ' + pathname }, 404);
    response.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' :
      file.endsWith('.css') ? 'text/css' : 'application/javascript' });
    response.end(fs.readFileSync(path.join(webRoot, file)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return 'http://127.0.0.1:' + server.address().port;
}
const nav = (page, name) => page.locator('.main-nav button[data-page="' + name + '"]').click();
async function setOpen(details, open) {
  if (await details.evaluate(node => node.open) !== open) await details.locator(':scope > summary').click();
}
async function screenshot(page, name) {
  await page.evaluate(() => { scrollTo(0, 0); return new Promise(requestAnimationFrame); });
  const filename = path.join(output, name); await page.screenshot({ path: filename, fullPage: true });
  result.screenshots.push(filename);
}
async function countIs(page, count, name) {
  await page.waitForFunction(expected => document.getElementById('export-count').textContent === String(expected), count);
  same(await page.locator('#export-count').innerText(), String(count), name);
  check((await page.locator('#export-preview-count').innerText()).includes(String(count)), name + ' also appears in preview summary');
}
async function fits(page, selector) {
  const control = page.locator(selector); await control.scrollIntoViewIfNeeded();
  check(await control.isVisible() && await control.isEnabled(), selector + ' is available at 1024px');
  await control.focus();
  check(await control.evaluate(node => node === document.activeElement && node.getBoundingClientRect().left >= 0 &&
    node.getBoundingClientRect().right <= innerWidth), selector + ' can receive keyboard focus within the narrow viewport');
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
    await page.goto(origin + '/#session=synthetic-exports-folders-only', { waitUntil: 'networkidle' });
    await page.waitForFunction(count => Number(document.getElementById('report-total').textContent) === count, records.length);
    for (const selector of ['#monthly-reviewed-details', '#monthly-setup-panel', '#monthly-document-coverage']) {
      same(await page.locator(selector).evaluate(node => node.hidden), true, selector + ' stays hidden in the DOM');
    }
    await nav(page, 'reports');
    check(await page.locator('#daily-calendar').isVisible() && await page.locator('#reports-library-panel').isHidden(),
      'Reports opens its receipt calendar first');
    await page.locator('#reports-library-view').click();
    check(await page.locator('#reports-library-panel').isVisible(), 'Report library remains reachable through its view control');
    same(await page.locator('#report-list button[data-record-id]').count(), records.length,
      'Report library retains every synthetic report');
    await nav(page, 'exports');
    const preview = page.locator('#export-preview-panel');
    same(await preview.evaluate(node => ({ tag: node.tagName, open: node.open })),
      { tag: 'DETAILS', open: false }, 'Export preview is a native disclosure collapsed by default');
    check((await preview.locator(':scope > summary').innerText()).includes('Preview included reports'), 'Export preview has a clear summary');
    await countIs(page, records.length, 'Default package count includes every synthetic report');
    check(await page.locator('#export-preview-list').isHidden(), 'Preview rows remain hidden while collapsed');
    check(await page.locator('#export-clear-filters').isVisible(), 'Clear export filters stays visible with preview closed');
    await screenshot(page, 'exports-light-1440.png');
    await setOpen(preview, true);
    const previewNames = await page.locator('#export-preview-list .export-preview-title').allTextContents();
    same(previewNames, sorted.slice(0, 12).map(row => row.filename), 'Opening preview preserves the same first twelve report filenames and order');
    result.initialPreview = sorted.slice(0, 12).map(row => ({ id: row.id, filename: row.filename }));
    check((await page.locator('#export-preview-list').innerText()).includes('Showing 12 of 24'), 'Preview keeps the twelve-row limit and complete-export explanation');
    await setOpen(preview, false);
    await page.locator('#export-scanner-filter').selectOption('CT_Flash');
    await countIs(page, 12, 'Scanner filter updates package count');
    await page.locator('#export-year-filter').selectOption('2026');
    await countIs(page, 6, 'Year filter updates package count');
    await page.locator('#export-month-filter').selectOption('11');
    await countIs(page, 3, 'Month filter updates package count');
    await page.locator('#export-type-filter').selectOption('monthly');
    await countIs(page, 1, 'QA type filter updates package count');
    const selected = sorted.filter(row => row.scanner === 'CT_Flash' && row.date.startsWith('2026-11') && row.category === 'Monthly');
    await setOpen(preview, true);
    same(await page.locator('#export-preview-list .export-preview-title').allTextContents(),
      selected.map(row => row.filename), 'Filtered preview contains the original matching report');
    await setOpen(preview, false);
    const exportRequest = page.waitForRequest(request => new URL(request.url()).pathname === '/api/actions' &&
      request.method() === 'POST' && request.postDataJSON().action === 'Export');
    await page.locator('#export-button').click();
    same((await exportRequest).postDataJSON(), { action: 'Export', ids: selected.map(row => row.id) },
      'Export submits exactly the selected synthetic IDs to the recording stub');
    await page.locator('#job-dismiss').waitFor({ state: 'visible' });
    await page.locator('#job-dismiss').click();
    await page.locator('#export-clear-filters').click();
    await countIs(page, records.length, 'Visible clear filters restores all reports with preview closed');
    same(await preview.evaluate(node => node.open), false, 'Filtering and clearing keep preview closed');
    await nav(page, 'folders');
    check(await page.getByRole('heading', { name: 'Browse by scanner', exact: true }).isVisible(), 'Folders uses Browse by scanner heading');
    const location = page.locator('.folder-location-details');
    same(await location.evaluate(node => ({ tag: node.tagName, open: node.open })),
      { tag: 'DETAILS', open: false }, 'Library location is a native disclosure collapsed by default');
    check(await page.locator('#folders-library-location').isHidden(), 'Library path is hidden until requested');
    same(await page.locator('#folders-pdf-count').innerText(), String(records.length), 'Folder total remains unchanged');
    same(await page.locator('#folders-scanner-count').innerText(), '2 scanners', 'Folder scanner total remains unchanged');
    await screenshot(page, 'folders-light-1440.png');
    await setOpen(location, true);
    same(await page.locator('#folders-library-location').innerText(), snapshot.libraryRoot, 'Opening location shows the original synthetic library path');
    await setOpen(location, false);
    same(await page.locator('#folder-library-tree > .folder-machine').count(), 2, 'Folder tree retains both scanners');
    for (const scanner of sources) {
      const machine = page.locator('#folder-library-tree > details[data-folder-key="' + scanner.id + '"]');
      await setOpen(machine, true);
      check((await machine.locator(':scope > summary').innerText()).includes(scanner.name), scanner.name + ' tree name remains');
      same(await machine.locator(':scope > summary .folder-tree-count').innerText(), '12 PDFs', scanner.name + ' scanner count remains');
      same(await machine.locator(':scope > .folder-year').count(), 2, scanner.name + ' keeps both year targets');
      for (const year of ['2025', '2026']) {
        const yearNode = machine.locator(':scope > details[data-folder-key="' + scanner.id + '/' + year + '"]');
        await setOpen(yearNode, true);
        same((await yearNode.locator(':scope > summary').innerText()).trim(), year, scanner.name + ' year target ' + year);
        same(await yearNode.locator(':scope > .folder-month').count(), 2, scanner.name + '/' + year + ' keeps both months');
        for (const [month, label] of [['05', '05 - May'], ['11', '11 - November']]) {
          const monthNode = yearNode.locator(':scope > details[data-folder-key="' + scanner.id + '/' + year + '/' + month + '"]');
          await setOpen(monthNode, true);
          same((await monthNode.locator(':scope > summary').innerText()).trim(), label, scanner.name + '/' + year + '/' + month + ' target label');
          same(await monthNode.locator('.folder-category > span:first-child').allTextContents(),
            ['Daily', 'Monthly', 'Other'], scanner.name + '/' + year + '/' + month + ' keeps all categories');
          same(await monthNode.locator('.folder-category .folder-tree-count').allTextContents(),
            ['1 PDFs', '1 PDFs', '1 PDFs'], scanner.name + '/' + year + '/' + month + ' category counts remain');
        }
      }
    }
    const transfers = page.locator('.folder-transfer-options'); await setOpen(transfers, true);
    check(await page.locator('#folders-export-all-button').isVisible() && await page.locator('#folders-export-all-button').isEnabled(), 'Full library export remains available');
    check(await page.locator('#folders-backup-button').isVisible() && await page.locator('#folders-backup-button').isEnabled(), 'Full backup remains available');
    const beforeBrowse = submitted.length;
    const browseRequest = page.waitForRequest(request => new URL(request.url()).pathname === '/api/actions' &&
      request.method() === 'POST' && request.postDataJSON().action === 'Browse');
    await page.locator('#folders-open-button').click();
    same((await browseRequest).postDataJSON(), { action: 'Browse' }, 'Open organized folders submits Browse only');
    await page.locator('#job-dismiss').waitFor({ state: 'visible' });
    await page.locator('#job-dismiss').click();
    same(submitted.length, beforeBrowse + 1, 'Opening folders sends exactly one recorded action');
    snapshot.settings.theme = 'Dark';
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
    await nav(page, 'exports'); await screenshot(page, 'exports-dark-1440.png');
    await nav(page, 'folders'); await screenshot(page, 'folders-dark-1440.png');
    await page.setViewportSize({ width: 1024, height: 1100 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Folders has no horizontal overflow at 1024px');
    await fits(page, '#folders-open-button');
    await page.evaluate(() => scrollTo(0, 0));
    await screenshot(page, 'folders-dark-1024.png');
    await nav(page, 'exports');
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Exports has no horizontal overflow at 1024px');
    for (const selector of ['#export-scanner-filter', '#export-year-filter', '#export-month-filter',
      '#export-type-filter', '#export-status-filter', '#export-search', '#export-clear-filters', '#export-button']) await fits(page, selector);
    await page.evaluate(() => scrollTo(0, 0)); await screenshot(page, 'exports-dark-1024.png');
    check(await page.locator('#error-banner').isHidden(), 'No application error banner');
    same(submitted.map(row => row.action), ['Export', 'Browse'], 'Only the two intended actions reach the recording stub');
    same(errors, [], 'No browser or JavaScript errors');
    same(externalRequests, [], 'No external asset requests');
    result.status = 'PASS';
  } catch (error) { result.status = 'FAIL'; result.failure = error.stack || String(error); process.exitCode = 1; }
  finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ status: result.status, checks: checks.length, output,
      screenshots: result.screenshots, scope: result.scope, failure: result.failure }, null, 2) + '\n');
  }
})();
