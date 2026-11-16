/* Development-only checks against the real offline host and generated PDFs. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
if (!args.root) throw new Error('Supply an explicitly synthetic fixture with --root.');
const root = path.resolve(args.root);
const output = path.resolve(args['output-dir'] || path.join(root, 'accessibility-results'));
const baseline = readJSON(path.join(root, 'fixture-baseline.json'));
if (!baseline.Synthetic) throw new Error('This check only accepts generated synthetic fixtures.');
fs.mkdirSync(output, { recursive: true });
let host, ready, browser, page, assertions = 0;
const results = [], errors = [], external = [], observations = [];
const startedAtUtc = new Date().toISOString();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase();
function readJSON(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
function clean(message) { return String(message || '').replaceAll(ready?.token || '\u0000', '[redacted session]'); }
function check(value, message) { assertions++; if (!value) throw new Error(message); }
async function until(fn, message, timeout = 90000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try { const value = await fn(); if (value) return value; } catch (error) { last = error; }
    await delay(100);
  }
  throw new Error(message + (last ? ': ' + clean(last.message) : ''));
}
async function scenario(name, fn) {
  try { await fn(); results.push({ name, result: 'PASS' }); console.log('PASS ' + name); }
  catch (error) { results.push({ name, result: 'FAIL', details: clean(error.stack) }); console.log('FAIL ' + name + ': ' + clean(error.message)); }
}
async function api(route, options = {}) {
  return fetch(new URL(route, ready.url), { ...options, headers: { 'X-Qa-Session': ready.token, ...options.headers } });
}
async function navigate(name) {
  const button = page.locator('.main-nav button[data-page="' + name + '"]');
  await button.scrollIntoViewIfNeeded();
  await button.click();
  await until(() => page.locator('body').getAttribute('data-page').then(value => value === name), 'Navigation did not select ' + name);
  if (name === 'monthly') await until(async () => await page.locator('#monthly-workspace-status').getAttribute('data-loading') === 'false', 'Monthly data did not settle.');
  if (name === 'reports') await page.locator('#reports-library-view').click();
  if (name === 'review') {
    if (await page.locator('#review-queue-toggle').getAttribute('aria-expanded') !== 'true') await page.locator('#review-queue-toggle').click();
    const first = page.locator('.review-queue-item').first();
    if (await first.count()) { const group = first.locator('xpath=ancestor::details'); if (await group.count() && !await group.evaluate(element => element.open)) await group.locator('summary').click(); await first.click(); await until(() => page.locator('#pdf-area').getAttribute('data-record-id'), 'Review did not select a saved PDF.'); }
  }
}
async function reachable(selector) {
  const locator = page.locator(selector).first();
  check(await locator.isVisible(), selector + ' is visible.');
  await locator.scrollIntoViewIfNeeded();
  const geometry = await locator.evaluate(control => {
    const box = control.getBoundingClientRect();
    return { left: box.left, top: box.top, right: box.right, bottom: box.bottom, width: box.width, height: box.height, viewportWidth: innerWidth, viewportHeight: innerHeight, font: parseFloat(getComputedStyle(control).fontSize) };
  });
  check(geometry.width >= 20 && geometry.height >= 20, selector + ' has a usable target.');
  check(geometry.left >= -1 && geometry.right <= geometry.viewportWidth + 1 && geometry.top >= -1 && geometry.bottom <= geometry.viewportHeight + 1, selector + ' can be scrolled fully into the viewport.');
  check(geometry.font >= 12, selector + ' uses readable Comfortable control text.');
}
const primary = {
  today: ['#refresh-button', '#today-calendar-button', '#monthly-overview-link'],
  monthly: ['#monthly-scanner', '#monthly-period', '#monthly-refresh'],
  reports: ['#report-search', '#scanner-filter', '#report-export-shortcut'],
  review: ['#review-queue-toggle', '#approve-button', '#disapprove-button', '#review-evidence-toggle'],
  exports: ['#export-search', '#export-scanner-filter', '#export-button'],
  folders: ['#folders-open-button'],
  trends: ['#trend-scanner', '#trend-metric', '#trend-period'],
  settings: ['#connection-scanner', '#connection-path', '#connection-username', '#connection-password']
};

(async () => {
  try {
    const parameters = ['--root', root, '--powershell', args.powershell || '/tmp/ctqa-pwsh', '--no-browser'];
    host = spawn(args.dotnet || args.host, args.dotnet ? [args.host, ...parameters] : parameters, { cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let startupError = '';
    host.stdout.on('data', () => {});
    host.stderr.on('data', bytes => { startupError = (startupError + bytes.toString()).slice(-2000); });
    await until(() => {
      if (host.exitCode !== null || host.signalCode !== null) throw new Error('Host exited before readiness: ' + clean(startupError));
      const file = path.join(root, 'Data/web-ready.json');
      if (!fs.existsSync(file)) return false;
      const value = readJSON(file);
      return value.pid === host.pid && (ready = value);
    }, 'The local host did not become ready.');
    await until(async () => { const response = await api('/api/snapshot'); return response.ok && (await response.json()).records?.length === baseline.RecordCount; }, 'The synthetic snapshot did not load.');
    // Materialize two genuine read-but-uncertain exceptions. Unread reports
    // belong to background reading, not the manual decision queue.
    const initial = await (await api('/api/snapshot')).json();
    for (const record of initial.records.filter(row => row.pending).slice(0, 2)) {
      const response = await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'Analyze', id: record.id }) });
      check(response.status === 202, 'An explicit synthetic PDF read is accepted.');
      const accepted = await response.json();
      const job = await until(async () => { const value = await (await api('/api/jobs')).json(); return value.jobs.find(row => row.id === accepted.id && ['completed', 'failed', 'cancelled'].includes(row.status)); }, 'Synthetic PDF reading did not finish.');
      check(job.status === 'completed', 'The generated PDF is read before testing filing controls.');
    }
    const launch = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (args['browser-channel']) launch.channel = args['browser-channel'];
    else launch.executablePath = args.chromium || '/usr/bin/chromium';
    browser = await chromium.launch(launch);
    const context = await browser.newContext({ viewport: { width: 1366, height: 768 } });
    page = await context.newPage();
    page.on('pageerror', error => errors.push(clean(error.message)));
    page.on('request', request => { const url = new URL(request.url()); if (['http:', 'https:'].includes(url.protocol) && url.origin !== new URL(ready.url).origin) external.push(url.origin); });
    await page.goto(ready.url + '#session=' + encodeURIComponent(ready.token), { waitUntil: 'domcontentloaded' });
    await until(async () => Number((await page.locator('#report-total').innerText()).replaceAll(',', '')) === baseline.RecordCount, 'The initial library did not render.');

    for (const theme of ['light', 'dark']) {
      if (await page.locator('html').getAttribute('data-theme') !== theme) await page.locator('#theme-toggle').click();
      await until(() => page.locator('html').getAttribute('data-theme').then(value => value === theme), 'Appearance did not switch.');
      for (const scale of [100, 125, 150, 200]) {
        const viewport = { width: Math.floor(1366 * 100 / scale), height: Math.floor(768 * 100 / scale) };
        await page.setViewportSize(viewport);
        for (const name of Object.keys(primary)) await scenario(theme + ' / ' + scale + '% effective viewport / ' + name, async () => {
          await navigate(name);
          if (name === 'settings') await page.locator('[data-settings-tab="connections"]').click();
          check(await page.locator('.main-nav [data-page="' + name + '"]').getAttribute('aria-current') === 'page', 'Selected navigation is announced.');
          check((await page.locator('#page-title').innerText()).trim().length > 0, 'The workspace has a readable heading.');
          for (const selector of primary[name]) await reachable(selector);
          if (name === 'today') {
            check(await page.locator('#daily-received-count').isVisible() && await page.locator('#report-total').isVisible(), 'Daily receipt and preserved-PDF totals remain visible at every effective scale.');
            const art = await page.locator('#scanner-cards svg.scanner-illustration').evaluateAll(nodes => nodes.map(svg => { const box = svg.getBBox(); return box.width > 40 && box.height > 30; }));
            check(art.length === initial.scanners.length && art.every(Boolean), 'Every scanner card renders its bundled CT illustration without remote images.');
          }
          const width = await page.evaluate(() => ({ content: document.documentElement.scrollWidth, viewport: document.documentElement.clientWidth }));
          check(width.content <= width.viewport + 2, 'The document has no horizontal page overflow.');
          observations.push({ theme, effectiveScalePercent: scale, page: name, viewport, horizontalOverflow: width.content - width.viewport });
          if (scale === 100) { await page.evaluate(() => scrollTo(0, 0)); await page.screenshot({ path: path.join(output, name + '-' + theme + '.png'), fullPage: true }); }
          if (scale === 200 && ['review', 'monthly', 'settings'].includes(name)) await page.screenshot({ path: path.join(output, name + '-' + theme + '-200.png'), fullPage: true });
        });
      }
    }

    await scenario('Keyboard navigation, Settings semantics and stable editable fields', async () => {
      await page.setViewportSize({ width: 1366, height: 768 });
      await navigate('settings');
      const tabs = page.locator('#settings-navigation [role="tab"]');
      check(await page.locator('#settings-navigation').getAttribute('role') === 'tablist' && await tabs.count() === 5, 'Settings exposes five named tabs.');
      for (const name of ['connections', 'archive', 'reading', 'support', 'updates']) {
        const tab = page.locator('[data-settings-tab="' + name + '"]');
        await tab.click();
        check(await tab.getAttribute('aria-selected') === 'true', 'The active Settings tab is announced.');
        check(await page.locator('#settings-panel-' + name).isVisible(), 'Its associated Settings panel is visible.');
      }
      const firstTab = page.locator('[data-settings-tab="connections"]');
      await firstTab.focus(); await firstTab.press('ArrowRight');
      check(await page.locator('[data-settings-tab="archive"]').getAttribute('aria-selected') === 'true' && await page.locator('[data-settings-tab="archive"]').evaluate(element => element === document.activeElement), 'Arrow keys select and focus the next Settings tab.');
      await page.keyboard.press('Home');
      check(await firstTab.getAttribute('aria-selected') === 'true', 'Home returns to the first Settings tab.');
      const input = page.locator('#connection-username');
      await input.fill('Synthetic input');
      await delay(2500); // Observe more than one normal jobs poll while the field has focus.
      await page.keyboard.type(' still editable');
      check(await input.inputValue() === 'Synthetic input still editable', 'Ordinary polling preserves focus and the unsaved typed value.');
      await input.press('Tab');
      check(await page.locator('#connection-password').evaluate(control => control === document.activeElement), 'Keyboard Tab reaches the password field.');
      check(await page.locator('#connection-password').getAttribute('type') === 'password', 'Password input remains concealed.');
      await page.locator('[data-settings-tab="reading"]').click();
      await page.locator('#display-density').selectOption('compact');
      check(await page.locator('html').getAttribute('data-density') === 'compact', 'Compact density is applied.');
      await page.locator('#display-density').selectOption('comfortable');
      check(await page.locator('html').getAttribute('data-density') === 'comfortable', 'Comfortable density can be restored.');
    });

    await scenario('Review retains one decision scope and keyboard access to PDF evidence', async () => {
      await navigate('review');
      check(await page.locator('#review-current-actions').isVisible(), 'A current PDF uses the single decision controls.');
      check(await page.locator('#approve-button:visible,#disapprove-button:visible,#approve-selected-button:visible,#disapprove-selected-button:visible').count() === 2, 'Only one filing action pair is visible.');
      const checkbox = page.locator('.review-row-checkbox').first();
      await checkbox.check();
      check(await page.locator('#review-selection-tools').isVisible() && !await page.locator('#review-current-actions').isVisible(), 'Selecting a report changes the single visible scope to the batch.');
      check(await page.locator('#approve-button:visible,#disapprove-button:visible,#approve-selected-button:visible,#disapprove-selected-button:visible').count() === 2, 'The selected scope still exposes exactly one action pair.');
      await page.locator('#review-clear-selection').click();
      await page.locator('#review-evidence-toggle').click();
      check(await page.locator('#review-evidence-toggle').getAttribute('aria-expanded') === 'true', 'Optional report details are expanded explicitly.');
      await page.locator('#review-evidence-toggle').click();
      check(!await page.locator('#review-evidence-drawer').isVisible(), 'Optional report details close without changing the PDF.');
      const scroller = page.locator('#pdf-image-scroller');
      check(await scroller.getAttribute('tabindex') === '0' && await scroller.getAttribute('role') === 'region', 'Continuous PDF pages have a keyboard-focusable named region.');
      if (await scroller.isVisible()) { await scroller.focus(); check(await scroller.evaluate(element => element === document.activeElement), 'The continuous PDF region accepts keyboard focus.'); }
    });

    await scenario('Offline assets and original source bytes stay intact', async () => {
      check(errors.length === 0, 'No browser JavaScript error occurred: ' + errors.join('; '));
      check(external.length === 0, 'The interface requested no external asset or endpoint.');
      for (const source of baseline.Sources) check(hash(fs.readFileSync(source.Path)) === source.Hash, 'An original synthetic scanner PDF remains unchanged.');
    });
  } catch (error) {
    results.push({ name: 'Test infrastructure', result: 'FAIL', details: clean(error.stack) });
    console.error(clean(error.message));
  } finally {
    if (browser) await browser.close();
    if (ready) try { await api('/api/actions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"Shutdown"}' }); } catch {}
    if (host) { await until(() => host.exitCode !== null || host.signalCode !== null, 'Host shutdown timed out.', 15000).catch(() => host.kill()); }
    const testedFiles = Object.fromEntries(['App/Web/app.js', 'App/Web/app.css', 'App/Web/index.html', 'App/Web/trends.js', 'App/WebService.psm1', 'App/Archive.psm1', 'App/WebWorker.ps1'].map(relative => [relative, hash(fs.readFileSync(path.join(root, relative)))]));
    const summary = { startedAtUtc, platform: process.platform, testedFiles, hostSha256: args.host && fs.existsSync(args.host) ? hash(fs.readFileSync(args.host)) : null, syntheticOnly: true, actualBrowser: true, actualHost: true, browserChannel: args['browser-channel'] || 'chromium', nativeWindowsDpiActuallyRun: false, tests: results.length, assertions, failed: results.filter(row => row.result === 'FAIL').length, javascriptErrors: errors, externalAssetRequests: external.length, observations, results, scope: 'Actual offline host, PowerShell adapter and generated PDFs. CSS viewports model the effective space of a 1366x768 display at 100/125/150/200%; this is not native Windows display-DPI, screen-reader or hospital workstation validation. Tests assert reachability, semantics, input focus, decision scope, local assets and unchanged scanner-source bytes.' };
    fs.writeFileSync(path.join(output, 'accessibility-summary.json'), JSON.stringify(summary, null, 2) + '\n');
    console.log('Result: ' + (summary.tests - summary.failed) + '/' + summary.tests + ' scenarios; ' + assertions + ' assertions.');
    if (summary.failed) process.exitCode = 1;
  }
})();
