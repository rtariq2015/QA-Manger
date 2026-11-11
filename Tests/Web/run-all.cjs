/* Development orchestration only; no Node or Playwright is required by the shipped program. */
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const key = process.argv[i].replace(/^--/, '');
  if (key === 'windows' || key === 'keep-fixture') args[key] = true;
  else args[key] = process.argv[++i];
}
const product = path.resolve(__dirname, '../..');
const isWindows = process.platform === 'win32';
const output = path.resolve(args.output || args['output-dir'] || path.join(product, 'artifacts/web'));
const fixture = args.root || path.join(os.tmpdir(), 'CTQA-Web-E2E-' + Date.now() + '-' + process.pid);
const powershell = args.powershell || process.env.CTQA_TEST_POWERSHELL || (isWindows ? path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe') : '/tmp/ctqa-pwsh');
const host = args.host || (isWindows ? path.join(product, 'App/Host/CTQa.Host.exe') : '/tmp/ctqa-host-build/CTQa.Host.dll');
const dotnet = args.dotnet || (!isWindows ? '/tmp/ctqa-dotnet/dotnet' : null);
fs.mkdirSync(output, { recursive: true });
const fixtureResult = spawnSync(powershell, ['-NoProfile', '-File', path.join(__dirname, 'New-WebFixture.ps1'), '-FixtureRoot', fixture, '-ProductRoot', product], { cwd: product, encoding: 'utf8', windowsHide: true, timeout: 180000 });
process.stdout.write(fixtureResult.stdout || '');
if (fixtureResult.status !== 0) {
  process.stderr.write(fixtureResult.stderr || 'Synthetic fixture creation failed.\n');
  process.exit(fixtureResult.status || 1);
}
const testArgs = [path.join(__dirname, 'run-e2e.cjs'), '--root', fixture, '--host', host, '--powershell', powershell, '--output-dir', output];
if (dotnet) testArgs.push('--dotnet', dotnet);
if (args.chromium) testArgs.push('--chromium', args.chromium);
else if (isWindows) testArgs.push('--browser-channel', 'msedge');
if (args.python) testArgs.push('--python', args.python);
const result = spawnSync(process.execPath, testArgs, { cwd: product, stdio: 'inherit', windowsHide: true, timeout: 900000 });
if (result.error) process.stderr.write(result.error.message + '\n');
let finalStatus = result.status || (result.error ? 1 : 0);
const largeFixture = fixture + '-large';
const largeOutput = path.join(output, 'large');
const contentFixture = fixture + '-content';
const contentOutput = path.join(output, 'content');
const pythonFixture = fixture + '-python';
const pythonOutput = path.join(output, 'python');
if (finalStatus === 0) {
  fs.mkdirSync(largeOutput, { recursive: true });
  const createLarge = spawnSync(powershell, ['-NoProfile', '-File', path.join(__dirname, 'New-LargeWebFixture.ps1'), '-FixtureRoot', largeFixture, '-ProductRoot', product], { cwd: product, encoding: 'utf8', windowsHide: true, timeout: 300000 });
  process.stdout.write(createLarge.stdout || '');
  if (createLarge.status !== 0) { process.stderr.write(createLarge.stderr || 'Large synthetic fixture creation failed.\n'); finalStatus = createLarge.status || 1; }
  if (finalStatus === 0) {
    const integration = spawnSync(powershell, ['-NoProfile', '-File', path.join(__dirname, 'Run-LargeWebTests.ps1'), '-FixtureRoot', largeFixture, '-OutputPath', path.join(largeOutput, 'library-summary.json')], { cwd: product, stdio: 'inherit', windowsHide: true, timeout: 900000 });
    finalStatus = integration.status || (integration.error ? 1 : 0);
  }
  if (finalStatus === 0) {
    const largeArgs = [path.join(__dirname, 'run-large-e2e.cjs'), '--root', largeFixture, '--host', host, '--powershell', powershell, '--output-dir', largeOutput];
    if (dotnet) largeArgs.push('--dotnet', dotnet);
    if (args.chromium) largeArgs.push('--chromium', args.chromium); else if (isWindows) largeArgs.push('--browser-channel', 'msedge');
    const integration = spawnSync(process.execPath, largeArgs, { cwd: product, stdio: 'inherit', windowsHide: true, timeout: 900000 });
    finalStatus = integration.status || (integration.error ? 1 : 0);
  }
}
if (finalStatus === 0) {
  fs.mkdirSync(contentOutput, { recursive: true });
  const createContent = spawnSync(powershell, ['-NoProfile', '-File', path.join(__dirname, 'New-ContentFixture.ps1'), '-FixtureRoot', contentFixture, '-ProductRoot', product], { cwd: product, encoding: 'utf8', windowsHide: true, timeout: 300000 });
  process.stdout.write(createContent.stdout || '');
  if (createContent.status !== 0) { process.stderr.write(createContent.stderr || 'Synthetic content fixture creation failed.\n'); finalStatus = createContent.status || 1; }
  if (finalStatus === 0) {
    const contentArgs = [path.join(__dirname, 'run-content-e2e.cjs'), '--root', contentFixture, '--host', host, '--powershell', powershell, '--output-dir', contentOutput];
    if (dotnet) contentArgs.push('--dotnet', dotnet);
    if (args.chromium) contentArgs.push('--chromium', args.chromium); else if (isWindows) contentArgs.push('--browser-channel', 'msedge');
    if (args.python) contentArgs.push('--python', args.python);
    const integration = spawnSync(process.execPath, contentArgs, { cwd: product, stdio: 'inherit', windowsHide: true, timeout: 900000 });
    finalStatus = integration.status || (integration.error ? 1 : 0);
  }
}
if (finalStatus === 0 && isWindows) {
  fs.mkdirSync(pythonOutput, { recursive: true });
  const createPython = spawnSync(powershell, ['-NoProfile', '-File', path.join(__dirname, 'New-PythonWebFixture.ps1'), '-FixtureRoot', pythonFixture, '-ProductRoot', product], { cwd: product, encoding: 'utf8', windowsHide: true, timeout: 300000 });
  process.stdout.write(createPython.stdout || '');
  if (createPython.status !== 0) { process.stderr.write(createPython.stderr || 'Synthetic Python fixture creation failed.\n'); finalStatus = createPython.status || 1; }
  if (finalStatus === 0) {
    const pythonArgs = [path.join(__dirname, 'run-python-e2e.cjs'), '--root', pythonFixture, '--host', host, '--powershell', powershell, '--browser-channel', 'msedge', '--output-dir', pythonOutput];
    const integration = spawnSync(process.execPath, pythonArgs, { cwd: product, stdio: 'inherit', windowsHide: true, timeout: 900000 });
    finalStatus = integration.status || (integration.error ? 1 : 0);
  }
}
if (finalStatus === 0 && !args['keep-fixture']) {
  fs.rmSync(fixture, { recursive: true, force: true });
  fs.rmSync(largeFixture, { recursive: true, force: true });
  fs.rmSync(contentFixture, { recursive: true, force: true });
  if (isWindows) fs.rmSync(pythonFixture, { recursive: true, force: true });
} else fs.writeFileSync(path.join(output, 'synthetic-fixture-location.txt'), fixture + '\n' + largeFixture + '\n' + contentFixture + '\n');
process.exit(finalStatus);
