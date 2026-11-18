/* One focused synthetic production-web startup recovery check.
 * The virtual clock/interval scheduler and controller seam exist only in this
 * test server's response. No scanner, PDF reader or Windows host is invoked. */
'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../..'),web=path.join(root,'App/Web');
const output=path.resolve(process.argv[2]||path.join(root,'Tests/Startup-Recovery/Browser.json'));
const checks=[],requests=[],errors=[],external=[],mutations=[],cases=new Map();
const result={syntheticOnly:true,scope:'One focused production-web Chromium startup/recovery flow with a virtual Date.now and test-only interval scheduler. Synthetic 503/401 responses and saved-record metadata only; no actual PowerShell host startup, Windows browser, hospital workstation, scanner/SMB, credentials, PDF reader or real startup throughput validation.',checks,requests,errors,externalRequests:external,mutations};
let browser,server;
const sourceHashes=()=>Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(name=>[name,crypto.createHash('sha256').update(fs.readFileSync(path.join(web,name))).digest('hex')]));
const id=label=>crypto.createHash('sha256').update('startup-recovery-synthetic:'+label).digest('hex');
function check(value,name){assert.ok(value,name);checks.push({name,result:'PASS'});}
function same(actual,expected,name){assert.deepEqual(actual,expected,name);checks.push({name,result:'PASS'});}
function json(response,value,status=200){response.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});response.end(JSON.stringify(value));}
function snapshot(){
 const scanners=[['CT_Edge','CT Edge'],['CT_Flash','CT Flash'],['MDP_Building','MDP Building']].map(([scanner,name])=>({id:scanner,name,path:'Synthetic scanner folder',username:'',drive:'',status:'Connected',message:'Synthetic last saved connection status',dailySchedule:'AllDays',activeFrom:'2026-01-01',expectedMonthly:false,monthlyDueDay:0,checklist:[],monthlyChecklistHistory:[],excludedDates:[]}));
 const records=scanners.map(scanner=>({id:id(scanner.id),stamp:id(scanner.id+':stamp'),scanner:scanner.id,scannerName:scanner.name,date:'2026-11-18',time:'07:00:00',title:'Synthetic saved Daily report',filename:'SYNTHETIC_'+scanner.id+'.pdf',category:'Daily',pending:false,decision:'Automatic',filingState:'Filed',filingBasis:'Filename',isReference:false,hasReferenceEvidence:false,approvalCategory:'Daily',approvalNeedsCategory:false,content:{},clinicalComponents:[]}));
 return {version:'5.7.18',previewMode:'browser',workspace:'Synthetic startup fixture',archiveRoot:'Synthetic archive',libraryRoot:'Synthetic archive/Report Library',setupComplete:true,records,scanners,today:{date:'2026-11-18',received:3,expected:3,headline:'All required Daily QA reports received'},months:[],analysis:{total:3,cached:0,pending:3,errors:0,backlogPending:3},trendsRevision:'a'.repeat(64),settings:{theme:'Light',monitorMinutes:0,autoAnalyze:false,autoUpdateOnOpen:false,pdfReaderMode:'Auto'},batchReviewLimit:50,lastDecision:null,undoBatch:null};
}
async function startServer(){
 server=http.createServer(async(request,response)=>{
  const url=new URL(request.url,'http://127.0.0.1'),pathname=url.pathname,name=request.headers['x-synthetic-case']||'slow',config=cases.get(name)||{mode:'ready'};
  requests.push({case:name,method:request.method,pathname});
  if(pathname==='/api/session')return json(response,{connected:true,version:'5.7.18'});
  if(pathname==='/api/heartbeat')return json(response,{alive:true});
  if(pathname==='/api/jobs')return json(response,{jobs:[]});
  if(pathname==='/api/snapshot'){
   config.active=(config.active||0)+1;config.maxActive=Math.max(config.maxActive||0,config.active);
   try{
    if(config.gate)await config.gate;
    if(config.mode==='loading')return json(response,{error:'The saved library is loading. Please wait a moment.'},503);
    if(config.mode==='permission')return json(response,{error:'Synthetic saved archive folder access was denied. Check folder permissions.'},503);
    if(config.mode==='expired')return json(response,{error:'The local session expired. Reopen CT QA Manager.'},401);
    return json(response,snapshot());
   }finally{config.active--;}
  }
  if(pathname==='/api/actions'){let body='';for await(const chunk of request)body+=chunk;mutations.push({case:name,body});return json(response,{error:'This read-only startup fixture forbids mutation actions.'},400);}
  if(pathname==='/favicon.ico'){response.writeHead(204);return response.end();}
  const file={'/':'index.html','/index.html':'index.html','/app.js':'app.js','/app.css':'app.css','/trends.js':'trends.js'}[pathname];
  if(!file)return json(response,{error:'Unexpected synthetic route: '+pathname},404);
  let content=fs.readFileSync(path.join(web,file));
  if(file==='app.js'){
   const marker='  boot().catch(';assert.ok(content.toString().includes(marker),'Expected existing boot seam.');
   content=content.toString().replace(marker,'  window.__qaStartup={state,refreshSnapshot,pollJobs,showError,hideError,retryLibrarySnapshot:typeof retryLibrarySnapshot==="undefined"?null:retryLibrarySnapshot,recoverLibraryIfDue:typeof recoverLibraryIfDue==="undefined"?null:recoverLibraryIfDue};\n'+marker);
  }
  response.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':'application/javascript'});response.end(content);
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return 'http://127.0.0.1:'+server.address().port;
}
const count=(name,pathname)=>requests.filter(row=>row.case===name&&row.pathname===pathname).length;
async function openCase(origin,name,mode){
 const config={mode};cases.set(name,config);
 const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'en-US',extraHTTPHeaders:{'X-Synthetic-Case':name}});
 await context.addInitScript(()=>{
  window.__qaNow=new Date('2026-11-18T08:00:00Z').getTime();Date.now=()=>window.__qaNow;
  const intervals=new Map();let nextId=5000;
  window.setInterval=(callback,ms,...args)=>{const id=++nextId;intervals.set(id,{callback,ms,args});return id;};
  window.clearInterval=id=>intervals.delete(id);
  window.__qaIntervals=intervals;
  window.__qaTick=async ms=>{for(const entry of [...intervals.values()])if(entry.ms===ms)await entry.callback(...entry.args);};
 });
 await context.route('**/*',route=>{const url=new URL(route.request().url());if(['http:','https:'].includes(url.protocol)&&url.origin!==origin){external.push(url.href);return route.abort();}return route.continue();});
 const page=await context.newPage();page.on('pageerror',error=>errors.push({case:name,message:error.message}));
 await page.goto(origin+'/#session=synthetic-startup-'+name,{waitUntil:'networkidle'});
 await page.waitForFunction(()=>window.__qaStartup&&window.__qaStartup.state.poll&&!window.__qaStartup.state.polling&&!window.__qaStartup.state.fetchingSnapshot);
 return {context,page,config};
}
async function tick(page,advance=0){await page.evaluate(async advance=>{window.__qaNow+=advance;await window.__qaTick(1300);},advance);}
async function due(page){await page.evaluate(async()=>{const state=window.__qaStartup.state;window.__qaNow=Math.max(window.__qaNow,state.libraryRetryAt);await window.__qaTick(1300);});}
async function expectedLoading(page){return page.locator('#error-banner').evaluate(node=>({hidden:node.hidden,source:node.dataset.source,loading:node.dataset.loading,role:node.getAttribute('role'),title:document.getElementById('error-title').textContent,message:document.getElementById('error-message').textContent}));}
(async()=>{
 result.sourceHashes=sourceHashes();
 try{
  const origin=await startServer();browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});result.browser=browser.version();
  {
   const {context,page,config}=await openCase(origin,'slow','loading');
   check(await page.evaluate(()=>window.__qaStartup.state.libraryWaiting),'Expected startup loading stays recoverable.');
   const first=await expectedLoading(page);
   check(!first.hidden&&first.source==='library'&&first.loading==='true'&&first.role==='status','Expected library loading uses an owned non-error status banner.');
   check(/automatically/i.test(first.message),'Loading guidance says the library will recover automatically.');
   const intervals=await page.evaluate(()=>[...window.__qaIntervals.values()].map(entry=>entry.ms));
   check(intervals.includes(1300)&&intervals.includes(30000),'Jobs polling and heartbeat are scheduled while the library is still opening.');
   const start=await page.evaluate(()=>Date.now());
   for(let attempt=0;attempt<8;attempt++){
    const before=count('slow','/api/snapshot'),wait=await page.evaluate(()=>window.__qaStartup.state.libraryRetryAt-Date.now());
    check(wait>0&&wait<=10000,'Startup retry '+attempt+' has bounded positive backoff.');
    await tick(page,Math.max(0,wait-1));same(count('slow','/api/snapshot'),before,'Startup retry '+attempt+' waits until its due time.');
    await due(page);same(count('slow','/api/snapshot'),before+1,'Startup retry '+attempt+' reads the existing snapshot once when due.');
   }
   check(await page.evaluate(start=>Date.now()-start>30000,start),'Automatic recovery remains active beyond the old thirty-second cutoff.');
   check(await page.evaluate(()=>!window.__qaStartup.state.snapshot&&window.__qaStartup.state.libraryWaiting),'No invented library data is rendered while waiting.');
   const waiting=await expectedLoading(page);check(waiting.role==='status'&&waiting.loading==='true','Expected loading remains a neutral status beyond thirty seconds.');
   const heartbeats=count('slow','/api/heartbeat');await page.evaluate(()=>window.__qaTick(30000));same(count('slow','/api/heartbeat'),heartbeats+1,'The scheduled heartbeat still runs during long startup.');
   check(count('slow','/api/jobs')>1,'Job polling continues during startup without requiring a job event.');
   let release;config.gate=new Promise(resolve=>release=resolve);config.mode='ready';
   await page.evaluate(()=>{window.__qaNow=Math.max(window.__qaNow,window.__qaStartup.state.libraryRetryAt);window.__pendingTick=window.__qaTick(1300);});
   await page.waitForFunction(()=>window.__qaStartup.state.fetchingSnapshot);
   const heldCount=count('slow','/api/snapshot');
   await page.evaluate(()=>{window.__extraRecoveries=Promise.all([window.__qaStartup.recoverLibraryIfDue(),window.__qaStartup.recoverLibraryIfDue(),window.__qaStartup.pollJobs()]);});
   await page.waitForTimeout(30);same(count('slow','/api/snapshot'),heldCount,'Concurrent startup recovery attempts coalesce while a snapshot is in flight.');
   release();config.gate=null;await page.evaluate(async()=>{await window.__pendingTick;await window.__extraRecoveries;});
   same(config.maxActive,1,'Startup recovery never starts overlapping snapshot requests.');
   same(await page.evaluate(()=>window.__qaStartup.state.records.map(record=>record.id)),snapshot().records.map(record=>record.id),'Automatic recovery loads every exact saved synthetic report.');
   check(await page.locator('#error-banner').isHidden(),'A successful automatic load clears its own stale loading banner.');
   check(await page.evaluate(()=>!window.__qaStartup.state.libraryWaiting),'Successful recovery clears the retry-wait state.');
   const readyCount=count('slow','/api/snapshot');await tick(page,60000);same(count('slow','/api/snapshot'),readyCount,'Startup retries stop after the first successful snapshot.');
   await page.evaluate(async()=>{window.__qaStartup.showError('Synthetic unrelated export problem','Export needs attention');await window.__qaStartup.refreshSnapshot();});
   check(await page.locator('#error-banner').isVisible(),'A later successful library refresh keeps an unrelated error visible.');
   same(await page.locator('#error-title').innerText(),'Export needs attention','Library recovery does not overwrite an unrelated error title.');
   await context.close();
  }
  {
   const {context,page,config}=await openCase(origin,'permission','permission');
   const failed=await expectedLoading(page);check(!failed.hidden&&failed.role==='alert'&&failed.loading!=='true','An actual saved-folder failure remains a real error rather than a loading status.');
   check(/folder permissions/i.test(failed.message),'Actual saved-folder failure retains its actionable explanation.');
   const before=count('permission','/api/snapshot');config.mode='ready';await page.locator('#retry-button').click();
   await page.waitForFunction(()=>window.__qaStartup.state.records.length===3);
   same(count('permission','/api/snapshot'),before+1,'Try again retries the library directly once.');
   check(await page.locator('#error-banner').isHidden(),'Successful manual retry clears the library-owned failure.');
   await context.close();
  }
  {
   const {context,page}=await openCase(origin,'expired','expired');
   const expired=await expectedLoading(page);check(!expired.hidden&&expired.role==='alert'&&/session expired/i.test(expired.message),'Expired authentication remains an actionable session error.');
   const before=count('expired','/api/snapshot');await tick(page,60000);await tick(page,60000);
   same(count('expired','/api/snapshot'),before,'An expired session is not retried indefinitely as normal startup loading.');
   await context.close();
  }
  same(mutations,[],'Startup recovery and manual retry never request scanner scans or another mutation.');
  same(external,[],'Startup recovery makes no external requests.');same(errors,[],'No unexpected browser errors occurred.');
  result.sourceHashesAtEnd=sourceHashes();same(result.sourceHashesAtEnd,result.sourceHashes,'The tested product files remain unchanged during the focused flow.');
  result.testedFiles=Object.fromEntries(Object.entries(result.sourceHashes).map(([name,sha])=>['App/Web/'+name,sha]));result.status='PASS';result.assertions=checks.length;
  console.log('PASS focused startup recovery: '+checks.length+' assertions.');
 }catch(error){result.status='FAIL';result.error=error.stack;result.assertions=checks.length;console.error(error.stack);process.exitCode=1;}
 finally{if(!result.sourceHashesAtEnd)result.sourceHashesAtEnd=sourceHashes();fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');if(browser)await browser.close();if(server){server.closeAllConnections?.();await new Promise(resolve=>server.close(resolve));}}
})();
