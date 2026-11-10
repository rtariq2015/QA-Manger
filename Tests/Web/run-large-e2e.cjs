/* Real host/browser workload and cooperative cancellation; synthetic PDFs only. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');
const args = {};
for (let i=2;i<process.argv.length;i+=2) args[process.argv[i].replace(/^--/,'')]=process.argv[i+1];
const root=path.resolve(args.root), output=path.resolve(args['output-dir']||path.join(root,'large-browser-results'));
const baseline=readJSON(path.join(root,'large-fixture-baseline.json'));
if(!baseline.Synthetic)throw Error('Only explicitly synthetic fixtures may be tested.');
fs.mkdirSync(output,{recursive:true});
const hold=path.join(root,'test-refresh-hold'), reached=path.join(root,'test-refresh-reached');
const archiveFile=path.join(root,'App/Archive.psm1'), originalArchive=fs.readFileSync(archiveFile);
let host,browser,page,ready,supportDownloadUrl,assertions=0;
const results=[],errors=[],external=[];
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase();
function readJSON(file){return JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));}
const clean=value=>String(value||'').replaceAll(ready?.token||'\u0000','[redacted session]');
function check(value,message){assertions++;if(!value)throw Error(message);}
async function until(fn,message,timeout=120000){const start=Date.now();let last;while(Date.now()-start<timeout){try{const value=await fn();if(value)return value;}catch(error){last=error;}await delay(100);}throw Error(message+(last?': '+clean(last.message):''));}
async function scenario(name,fn){try{await fn();results.push({name,result:'PASS'});console.log('PASS '+name);}catch(error){results.push({name,result:'FAIL',details:clean(error.stack)});console.log('FAIL '+name+': '+clean(error.message));throw error;}}
async function api(route,options={}){return fetch(new URL(route,ready.url),{...options,headers:{'X-Qa-Session':ready.token,...options.headers}});}
async function snapshot(){const response=await api('/api/snapshot');const value=await response.json();if(!response.ok)throw Error('Snapshot '+response.status+': '+clean(value.error));return value;}
async function jobs(){return (await(await api('/api/jobs')).json()).jobs;}
async function refresh(){const response=await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"action":"Refresh"}'});check(response.status===202,'Refresh is accepted');return (await response.json()).id;}
async function jobWith(id,predicate){return until(async()=>{const job=(await jobs()).find(j=>j.id===id);return job&&predicate(job)&&job;},'Expected Refresh job state was not reached.');}
async function navigate(name){await page.locator('.main-nav button[data-page="'+name+'"]').click();}
async function reload(){await page.goto(ready.url+'#session='+encodeURIComponent(ready.token),{waitUntil:'domcontentloaded'});await page.locator('#refresh-button').waitFor({state:'visible'});}
function setBarrier(){fs.rmSync(reached,{force:true});fs.writeFileSync(hold,'synthetic test barrier');}
function releaseBarrier(){fs.rmSync(hold,{force:true});}
function canonical(value){if(Array.isArray(value))return value.map(canonical);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])]));if(typeof value==='string'&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(value))return new Date(value).toISOString();return value;}
function preserveRecords(){
 const state=readJSON(path.join(root,'Data/.ctqa/state.json')), records=new Map(state.Records.map(r=>[r.Id,r]));
 check(state.Records.length===1367,'Refresh retains every original report identity');
 for(const original of baseline.CoreRecords){const record=records.get(original.Id);for(const field of ['Category','ClassificationBasis','ConfirmedBy','ReviewDecision','LastReviewId'])check(String(record[field]||'')===String(original[field]||''),'Refresh preserves authoritative '+field);check((Date.parse(record.ConfirmedAt)||0)===(Date.parse(original.ConfirmedAt)||0),'Refresh preserves the exact clinical review time');}
 check(JSON.stringify(canonical(state.Reviews))===JSON.stringify(canonical(baseline.CoreReviews)),'Refresh preserves the complete existing clinical review history');
 for(const original of baseline.Expected){const record=records.get(original.Id);check(!!record&&record.Hash===original.Hash,'Refresh retains the indexed report hash');check(record.ConfirmedBy===original.ConfirmedBy&&JSON.stringify(record.ConfirmedComponents||[])===JSON.stringify(original.ConfirmedComponents),'Refresh preserves actual clinical reviewer and checklist fields');check(hash(fs.readFileSync(original.SourcePath))===original.Hash,'Refresh never modifies the scanner-source PDF');check(hash(fs.readFileSync(record.DestinationPath))===original.Hash,'Refresh preserves the archived PDF bytes');}
 check(hash(fs.readFileSync(path.join(root,'Data/.ctqa/organization.json')))===baseline.OrganizationSHA256,'Refresh retains existing Approve/Disapprove decisions and history byte-for-byte');
}
function injectBarrier(){
 const source=originalArchive.toString('utf8'), start=source.indexOf('function Set-QaProgress '), next=source.indexOf('function Test-QaCancel',start), end=source.lastIndexOf('}',next);
 if(start<0||next<0||end<start)throw Error('The fixture progress checkpoint could not be located.');
 // This barrier is added only to a disposable copied fixture, never production.
 const code=`\n    if($null -ne $Progress -and $Message -like 'Organizing *') {\n        $fixtureHold=Join-Path $PSScriptRoot '../test-refresh-hold';$fixtureReached=Join-Path $PSScriptRoot '../test-refresh-reached'\n        if([IO.File]::Exists($fixtureHold) -and -not [IO.File]::Exists($fixtureReached)) {\n            [IO.File]::WriteAllText($fixtureReached,'synthetic checkpoint')\n            while([IO.File]::Exists($fixtureHold) -and -not [bool]$Progress.Cancel){Start-Sleep -Milliseconds 50}\n        }\n    }\n`;
 fs.writeFileSync(archiveFile,source.slice(0,end)+code+source.slice(end));
}
(async()=>{
 try{
  injectBarrier();
  const parameters=['--root',root,'--powershell',args.powershell||'/tmp/ctqa-pwsh','--no-browser'];
  host=spawn(args.dotnet||args.host,args.dotnet?[args.host,...parameters]:parameters,{cwd:root,stdio:['ignore','ignore','pipe'],windowsHide:true});
  let startupError='';host.stderr.on('data',bytes=>{startupError=(startupError+bytes.toString()).slice(-2000);});
  await until(()=>{if(host.exitCode!==null)throw Error('Host exited '+host.exitCode+': '+clean(startupError));const file=path.join(root,'Data/web-ready.json');if(!fs.existsSync(file))return false;const value=readJSON(file);return value.pid===host.pid&&(ready=value);},'Local host did not become ready.');
  await until(async()=>{const value=await snapshot();return value.records?.length===1367;},'The real adapter did not load all synthetic records.');
  const launch={headless:true,args:['--no-sandbox','--disable-dev-shm-usage']};if(args['browser-channel'])launch.channel=args['browser-channel'];else launch.executablePath=args.chromium||'/usr/bin/chromium';
  browser=await chromium.launch(launch);const context=await browser.newContext({viewport:{width:1440,height:1000}});
  await context.route('**/*',route=>{const url=new URL(route.request().url());if(['http:','https:'].includes(url.protocol)&&!['127.0.0.1','localhost','[::1]'].includes(url.hostname)){external.push(url.hostname);route.abort();}else route.continue();});
  page=await context.newPage();page.on('pageerror',error=>errors.push(clean(error.message)));await reload();
  await scenario('The full library shows known reports as automatic and reserves review for 217 uncertain PDFs',async()=>{
   const value=await snapshot();check(value.pendingSummary.automatic===1050&&value.pendingSummary.pending===217,'The real API exposes exact automatic and pending counts');
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#status-filter').selectOption('automatic');
   await until(async()=>await page.locator('.report-item').count()===1050,'The Automatic filter did not include every confidently organized report.');check(true,'The Automatic filter contains 1,050 known documents');
   await page.locator('#status-filter').selectOption('pending');await until(async()=>await page.locator('.report-item').count()===217,'The Pending filter did not match actual uncertain reports.');check(true,'The Pending filter contains 217 genuinely uncertain documents');
   check(!/1033/.test(await page.locator('#list-pending-summary').innerText()),'The review count is not inflated by generic Daily reports');
   await page.screenshot({path:path.join(output,'large-library-pending.png'),fullPage:true});
  });
  await scenario('An active Refresh reports real progress, merges duplicate requests and permits offline browsing after reload',async()=>{
   setBarrier();await navigate('today');await page.locator('#refresh-button').click();
   await until(()=>fs.existsSync(reached),'The actual archive loop did not reach its synthetic organizing checkpoint.');
   const active=(await jobs()).find(j=>j.action==='Refresh'&&j.status==='running');check(!!active,'Refresh runs as an actual background worker');
   const duplicate=await refresh();check(duplicate===active.id,'A duplicate Refresh returns the same active job instead of adding an import');
   const observed=await jobWith(active.id,j=>j.stage==='Copying'&&j.total===1367);check(observed.completed>=0&&observed.elapsedSeconds>=0&&observed.cancellable,'The API supplies factual counts, elapsed time and cooperative cancellation');
   await reload();await page.locator('#job-progress').waitFor({state:'visible'});await until(async()=>/Copying/.test(await page.locator('#job-stage').innerText()),'A reloaded browser did not rediscover the running job.');
   check((await page.locator('#job-count').innerText()).includes('1,367'),'The UI shows the actual report total');
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#report-search').click();await page.keyboard.type('Unlabelled');
   await until(async()=>await page.locator('.report-item').count()===100,'Saved report search was blocked by the active update.');check(true,'The saved library remains searchable while Refresh is running');
   const selected=page.locator('.report-item').first(),recordId=await selected.getAttribute('data-record-id');await selected.click();await until(async()=>await page.locator('#pdf-frame').isVisible()||await page.locator('#pdf-image').isVisible(),'A saved PDF could not be viewed while scanning.');
   if(await page.locator('#pdf-image').isVisible())await until(()=>page.locator('#pdf-image').evaluate(image=>image.complete&&image.naturalWidth>0),'The native PDF page did not finish rendering during Refresh.');
   const pdf=await api('/api/pdf/'+recordId);check(pdf.ok&&Buffer.from(await pdf.arrayBuffer()).subarray(0,5).toString()==='%PDF-','A real saved PDF remains available through the authenticated route during Refresh');
   await page.screenshot({path:path.join(output,'large-refresh-progress.png'),fullPage:true});
   await navigate('settings');check(await page.locator('#diagnostics-button').isEnabled(),'Support logs can be requested while Refresh is still running');
   const beforeDiagnostics=new Set((await jobs()).map(job=>job.id));await page.locator('#diagnostics-button').click();
   const diagnostics=await until(async()=>(await jobs()).find(job=>!beforeDiagnostics.has(job.id)&&job.action==='Diagnostics'&&['completed','failed'].includes(job.status)),'Support logs did not complete while Refresh was held.');
   check(diagnostics.status==='completed','Diagnostics completes independently of the held archive update');
   check((await jobs()).find(job=>job.id===active.id)?.status==='running'&&fs.existsSync(hold),'Collecting support logs neither waits for nor interrupts the active Refresh');
   supportDownloadUrl=diagnostics.result?.downloadUrl;check(!!supportDownloadUrl,'Completed Diagnostics exposes its authenticated ZIP download');
   await page.locator('#support-download-link').waitFor({state:'visible'});check((await page.locator('#support-download-link').getAttribute('href')).endsWith(supportDownloadUrl),'Backup & support keeps a dedicated download link while progress continues');
   const logs=await api(supportDownloadUrl);check(logs.ok&&Buffer.from(await logs.arrayBuffer()).subarray(0,2).toString()==='PK','The support download returns a real ZIP while Refresh remains active');
  });
  await scenario('Cancel stops the real import cooperatively without continuing into library generation or losing evidence',async()=>{
   const active=(await jobs()).find(j=>j.action==='Refresh'&&j.status==='running');const manifest=path.join(root,'Data/.ctqa/web-library.json');const before=hash(fs.readFileSync(manifest));
   await page.locator('#job-cancel').click();const done=await jobWith(active.id,j=>['completed','failed','cancelled'].includes(j.status));
   check(done.status==='cancelled','A user cancellation is a cancelled job, rather than failure or false success');check(done.cancelRequested,'The terminal job retains the cancellation request');
   await until(async()=>!(await page.locator('#job-spinner').isVisible())&&!(await page.locator('#job-progress').isVisible()),'The reloaded page left its spinner running after cancellation.');check(true,'Progress and spinner stop after the observed job is cancelled');
   check(hash(fs.readFileSync(manifest))===before,'Cancelling before library work leaves the existing readable-library ledger unchanged');preserveRecords();
   check(await page.locator('#support-download-link').isVisible()&&(await page.locator('#support-download-link').getAttribute('href')).endsWith(supportDownloadUrl),'The support download remains available after a later Refresh result replaces the job toast');
   releaseBarrier();
  });
  await scenario('A subsequent unchanged Refresh finishes after reload and reuses cached readable PDFs',async()=>{
   setBarrier();const id=await refresh();await until(()=>fs.existsSync(reached),'The resumed actual update did not reach its checkpoint.');await reload();await page.locator('#job-progress').waitFor({state:'visible'});releaseBarrier();
   const done=await jobWith(id,j=>['completed','failed','cancelled'].includes(j.status));check(done.status==='completed','The next Refresh completes normally after cooperative cancellation');
   const result=done.result?.result||done.result;const library=result?.library;check(!!library,'Refresh returns factual readable-library metrics');check(library.hashedFiles===0&&library.manifestWrites===0&&library.copied===0&&library.unchanged===1367,'The real worker reuses all 1,367 warm copies without full hash rereads or ledger writes');
   await until(async()=>!(await page.locator('#job-spinner').isVisible())&&!(await page.locator('#job-progress').isVisible()),'The reloaded browser left the completed update spinning.');check(true,'A completed job ends progress even when submitted by the previous browser document');
   const after=await snapshot();check(after.pendingSummary.pending===217&&after.pendingSummary.automatic===1050,'Unchanged scanning preserves correct automatic and pending classifications');preserveRecords();
   check(errors.length===0,'No JavaScript errors occurred');check(external.length===0,'No external asset request was attempted');
  });
 }catch(error){process.exitCode=1;if(!results.some(r=>r.result==='FAIL'))results.push({name:'Setup or completion',result:'FAIL',details:clean(error.stack)});if(page)try{await page.screenshot({path:path.join(output,'large-failure.png'),fullPage:true});}catch{}}
 finally{
  releaseBarrier();if(browser)await browser.close();if(ready)try{await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"action":"Shutdown"}'});}catch{}
  if(host){await until(()=>host.exitCode!==null,'Host shutdown timed out.',15000).catch(()=>host.kill());}
  fs.writeFileSync(archiveFile,originalArchive);
  const summary={version:'5.1.0',syntheticOnly:true,records:1367,tests:results.length,assertions,failed:results.filter(r=>r.result==='FAIL').length,externalAssetRequests:external.length,javascriptErrors:errors,results,scope:'Real local host, worker, archive loop and browser. A disposable copied Set-QaProgress checkpoint supplies a deterministic barrier; the real cooperative cancellation and production persistence run unchanged.'};
  fs.writeFileSync(path.join(output,'large-browser-summary.json'),JSON.stringify(summary,null,2)+'\n');console.log('Result: '+(summary.tests-summary.failed)+'/'+summary.tests+' scenarios; '+assertions+' assertions.');
 }
})();
