/* Development-only synthetic browser benchmark. No Node or test bridge is shipped. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const assets = path.resolve(args.assets || path.join(__dirname, '../../App/Web'));
const output = path.resolve(args.output || path.join(__dirname, '../../artifacts/library-performance.json'));
const baseline = args.baseline === 'true';
const counts = (args.counts || '1367,20000').split(',').map(Number);
const budgetMs = Number(args['budget-ms'] || 120000);
let snapshot, submitted = [], assertions = 0;
function check(condition, message) { assertions++; if (!condition) throw Error(message); }
function makeSnapshot(count) {
  const scanners = ['CT_Edge', 'CT_Flash', 'MDP_Building'].map((id, index) => ({
    id, name: ['Synthetic CT Edge', 'Synthetic CT Flash', 'Synthetic MDP Building'][index],
    path: 'Synthetic scanner folder', username: '', drive: '', status: 'Connected', message: 'Synthetic connected status', code: 0,
    dailySchedule: 'AllDays', activeFrom: '2024-01-01', expectedMonthly: true, monthlyDueDay: 25,
    contentProfiles: [], checklist: ['MTF', 'Slice thickness'], checklistEffectiveMonth: '', monthlyChecklistHistory: [], nextChecklistEffectiveMonth: '2026-11', excludedDates: []
  }));
  const records = Array.from({length: count}, (_, i) => {
    const scanner = scanners[i % scanners.length], category = i % 5 === 0 ? 'Monthly' : 'Daily', pending = i % 100 === 0;
    return {id: i.toString(16).padStart(64, '0'), stamp: i.toString(16).padStart(64, '0'), scanner: scanner.id, scannerName: scanner.name,
      date: `202${4 + i % 3}-${String(1 + i % 12).padStart(2, '0')}-${String(1 + i % 28).padStart(2, '0')}`, time: `${String(i % 24).padStart(2, '0')}:00:00`,
      title: `Synthetic report ${i}`, filename: `QA_Session_${String(i).padStart(5, '0')}.pdf`, category, pending,
      decision: pending ? 'Pending' : 'Automatic', filingState: pending ? 'NeedsReview' : 'Filed', filingBasis: pending ? 'Unsupported' : 'Filename',
      inferred: false, isReference: false, hasReferenceEvidence: false, approvalCategory: category, approvalNeedsCategory: false, content: {}, clinicalComponents: []};
  });
  return {version: '5.7.0', previewMode: 'Browser', workspace: 'Synthetic workspace', archiveRoot: 'Synthetic archive', libraryRoot: 'Synthetic report library', setupComplete: true,
    records, scanners, today: {date: '2026-11-16', received: 0, expected: 3, headline: '0 of 3 Daily QA reports received'},
    months: scanners.map(scanner => ({scanner: scanner.id, name: scanner.name, month: '2026-11', progress: '0 / 2 items', status: 'NoConfirmedReport', timing: 'Upcoming'})),
    analysis: {total: count, cached: 0, pending: count, errors: 0, measurementUpgradePending: 0, unsupportedUpgradePending: 0, backlogPending: count},
    trendsRevision: 'A'.repeat(64), settings: {monitorMinutes: 0, autoAnalyze: false, autoUpdateOnOpen: false, pdfReaderMode: 'Auto', theme: 'Light'},
    batchReviewLimit: 50, lastDecision: null, undoBatch: null};
}
const server = http.createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://localhost').pathname;
  response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : pathname.endsWith('.css') ? 'text/css' : pathname.startsWith('/api/') ? 'application/json' : 'text/html');
  if (pathname === '/api/snapshot') return response.end(JSON.stringify(snapshot));
  if (pathname === '/api/jobs') return response.end('{"jobs":[]}');
  if (pathname === '/api/monthly') return response.end(JSON.stringify({month: '2026-11', scanners: snapshot.scanners.map(scanner => ({
    id: scanner.id, name: scanner.name, expectedMonthly: true, applicability: 'Required',
    checklist: {requiredCount: 2, effectiveMonth: '2026-11', items: [{label: 'MTF', code: 'MTF', found: false, reportIds: []}, {label: 'Slice thickness', code: 'SliceThickness', found: false, reportIds: []}]},
    receipt: {count: 0, waitingCount: 0, reviewCount: 0}, detected: {foundCount: 0, requiredCount: 2},
    reviewed: {confirmedReportCount: 0, requiredComponents: ['MTF', 'SliceThickness'], confirmedComponents: []}, due: {date: '2026-11-25', timing: 'Upcoming'}, reports: []
  }))}));
  if (pathname === '/api/session' || pathname === '/api/heartbeat') return response.end('{}');
  if (pathname === '/api/actions') {
    let body = ''; for await (const chunk of request) body += chunk;
    submitted.push(JSON.parse(body)); response.statusCode = 202; return response.end('{"id":"synthetic-job"}');
  }
  const file = path.join(assets, pathname === '/' ? 'index.html' : pathname.slice(1));
  if (!fs.existsSync(file)) { response.statusCode = 404; return response.end('{}'); }
  let content = fs.readFileSync(file);
  // Expose existing functions only in this development server response. Product bytes stay unchanged.
  if (pathname === '/app.js') content = content.toString().replace('  boot().catch(', '  window.__qaBench={state,renderReports,renderSnapshot,refreshSnapshot,filteredRecords,showPage,clearFilters,copyReportsToExports,renderMonthly};\n  boot().catch(');
  response.end(content);
});
(async () => {
  fs.mkdirSync(path.dirname(output), {recursive: true});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const launch = {headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage']};
  if (args['browser-channel']) launch.channel = args['browser-channel']; else launch.executablePath = args.chromium || '/usr/bin/chromium';
  const browserServer = await chromium.launchServer(launch);
  const browser = await chromium.connect(browserServer.wsEndpoint());
  const summary = {syntheticOnly: true, baseline, browser: browser.version(), node: process.version, platform: process.platform, architecture: process.arch,
    assetHashes: Object.fromEntries(['app.js','index.html','app.css','trends.js'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(assets,file))).digest('hex')])),
    scope: 'Production browser assets with deterministic synthetic API responses and a response-only test bridge. No PowerShell, real scanner, PDF reader, native Windows DPI or hospital throughput claim. Timings include layout and are diagnostic. JS heap excludes native DOM/browser memory.',
    budgetMs, assertions: 0, failed: 0, results: []};
  const save = () => { summary.assertions = assertions; fs.writeFileSync(output, JSON.stringify(summary, null, 2) + '\n'); };
  try {
    for (const count of counts) {
      snapshot = makeSnapshot(count); submitted = [];
      const page = await browser.newPage({viewport: {width: 1440, height: 1000}}), errors = [], external = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.route('**/*', route => { const url = new URL(route.request().url()); if (['http:', 'https:'].includes(url.protocol) && url.hostname !== '127.0.0.1') {external.push(url.hostname); route.abort();} else route.continue(); });
      let timeout;
      try {
        const result = await Promise.race([(async () => {
          await page.goto(`http://127.0.0.1:${server.address().port}/#session=synthetic-benchmark`);
          await page.waitForFunction(n => window.__qaBench?.state.records.length === n, count);
          return await page.evaluate(async count => {
            const {state, renderSnapshot, showPage} = window.__qaBench;
            clearInterval(state.poll); clearInterval(state.heartbeat);
            const measure = fn => { const start = performance.now(); fn(); document.body.offsetHeight; return performance.now() - start; };
            const openReportsMs = measure(() => showPage('reports')), renderedRows = document.querySelectorAll('.report-item').length, totalDomNodes = document.querySelectorAll('*').length;
            const list = document.getElementById('report-list'), first = list.firstElementChild;
            let childMutations = 0;
            const observer = new MutationObserver(entries => {childMutations += entries.reduce((n, entry) => n + entry.addedNodes.length + entry.removedNodes.length, 0);});
            observer.observe(list, {childList: true});
            const unchangedSnapshotMs = measure(() => renderSnapshot()); await Promise.resolve(); observer.disconnect();
            const retainedFirstRow = list.firstElementChild === first, search = document.getElementById('report-search');
            let searchListReplacements = 0, searchLastMutationAt = 0;
            const searchStarted = performance.now(), searchObserver = new MutationObserver(entries => { searchListReplacements += entries.length; searchLastMutationAt = performance.now(); });
            searchObserver.observe(list, {childList: true});
            for (const query of ['s', 'sy', 'syn', 'synt', 'synth', 'synthe']) {search.value = query; search.dispatchEvent(new Event('input', {bubbles: true}));}
            const rapidInputDispatchMs = performance.now() - searchStarted;
            await new Promise(resolve => setTimeout(resolve, 300)); document.body.offsetHeight; searchObserver.disconnect();
            return {count, openReportsMs, unchangedSnapshotMs, rapidInputDispatchMs, rapidSearchSettledMs: searchLastMutationAt ? searchLastMutationAt - searchStarted : null,
              renderedRows, totalDomNodes, unchangedSnapshotChildMutations: childMutations, unchangedSnapshotRetainedFirstRow: retainedFirstRow,
              matching: state.matching.length, searchRenderedRows: document.querySelectorAll('.report-item').length, searchListReplacements};
          }, count);
        })(), new Promise((_, reject) => {timeout = setTimeout(() => reject(Error('Synthetic frontend workload exceeded its time budget.')), budgetMs);})]);
        clearTimeout(timeout);
        const cdp = await page.context().newCDPSession(page); await cdp.send('HeapProfiler.collectGarbage'); result.jsHeapUsedBytes = (await cdp.send('Runtime.getHeapUsage')).usedSize;
        result.javascriptErrors = errors; result.externalRequests = external.length;
        check(result.matching === count, 'Search retains every matching synthetic record.'); check(!errors.length && !external.length, 'No JavaScript errors or external requests.');
        if (!baseline) {
          check(result.renderedRows === Math.min(count, 100) && result.searchRenderedRows === Math.min(count, 100), 'Only one bounded report page is rendered.');
          check(result.unchangedSnapshotChildMutations === 0 && result.unchangedSnapshotRetainedFirstRow, 'Unchanged snapshots preserve existing report nodes.');
          check(result.searchListReplacements === 1, 'Rapid search inputs coalesce into one list replacement.');
          await verifyWorkflow(page, count);
        }
        result.result = 'PASS'; summary.results.push(result); save(); console.log('PASS ' + count + ': ' + JSON.stringify(result));
      } catch (error) {
        clearTimeout(timeout); summary.failed++; summary.results.push({count, result: 'FAIL', reason: error.message, javascriptErrors: errors, externalRequests: external.length}); save();
        console.log('FAIL ' + count + ': ' + error.message);
        // A baseline may hang while building an unbounded DOM; closing its page is bounded separately.
        await Promise.race([page.close().catch(() => {}), new Promise(resolve => setTimeout(resolve, 1000))]);
        if (!baseline) process.exitCode = 1;
        if (baseline && error.message.includes('time budget')) { await browserServer.kill(); break; }
      }
      if (!page.isClosed()) await page.close();
    }
  } finally { save(); await browser.close().catch(() => {}); await browserServer.close().catch(() => {}); server.close(); }
})().catch(error => {console.error(error.message); process.exitCode = 1; server.close();});
async function verifyWorkflow(page, count) {
  await page.locator('.report-item').nth(4).focus(); await page.keyboard.press('ArrowDown');
  await page.locator('#reports-next').click();
  check((await page.locator('#reports-page-label').innerText()).includes('Page 2'), 'Next opens the second page.');
  check(await page.locator('.report-item').count() === 100, 'The second page stays bounded.');
  await page.keyboard.press('ArrowDown');
  check(await page.evaluate(() => window.__qaBench.state.selectedId === window.__qaBench.state.matching[101].id && window.__qaBench.state.reportPage === 1), 'ArrowDown after paging starts from a visible row instead of the previous page selection.');
  await page.keyboard.press('Enter');
  check(await page.evaluate(() => window.__qaBench.state.page === 'review' && window.__qaBench.state.selectedId === window.__qaBench.state.matching[101].id), 'Enter opens the currently focused visible report after paging.');
  await page.locator('.main-nav [data-page="reports"]').click();
  await page.locator('#report-list').press('End');
  const last = await page.evaluate(() => {const {state} = window.__qaBench; return {selected: state.selectedId, expected: state.matching.at(-1).id, page: state.reportPage, pages: Math.ceil(state.matching.length / 100)};});
  check(last.selected === last.expected && last.page === last.pages - 1, 'End reaches the last matching report across pages.');
  await page.locator('#report-list').press('Home');
  check((await page.locator('#reports-page-label').innerText()).includes('Page 1'), 'Home returns to the first matching report.');
  await page.locator('#scanner-filter').selectOption('CT_Flash');
  const scannerCount = snapshot.records.filter(record => record.scanner === 'CT_Flash').length;
  check((await page.locator('#matching-count').innerText()).includes(scannerCount.toLocaleString()), 'Scanner filtering retains its exact full count.');
  await page.locator('#type-filter').selectOption('monthly');
  const filtered = snapshot.records.filter(record => record.scanner === 'CT_Flash' && record.category === 'Monthly');
  check((await page.locator('#matching-count').innerText()).includes(filtered.length.toLocaleString()), 'Combined scanner/type filters invalidate cached results.');
  await page.locator('#report-search').fill('QA_Session_00010');
  await page.waitForFunction(() => window.__qaBench.state.matching.length === 1);
  check(await page.locator('.report-item').count() === 1 && await page.locator('#report-pagination').isHidden(), 'Filename search reaches one report and hides unnecessary pagination.');
  const original = structuredClone(snapshot.records[10]);
  try {
    Object.assign(snapshot.records[10], {filename: 'Synthetic_Changed_Record.pdf', date: '2026-12-31', stamp: 'F'.repeat(64), pending: true, decision: 'Pending', filingState: 'NeedsReview'});
    await page.evaluate(() => window.__qaBench.refreshSnapshot());
    check(await page.locator('.report-item').count() === 0, 'Changed snapshot records invalidate a previously matching filename search.');
    await page.locator('#report-search').fill('Synthetic_Changed_Record');
    await page.waitForFunction(() => window.__qaBench.state.matching.length === 1);
    check(await page.evaluate(id => {const {state} = window.__qaBench; return state.recordIndex.get(id)?.stamp === 'F'.repeat(64) && state.sortedRecords[0].id === id && state.pendingRecords.some(record => record.id === id);}, original.id), 'Changed filename, date, stamp and filing state refresh the search index, ordering, ID lookup and review queue.');
  } finally { snapshot.records[10] = original; await page.evaluate(() => window.__qaBench.refreshSnapshot()); }
  await page.locator('#clear-filters').click();
  await page.locator('#report-export-shortcut').click();
  check((await page.locator('#export-count').innerText()) === count.toLocaleString(), 'The export shortcut keeps every matching record, independent of the report page.');
  check(await page.locator('.export-preview-row').count() === 12, 'Exports retains its existing twelve-row preview.');
  await page.locator('#export-button').click();
  await page.waitForTimeout(50);
  const exported = submitted.find(request => request.action === 'Export');
  check(exported?.ids.length === count && new Set(exported.ids).size === count, 'The submitted export contains all matching unique IDs, never just the visible page.');
  // Reuse a same-origin browser tab to prove that the display preference survives reload.
  await page.locator('.main-nav [data-page="settings"]').click(); await page.locator('[data-settings-tab="reading"]').click();
  await page.locator('#display-density').selectOption('compact');
  check(await page.evaluate(() => document.documentElement.dataset.density === 'compact' && localStorage.getItem('ctqa.density') === 'compact'), 'Compact density is a browser preference and is saved.');
  await page.reload(); await page.waitForFunction(n => window.__qaBench?.state.records.length === n, count);
  check(await page.evaluate(() => document.documentElement.dataset.density === 'compact'), 'Saved density survives a reload.');
  await page.locator('.main-nav [data-page="monthly"]').click();
  await page.waitForFunction(() => document.getElementById('monthly-workspace-status').dataset.month === '2026-11' && document.getElementById('monthly-workspace-status').dataset.loading === 'false');
  const groups = page.locator('.monthly-document-scanner');
  check(await groups.count() === 3 && await groups.first().evaluate(node => node.open), 'Monthly provides three compact scanner summaries with the first expanded.');
  await groups.nth(1).locator('summary').press('Enter');
  check(await groups.nth(1).evaluate(node => node.open), 'A Monthly scanner expands using the keyboard.');
  await page.evaluate(() => window.__qaBench.renderMonthly({load: false}));
  check(await groups.nth(1).evaluate(node => node.open), 'Expanded Monthly details survive a background-style rerender.');
  await page.locator('#monthly-scanner').selectOption('MDP_Building');
  check(await groups.count() === 1 && await groups.first().evaluate(node => node.open), 'Choosing one scanner opens its details directly.');
}
