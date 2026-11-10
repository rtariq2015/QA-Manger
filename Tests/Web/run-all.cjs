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
if (result.status === 0 && !args['keep-fixture']) fs.rmSync(fixture, { recursive: true, force: true });
else fs.writeFileSync(path.join(output, 'synthetic-fixture-location.txt'), fixture + '\n');
process.exit(result.status || (result.error ? 1 : 0));
