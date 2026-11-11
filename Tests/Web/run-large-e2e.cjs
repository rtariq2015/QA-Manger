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
let host,browser,page,ready,supportDownloadUrl,initialFiling,assertions=0;
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
async function startTestHost(){
 const parameters=['--root',root,'--powershell',args.powershell||'/tmp/ctqa-pwsh','--no-browser'];host=spawn(args.dotnet||args.host,args.dotnet?[args.host,...parameters]:parameters,{cwd:root,stdio:['ignore','ignore','pipe'],windowsHide:true});let startupError='';host.stderr.on('data',bytes=>startupError=(startupError+bytes.toString()).slice(-2000));
 await until(()=>{if(host.exitCode!==null)throw Error('Host exited '+host.exitCode+': '+clean(startupError));const file=path.join(root,'Data/web-ready.json');if(!fs.existsSync(file))return false;const value=readJSON(file);return value.pid===host.pid&&(ready=value);},'Local host did not become ready.');await until(async()=>(await snapshot()).records?.length===1367,'The real adapter did not load all synthetic records.');
}
async function stopTestHost(){if(!host)return;const running=host;await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"action":"Shutdown"}'});await until(()=>running.exitCode!==null,'Host shutdown timed out.',15000);host=null;}
async function completedAction(request,expected='completed'){const response=await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(request)});check(response.status===202,'The '+request.action+' request is accepted');const accepted=await response.json(),job=await until(async()=>(await jobs()).find(row=>row.id===accepted.id&&['completed','failed','cancelled'].includes(row.status)),request.action+' did not finish.');check(job.status===expected,request.action+' finished with its expected '+expected+' status');return job;}
function decisionOf(job){const value=job.result?.result||job.result||{};return value.decision||value;}
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
  await startTestHost();
  const launch={headless:true,args:['--no-sandbox','--disable-dev-shm-usage']};if(args['browser-channel'])launch.channel=args['browser-channel'];else launch.executablePath=args.chromium||'/usr/bin/chromium';
  browser=await chromium.launch(launch);const context=await browser.newContext({viewport:{width:1440,height:1000}});
  await context.route('**/*',route=>{const url=new URL(route.request().url());if(['http:','https:'].includes(url.protocol)&&!['127.0.0.1','localhost','[::1]'].includes(url.hostname)){external.push(url.hostname);route.abort();}else route.continue();});
  page=await context.newPage();page.on('pageerror',error=>errors.push(clean(error.message)));await reload();
  await scenario('The full library separates unread filing work from actual review exceptions',async()=>{
   const value=await snapshot();check(value.pendingSummary.automatic===1050&&value.pendingSummary.pending===217,'The real API retains exact legacy automatic and unresolved totals');
   const waiting=value.records.filter(record=>record.filingState==='WaitingRead').length,exceptions=value.records.filter(record=>record.filingState==='NeedsReview').length;
   initialFiling={waiting,exceptions};check(waiting===217&&exceptions===0,'The unread synthetic workload begins with 217 awaiting-reading reports and no completed-read exception');
   check(value.filingSummary.waitingRead===waiting&&value.filingSummary.needsReview===exceptions,'The aggregate filing counts match actual per-record states');
   await navigate('today');await until(async()=>Number((await page.locator('#report-total').innerText()).replaceAll(',',''))===1367,'The Today workspace did not load its saved library.');
   check(await page.locator('#nav-pending').isHidden(),'The Review badge does not turn unread PDFs into urgent manual decisions');
   check((await page.locator('#review-callout').getAttribute('class')).split(/\s+/).includes('waiting'),'Today uses the neutral reading-queue callout for unread PDFs');
   check((await page.locator('#review-callout-title').innerText()).includes(waiting.toLocaleString()),'The neutral callout states the factual waiting count');
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#status-filter').selectOption('automatic');
   await until(async()=>await page.locator('.report-item').count()===1050,'The Automatic filter did not include every confidently organized report.');check(true,'The Automatic filter contains 1,050 known documents');
   await page.locator('#status-filter').selectOption('pending');await until(async()=>await page.locator('.report-item').count()===exceptions,'The exception filter did not match completed-read filing exceptions.');check(true,'The exception filter excludes all unread PDFs');
   await page.locator('#status-filter').selectOption('waiting');await until(async()=>await page.locator('.report-item').count()===waiting,'The awaiting-reading filter did not match the saved queue.');check(true,'All 217 unread PDFs remain accessible in the separate awaiting-reading filter');
   check((await page.locator('#list-pending-summary').innerText()).includes('0 file exceptions'),'The list summary distinguishes actual exceptions from awaiting reading');
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
   await navigate('settings');await page.locator('[data-settings-tab="support"]').click();check(await page.locator('#diagnostics-button').isEnabled(),'Support logs can be requested while Refresh is still running');
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
  await scenario('Reading one unsupported synthetic PDF creates one genuine review exception',async()=>{
   const before=await snapshot(),selected=before.records.find(record=>record.filingState==='WaitingRead'&&/Unlabelled/.test(record.filename));check(!!selected,'One existing unread synthetic layout is available for selected reading');
   const original=baseline.Expected.find(record=>record.Id===selected.id),statePath=path.join(root,'Data/.ctqa/state.json'),stateHash=hash(fs.readFileSync(statePath));
   const response=await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'Analyze',id:selected.id})});check(response.status===202,'Only the selected synthetic PDF is submitted for reading');
   const accepted=await response.json(),done=await until(async()=>(await jobs()).find(job=>job.id===accepted.id&&['completed','failed','cancelled'].includes(job.status)),'The selected synthetic PDF did not finish reading.');check(done.status==='completed','The selected read completes and records unsupported content honestly');
   const result=done.result?.result||done.result;check(result.Analyzed===1&&result.AnalyzedIds.length===1&&result.AnalyzedIds[0]===selected.id,'Exactly one report is parsed rather than the entire waiting queue');
   const after=await snapshot(),row=after.records.find(record=>record.id===selected.id);check(row.filingState==='NeedsReview'&&row.pending&&['Unsupported','ReadError'].includes(row.filingBasis),'The actually attempted unsupported report becomes a genuine review exception');
   check(after.filingSummary.needsReview===initialFiling.exceptions+1&&after.filingSummary.waitingRead===initialFiling.waiting-1,'One attempted read moves exactly one item from awaiting reading to review');
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#status-filter').selectOption('pending');
   await until(async()=>await page.locator('.report-item').count()===1,'The UI did not show the one newly created exception.');check((await page.locator('.report-item').getAttribute('data-record-id'))===selected.id,'The exception filter points to the actually read unsupported PDF');
   check((await page.locator('#nav-pending').innerText())==='1'&&await page.locator('#nav-pending').isVisible(),'The Review badge now exposes the factual single exception');
   await page.locator('#status-filter').selectOption('waiting');await until(async()=>await page.locator('.report-item').count()===after.filingSummary.waitingRead,'The remaining unread queue did not stay separate.');check(true,'The other unread PDFs remain in the neutral reading queue');
   check(hash(fs.readFileSync(statePath))===stateHash,'Selected reading leaves the complete clinical archive state unchanged');
   const archived=readJSON(statePath).Records.find(record=>record.Id===selected.id);check(original&&hash(fs.readFileSync(original.SourcePath))===original.Hash&&hash(fs.readFileSync(archived.DestinationPath))===original.Hash,'The selected source and archived PDF bytes remain unchanged');
   check(errors.length===0,'No JavaScript errors occurred after the exception transition');check(external.length===0,'The exception workflow makes no external asset request');
  });
  await scenario('Reason groups support atomic selected decisions, stale protection and durable batch Undo',async()=>{
   let before=await snapshot();const first=before.records.find(row=>row.filingState==='NeedsReview'&&/Unlabelled/.test(row.filename)),second=before.records.find(row=>row.filingState==='WaitingRead'&&row.scanner===first?.scanner&&/Unlabelled/.test(row.filename));check(!!first&&!!second,'Two existing synthetic unknown layouts share a scanner for grouped review');
   await completedAction({action:'Analyze',id:second.id});before=await snapshot();const pair=[first.id,second.id].map(id=>before.records.find(row=>row.id===id));
   check(pair.every(row=>row.filingState==='NeedsReview'&&row.approvalNeedsCategory)&&pair[0].groupingKey===pair[1].groupingKey,'The actual classifier groups matching exceptions and exposes their missing filing type');
   const clinicalHash=hash(fs.readFileSync(path.join(root,'Data/.ctqa/state.json'))),profiles=JSON.stringify(before.scanners.map(scanner=>scanner.contentProfiles));
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#status-filter').selectOption('pending');await until(async()=>await page.locator('.report-item').count()===2,'The second exception did not reach the browser');await page.locator('.report-item[data-record-id="'+first.id+'"]').click();
   check(await page.locator('#review-target-type').isVisible()&&await page.locator('#approve-button').isDisabled(),'An unsupported single report requires an explicit visible type choice');await page.locator('#review-target-type').selectOption('Monthly');check((await page.locator('#approve-button').innerText()).includes('Approve as Monthly'),'Choosing a type makes the single action explicit');
   if(await page.locator('#review-queue-toggle').getAttribute('aria-expanded')!=='true')await page.locator('#review-queue-toggle').click();
   let group=page.locator('.review-reason-group[data-group-key="'+pair[0].groupingKey+'"]');if(!(await group.evaluate(node=>node.open))){await group.locator('summary').focus();await group.locator('summary').press('Enter');}check(await group.locator('.review-row-checkbox').count()===2&&await group.evaluate(node=>node.open),'Keyboard activation opens a visible reason group containing both matching file exceptions');await group.locator('.review-select-group').focus();await group.locator('.review-select-group').press('Enter');check((await page.locator('#review-selection-count').innerText())==='2 selected','One group selection reports the exact selected count');check(await page.locator('#approve-selected-button').isDisabled(),'Unknown selected types are never approved ambiguously');await page.locator('#review-batch-category').selectOption('Monthly');
   const held=[];let releaseResponses;const responseGate=new Promise(resolve=>{releaseResponses=resolve;});const holdRoute=route=>{const pending=(async()=>{await responseGate;await route.continue();})();held.push(pending);return pending;};await page.route('**/api/jobs',holdRoute);await page.route('**/api/snapshot',holdRoute);
   const changed=await completedAction({action:'Disapprove',id:pair[1].id,stamp:pair[1].stamp}),changedDecision=decisionOf(changed),previous=new Set((await jobs()).map(job=>job.id));
   const submitted=page.waitForRequest(request=>{if(new URL(request.url()).pathname!=='/api/actions'||request.method()!=='POST')return false;try{return request.postDataJSON().action==='Approve'&&Array.isArray(request.postDataJSON().selections);}catch{return false;}});
   await page.locator('#approve-selected-button').click();const stalePayload=(await submitted).postDataJSON();check(stalePayload.selections.length===2&&stalePayload.selections.some(row=>row.id===pair[1].id&&row.stamp===pair[1].stamp),'The stale UI submits the captured displayed stamps rather than silently refreshing selection');
   const rejected=await until(async()=>(await jobs()).find(job=>!previous.has(job.id)&&job.action==='Approve'&&['completed','failed'].includes(job.status)),'The stale grouped decision did not finish');check(rejected.status==='failed','A changed member rejects the entire actual batch');
   let value=await snapshot();check(value.records.find(row=>row.id===pair[0].id).filingState==='NeedsReview'&&value.records.find(row=>row.id===pair[1].id).decision==='Disapproved','A stale batch neither changes its valid member nor overwrites the newer decision');
   releaseResponses();await Promise.all(held);await page.unroute('**/api/jobs',holdRoute);await page.unroute('**/api/snapshot',holdRoute);await until(async()=>(await page.locator('#review-selection-note').innerText()).includes('changed'),'The browser did not explain the stale selected member');check(await page.locator('#approve-selected-button').isDisabled(),'A changed selection stays blocked until the user clears it');await page.locator('#review-clear-selection').click();
   const current=value.records.find(row=>row.id===pair[1].id);await completedAction({action:'Undo',id:current.id,reviewId:changedDecision.reviewId,stamp:current.stamp});await until(async()=>(await snapshot()).records.find(row=>row.id===current.id).filingState==='NeedsReview','Undo did not restore the externally changed exception');
   await navigate('reports');await page.locator('#clear-filters').click();await page.locator('#status-filter').selectOption('pending');await until(async()=>await page.locator('.report-item').count()===2,'The restored exceptions did not reach the browser');await page.locator('.report-item[data-record-id="'+first.id+'"]').click();
   if(await page.locator('#review-queue-toggle').getAttribute('aria-expanded')!=='true')await page.locator('#review-queue-toggle').click();
   for(const id of [first.id,second.id]){const checkbox=page.locator('.review-row-checkbox[data-record-id="'+id+'"]');const details=checkbox.locator('xpath=ancestor::details');if(!(await details.evaluate(node=>node.open)))await details.locator('summary').click();await checkbox.check();}
   await page.locator('#review-batch-category').selectOption('Monthly');check((await page.locator('#approve-selected-button').innerText())==='Approve 2 as Monthly','The batch action visibly names its selected count and target');if(await page.locator('#job-dismiss').isVisible())await page.locator('#job-dismiss').click();await page.screenshot({path:path.join(output,'grouped-review-web-demo.png'),fullPage:true});
   const beforeApprove=new Set((await jobs()).map(job=>job.id));await page.locator('#approve-selected-button').click();const saved=await until(async()=>(await jobs()).find(job=>!beforeApprove.has(job.id)&&job.action==='Approve'&&['completed','failed'].includes(job.status)),'The selected approval did not finish');check(saved.status==='completed'&&decisionOf(saved).count===2,'The actual batch saves both file labels together');
   value=await snapshot();check([first.id,second.id].every(id=>value.records.some(row=>row.id===id&&row.category==='Monthly'&&row.decision==='Approved'&&!row.pending))&&value.undoBatch?.count===2,'Both explicit Monthly labels and durable batch Undo are exposed');
   await stopTestHost();await startTestHost();await reload();await until(async()=>!(await page.locator('#refresh-button').isDisabled()),'The restarted browser did not load its snapshot');await navigate('review');await page.locator('#undo-batch-button').waitFor({state:'visible'});check((await snapshot()).undoBatch?.count===2,'Grouped Undo survives an actual host restart');
   const beforeUndo=new Set((await jobs()).map(job=>job.id));await page.locator('#undo-batch-button').click();const restored=await until(async()=>(await jobs()).find(job=>!beforeUndo.has(job.id)&&job.action==='Undo'&&['completed','failed'].includes(job.status)),'The grouped Undo did not finish');check(restored.status==='completed','One action restores the complete actual batch');
   value=await snapshot();check([first.id,second.id].every(id=>value.records.some(row=>row.id===id&&row.filingState==='NeedsReview'&&row.category==='Other'))&&!value.undoBatch,'Batch Undo restores both original filing exceptions without leaving a partial undo');
   check(hash(fs.readFileSync(path.join(root,'Data/.ctqa/state.json')))===clinicalHash,'Grouped decisions preserve the complete clinical archive state byte-for-byte');check(JSON.stringify(value.scanners.map(scanner=>scanner.contentProfiles))===profiles,'Batch review does not teach or replace scanner filing rules');
   for(const id of [first.id,second.id]){const expected=baseline.Expected.find(row=>row.Id===id),record=readJSON(path.join(root,'Data/.ctqa/state.json')).Records.find(row=>row.Id===id);check(hash(fs.readFileSync(expected.SourcePath))===expected.Hash&&hash(fs.readFileSync(record.DestinationPath))===expected.Hash,'The grouped source and archived PDF bytes stay unchanged');}
   check(errors.length===0,'Grouped review produces no JavaScript errors');check(external.length===0,'Grouped review uses no external service or asset');
  });
 }catch(error){process.exitCode=1;if(!results.some(r=>r.result==='FAIL'))results.push({name:'Setup or completion',result:'FAIL',details:clean(error.stack)});if(page)try{await page.screenshot({path:path.join(output,'large-failure.png'),fullPage:true});}catch{}}
 finally{
  releaseBarrier();if(browser)await browser.close();if(ready)try{await api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"action":"Shutdown"}'});}catch{}
  if(host){await until(()=>host.exitCode!==null,'Host shutdown timed out.',15000).catch(()=>host.kill());}
  fs.writeFileSync(archiveFile,originalArchive);
  const summary={version:'5.5.0',syntheticOnly:true,browserChannel:args['browser-channel']||'chromium',records:1367,tests:results.length,assertions,failed:results.filter(r=>r.result==='FAIL').length,externalAssetRequests:external.length,javascriptErrors:errors,results,scope:'Real local host, worker, archive loop and browser. A disposable copied Set-QaProgress checkpoint supplies a deterministic barrier; the real cooperative cancellation and production persistence run unchanged.'};
  fs.writeFileSync(path.join(output,'large-browser-summary.json'),JSON.stringify(summary,null,2)+'\n');console.log('Result: '+(summary.tests-summary.failed)+'/'+summary.tests+' scenarios; '+assertions+' assertions.');
 }
})();
