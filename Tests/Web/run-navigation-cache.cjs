/* One focused development-only navigation/cache flow. No test bridge is shipped. */
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {chromium}=require('playwright');
const args={};for(let i=2;i<process.argv.length;i+=2)args[process.argv[i].replace(/^--/,'')]=process.argv[i+1];
const root=path.resolve(__dirname,'../..'),web=path.join(root,'App/Web');
const output=path.resolve(args.output||path.join(root,'Tests/Navigation-Cache/result.json'));
const baselineAssets=args['baseline-assets']?path.resolve(args['baseline-assets']):null;
const counts=(args.counts||'1367,20000').split(',').map(Number);
const checks=[],requests=[],submitted=[],errors=[],external=[];
let snapshot,assets=web,phase='after',browser,server;
const hashAssets=directory=>Object.fromEntries(['index.html','app.css','app.js','trends.js'].map(name=>[name,crypto.createHash('sha256').update(fs.readFileSync(path.join(directory,name))).digest('hex')]));
const result={syntheticOnly:true,scope:'One production-web Chromium navigation/cache flow with generated snapshot/PNG/Trends responses and response-only instrumentation. Before/after timings use identical synthetic 1,367/20,000-record libraries. No Windows, PowerShell, scanner, real reader/archive, hospital throughput or clinical validation.',checks,results:[],errors,externalRequests:external};
function check(condition,name){assert.ok(condition,name);checks.push({name,result:'PASS'});}
function same(actual,expected,name){assert.deepEqual(actual,expected,name);checks.push({name,result:'PASS'});}
function json(response,value,status=200){response.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});response.end(JSON.stringify(value));}
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
// Reuse the existing deterministic synthetic library and valid generated PNG.
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
  return {version: '5.7.1', previewMode: 'Browser', workspace: 'Synthetic workspace', archiveRoot: 'Synthetic archive', libraryRoot: 'Synthetic report library', setupComplete: true,
    records, scanners, today: {date: '2026-11-16', received: 0, expected: 3, headline: '0 of 3 Daily QA reports received'},
    months: scanners.map(scanner => ({scanner: scanner.id, name: scanner.name, month: '2026-11', progress: '0 / 2 items', status: 'NoConfirmedReport', timing: 'Upcoming'})),
    analysis: {total: count, cached: 0, pending: count, errors: 0, measurementUpgradePending: 0, unsupportedUpgradePending: 0, backlogPending: count},
    trendsRevision: 'A'.repeat(64), settings: {monitorMinutes: 0, autoAnalyze: false, autoUpdateOnOpen: false, pdfReaderMode: 'Auto', theme: 'Light'},
    batchReviewLimit: 50, lastDecision: null, undoBatch: null};
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

function trendsResponse(params){
 const scanner=params.get('scanner')||snapshot.scanners[0].id,metric=params.get('metric')||'WaterCTNumber',unit=['WaterCTNumber','ImageNoise'].includes(metric)?'HU':'mm';
 const key=scanner+'|'+metric+'|Body|A|1',value=metric==='WaterCTNumber'?-1.25:1.75;
 const record=snapshot.records.find(row=>row.scanner===scanner&&!row.pending);
 return {scanners:snapshot.scanners.map(row=>({id:row.id,name:row.name})),selection:{scanner},selectedSeries:key,
  series:[{key,label:'Synthetic Body / System A / Slice 1',metric,count:1}],points:[{recordId:record.id,date:'2026-11-16',time:'08:00:00',value,unit,lower:-2,upper:2,page:1}],pendingIds:[],
  coverage:{savedReports:1,readReports:1,pendingReports:0},summary:{count:1,first:value,latest:value},totalPointCount:1};
}
async function startServer(){
 const pngBase64=portraitPng().toString('base64');
 server=http.createServer(async(request,response)=>{
  const url=new URL(request.url,'http://127.0.0.1'),pathname=url.pathname;
  requests.push({phase,method:request.method,pathname,query:url.searchParams.toString()});
  if(pathname==='/api/session'||pathname==='/api/heartbeat')return json(response,{});
  if(pathname==='/api/snapshot')return json(response,snapshot);
  if(pathname==='/api/jobs')return json(response,{jobs:[]});
  if(pathname==='/api/trends')return json(response,trendsResponse(url.searchParams));
  if(pathname.startsWith('/api/preview/'))return json(response,{recordId:pathname.slice('/api/preview/'.length),pageNumber:Number(url.searchParams.get('page')),pageCount:1,pngBase64});
  if(pathname==='/api/actions'){let body='';for await(const chunk of request)body+=chunk;submitted.push(JSON.parse(body));return json(response,{id:'synthetic-export-only-job'},202);}
  if(pathname==='/favicon.ico'){response.writeHead(204);return response.end();}
  const name={'/':'index.html','/index.html':'index.html','/app.js':'app.js','/app.css':'app.css','/trends.js':'trends.js'}[pathname];
  if(!name)return json(response,{error:'Unexpected synthetic route'},404);
  let content=fs.readFileSync(path.join(assets,name));
  if(name==='app.js')content=content.toString().replace('  boot().catch(',`  window.__qaBench={state,renderReports,renderSnapshot,refreshSnapshot,filteredRecords,showPage,showReportsView,clearFilters,copyReportsToExports,renderCalendar,renderFolders,renderExports,todayReportLinks,selectRecord,previewLimits,previewAssets:typeof previewAssets==='undefined'?null:previewAssets,browseCache:typeof browseCache==='undefined'?null:browseCache,browseCacheLimits:typeof browseCacheLimits==='undefined'?null:browseCacheLimits,cachedCalendar:typeof cachedCalendar==='undefined'?null:cachedCalendar};\n  boot().catch(`);
  if(name==='trends.js')content=content.toString().replace('  window.QaTrends={init,show,refresh};','  window.__qaTrendBench={state,load,refresh,show,queryCacheLimits:typeof queryCacheLimits==="undefined"?null:queryCacheLimits};\n  window.QaTrends={init,show,refresh};');
  response.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'application/javascript'});response.end(content);
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return 'http://127.0.0.1:'+server.address().port;
}
async function pageFor(origin,count){
 snapshot=makeSnapshot(count);snapshot.version='5.7.17';snapshot.previewMode='windows';
 const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'en-US'});
 await context.addInitScript(()=>{window.__qaNow=new Date('2026-11-17T08:00:00Z').getTime();Date.now=()=>window.__qaNow;});
 await context.route('**/*',route=>{const url=new URL(route.request().url());if(['http:','https:'].includes(url.protocol)&&url.origin!==origin){external.push(url.href);return route.abort();}return route.continue();});
 const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
 await page.goto(origin+'/#session=synthetic-navigation-cache-only');await page.waitForFunction(n=>window.__qaBench?.state.records.length===n,count);
 await page.evaluate(()=>{const b=window.__qaBench;clearInterval(b.state.poll);clearInterval(b.state.heartbeat);window.__calendarBuildCount=0;window.__calendarBuild=window.CTQaCalendar.build;window.CTQaCalendar={build(...args){window.__calendarBuildCount++;return window.__calendarBuild(...args);}};});
 return {page,context};
}
async function navigationMeasurement(page,count){
 return page.evaluate(async count=>{
  const b=window.__qaBench,$=id=>document.getElementById(id),measure=fn=>{const start=performance.now();fn();document.body.offsetHeight;return performance.now()-start;},median=items=>[...items].sort((a,b)=>a-b)[Math.floor(items.length/2)];
  b.state.reportsView='library';b.showPage('reports');b.clearFilters('reports');
  const first=b.filteredRecords();$('scanner-filter').value='CT_Flash';b.filteredRecords();$('scanner-filter').value='all';const back=b.filteredRecords();
  b.copyReportsToExports();const shared=b.filteredRecords('exports');
  b.showPage('folders');const folder=$('folder-library-tree').firstElementChild;folder.open=false;b.showPage('today');b.showPage('folders');const folderRetained=$('folder-library-tree').firstElementChild===folder,folderOpenPreserved=!$('folder-library-tree').firstElementChild.open;
  b.showPage('exports');const preview=$('export-preview-list').firstElementChild;b.showPage('today');b.showPage('exports');const exportRetained=$('export-preview-list').firstElementChild===preview;
  const todayA=b.todayReportLinks(),todayB=b.todayReportLinks();
  b.showPage('reports');b.showReportsView('calendar');b.state.calendarMonth='2026-11';$('calendar-month').value='2026-11';b.renderCalendar();
  const firstCalendarCount=window.__calendarBuildCount,calendarNode=$('calendar-grid').firstElementChild;b.renderCalendar();const calendarRepeatedCount=window.__calendarBuildCount-firstCalendarCount;
  const calendarDomRetained=$('calendar-grid').firstElementChild===calendarNode;
  b.state.calendarMonth='2026-10';$('calendar-month').value='2026-10';b.renderCalendar();b.state.calendarMonth='2026-11';$('calendar-month').value='2026-11';
  const beforeCalendarReturn=window.__calendarBuildCount;b.renderCalendar();const calendarReturnBuilds=window.__calendarBuildCount-beforeCalendarReturn;
  const expected=window.__calendarBuild(b.state.snapshot,'2026-11',''),actualSummary=$('calendar-summary').textContent;
  const renderedCalendarIds=[...document.querySelectorAll('#calendar-grid button')].map(node=>node.dataset.calendarDate);
  const timings={reports:[],calendar:[],folders:[],exports:[],unchangedSnapshot:[]};
  for(let n=0;n<5;n++){
   b.showPage('today');timings.reports.push(measure(()=>{b.showPage('reports');b.showReportsView('library');}));
   timings.calendar.push(measure(()=>b.showReportsView('calendar')));
   timings.folders.push(measure(()=>b.showPage('folders')));
   timings.exports.push(measure(()=>b.showPage('exports')));
   timings.unchangedSnapshot.push(measure(()=>b.renderSnapshot()));
  }
  b.clearFilters('reports');b.copyReportsToExports();
  return {count,medianMs:Object.fromEntries(Object.entries(timings).map(([name,items])=>[name,median(items)])),samplesMs:timings,
   repeatFilterSameArray:first===back,sharedFilterSameArray:back===shared,todaySameMetadata:todayA===todayB,folderRetained,folderOpenPreserved,exportRetained,
   calendarRepeatedBuilds:calendarRepeatedCount,calendarReturnBuilds,calendarDomRetained,calendarSummaryMatches:actualSummary.includes(`${expected.summary.received} of ${expected.summary.expected}`),renderedCalendarIds,expectedCalendarIds:expected.days.map(day=>day.date),
   exportIds:b.state.exportMatching.map(record=>record.id),expectedExportIds:b.state.sortedRecords.map(record=>record.id),exportPreviewRows:document.querySelectorAll('.export-preview-row').length,
   reportRows:document.querySelectorAll('#report-list .report-item').length};
 },count);
}
async function checkBounds(page,count){
 const bounded=await page.evaluate(()=>{
  const b=window.__qaBench,search=document.getElementById('report-search');b.clearFilters('reports');search.value='unmatched cache probe 0';const first=b.filteredRecords();
  for(let n=1;n<=9;n++){search.value='unmatched cache probe '+n;b.filteredRecords();}
  search.value='unmatched cache probe 0';const revisited=b.filteredRecords(),firstMonth=b.cachedCalendar('2024-01','').model;
  for(let n=1;n<=12;n++)b.cachedCalendar('2024-'+String(n).padStart(2,'0'),'');b.cachedCalendar('2025-01','');
  const returnedMonth=b.cachedCalendar('2024-01','').model;
  return {filterEvicted:first!==revisited,calendarEvicted:firstMonth!==returnedMonth,filters:b.browseCache.filters.size,filterItems:b.browseCache.filterItems,calendar:b.browseCache.calendar.size,calendarItems:b.browseCache.calendarItems,limits:b.browseCacheLimits};
 });
 check(bounded.filterEvicted,count+' filter cache evicts an old search at its entry bound');check(bounded.calendarEvicted,count+' calendar cache evicts an old month at its bound');
 check(bounded.filters<=bounded.limits.filters&&bounded.filterItems<=bounded.limits.filterItems,count+' filter cache stays within eight entries/eighty-thousand record references');
 check(bounded.calendar<=bounded.limits.calendar&&bounded.calendarItems<=bounded.limits.calendarItems,count+' calendar cache stays within twelve entries/forty-thousand report-ID references');
}
async function checkInvalidation(page,count){
 const old=snapshot.records[10].filename;Object.assign(snapshot.records[10],{filename:'SYNTHETIC_CHANGED_CACHE_RECORD.pdf',category:'Daily',date:'2026-11-16',stamp:'f'.repeat(64)});
 await page.evaluate(()=>window.__qaBench.refreshSnapshot());
 const changed=await page.evaluate(()=>{const b=window.__qaBench;b.clearFilters('reports');document.getElementById('report-search').value='SYNTHETIC_CHANGED_CACHE_RECORD';const filtered=b.filteredRecords();b.renderReports();b.copyReportsToExports();return {names:filtered.map(row=>row.filename),ids:b.state.exportMatching.map(row=>row.id),rows:document.querySelectorAll('.export-preview-row').length};});
 same(changed.names,['SYNTHETIC_CHANGED_CACHE_RECORD.pdf'],count+' changed report invalidates filter cache');same(changed.ids,[snapshot.records[10].id],count+' export retains the exact updated matching ID');same(changed.rows,1,count+' changed filter rebuilds the export preview');
 await page.evaluate(()=>{const b=window.__qaBench;b.showPage('folders');window.__oldFolder=document.getElementById('folder-library-tree').firstElementChild;});
 snapshot.scanners[0].name='Synthetic renamed scanner';snapshot.scanners[0].excludedDates=['2026-11-16'];snapshot.archiveRoot='Synthetic alternate archive';
 await page.evaluate(()=>window.__qaBench.refreshSnapshot());
 const res=await page.evaluate(()=>{const b=window.__qaBench;b.showPage('folders');const folderChanged=document.getElementById('folder-library-tree').firstElementChild!==window.__oldFolder;b.showPage('reports');b.showReportsView('calendar');const model=window.__calendarBuild(b.state.snapshot,'2026-11','');b.renderCalendar();return {folderChanged,folderText:document.getElementById('folder-library-tree').textContent,summary:document.getElementById('calendar-summary').textContent,expected:model.summary};});
 check(res.folderChanged&&res.folderText.includes('Synthetic renamed scanner'),count+' archive/scanner metadata invalidates the folder tree');check(res.summary.includes(`${res.expected.received} of ${res.expected.expected}`),count+' changed scanner schedule refreshes exact calendar receipt totals');
}
async function mediaCacheCheck(page){
 const trendCount=()=>requests.filter(row=>row.phase==='after'&&row.pathname==='/api/trends').length;
 await page.evaluate(()=>{window.__qaBench.showPage('trends');});await page.waitForFunction(()=>window.__qaTrendBench?.state.data&&!window.__qaTrendBench.state.loading);
 const before=trendCount();await page.locator('#trend-metric').selectOption('ImageNoise');await page.waitForFunction(()=>window.__qaTrendBench.state.metric==='ImageNoise'&&window.__qaTrendBench.state.data&&!window.__qaTrendBench.state.loading);
 const beforeReturn=trendCount();await page.locator('#trend-metric').selectOption('WaterCTNumber');await page.waitForFunction(()=>window.__qaTrendBench.state.metric==='WaterCTNumber'&&window.__qaTrendBench.state.data&&!window.__qaTrendBench.state.loading);
 same(trendCount(),beforeReturn,'Trends metric A→B→A reuses cached response');same(beforeReturn,before+1,'Different Trends metric initially makes one request');
 const reading=await page.evaluate(()=>{const s=window.__qaTrendBench.state;return s.data.points.map(p=>({value:p.value,unit:p.unit,lower:p.lower,upper:p.upper,page:p.page,recordId:p.recordId}));});
 same(reading,[{value:-1.25,unit:'HU',lower:-2,upper:2,page:1,recordId:snapshot.records.find(row=>row.scanner===snapshot.scanners[0].id&&!row.pending).id}],'Cached Trends retains exact value, units, printed bounds and source page');
 const beforeArchive=trendCount();snapshot.archiveRoot='Synthetic media alternate archive';await page.evaluate(()=>window.__qaBench.refreshSnapshot());await page.waitForFunction(()=>window.__qaTrendBench.state.data&&!window.__qaTrendBench.state.loading);
 same(trendCount(),beforeArchive+1,'Changing archive invalidates Trends even with the same opaque revision');
 const beforeExpiry=trendCount();await page.evaluate(()=>window.__qaNow+=300001);await page.locator('#trend-metric').selectOption('ImageNoise');await page.waitForFunction(()=>window.__qaTrendBench.state.metric==='ImageNoise'&&window.__qaTrendBench.state.data&&!window.__qaTrendBench.state.loading);same(trendCount(),beforeExpiry+1,'An expired Trends query requires fresh data');
 const trendResources=await page.evaluate(()=>{const t=window.__qaTrendBench;return {entries:t.state.queryCache.size,bytes:t.state.queryCacheBytes,limits:t.queryCacheLimits};});
 check(trendResources.entries<=trendResources.limits.entries&&trendResources.bytes<=trendResources.limits.bytes,'Trends response cache remains within eight queries/two MiB');

 const ids=snapshot.records.filter(row=>!row.pending).slice(0,2).map(row=>row.id),previewCount=()=>requests.filter(row=>row.phase==='after'&&row.pathname.startsWith('/api/preview/')).length;
 async function open(id){await page.evaluate(id=>window.__qaBench.selectRecord(id,{viewOnly:true}),id);await page.waitForFunction(id=>window.__qaBench.state.previewId===id&&window.__qaBench.state.previewEntries.get(0)?.status==='loaded',id);}
 await open(ids[0]);await open(ids[1]);const beforePdfReturn=previewCount();await open(ids[0]);same(previewCount(),beforePdfReturn,'PDF A→B→A reuses the successful page without a renderer request');
 snapshot.records.find(row=>row.id===ids[0]).stamp='e'.repeat(64);await page.evaluate(()=>window.__qaBench.refreshSnapshot());await page.waitForFunction(()=>window.__qaBench.state.previewEntries.get(0)?.status==='loaded');same(previewCount(),beforePdfReturn+1,'Changed report stamp invalidates the displayed PDF page');
 for(const row of snapshot.records.filter(row=>!row.pending).slice(2,23))await open(row.id);
 const resources=await page.evaluate(()=>{const b=window.__qaBench;return {pages:b.previewAssets?.size,bytes:b.state.previewCacheBytes,limits:b.previewLimits};});
 check(resources.pages<=resources.limits.pages&&resources.bytes<=resources.limits.bytes,'PDF documents share the existing twenty-page/thirty-MiB limits');
}
(async()=>{
 fs.mkdirSync(path.dirname(output),{recursive:true});const origin=await startServer();browser=await chromium.launch({executablePath:args.chromium||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});result.browser=browser.version();result.sourceHashes=hashAssets(web);if(baselineAssets){result.baselineSource='v5.7.16';result.baselineSourceHashes=hashAssets(baselineAssets);}
 try{
  for(const mode of baselineAssets?['baseline','after']:['after']){phase=mode;assets=mode==='baseline'?baselineAssets:web;
   for(const count of counts){const {page,context}=await pageFor(origin,count);try{
    const observation=await navigationMeasurement(page,count);const {exportIds,expectedExportIds,...recorded}=observation;result.results.push({phase:mode,...recorded});
    same(exportIds,expectedExportIds,mode+' '+count+' exports retain every exact matching ID in order');same(observation.exportPreviewRows,12,mode+' '+count+' export preview stays at twelve rows');same(observation.reportRows,100,mode+' '+count+' report page stays at one hundred rows');same(observation.renderedCalendarIds,observation.expectedCalendarIds,mode+' '+count+' calendar retains all exact day identities');check(observation.calendarSummaryMatches,mode+' '+count+' calendar totals match the pure receipt model');
    if(mode==='after'){check(observation.repeatFilterSameArray,count+' revisiting a filter reuses its result array');check(observation.sharedFilterSameArray,count+' Reports and Exports share the same matching result');check(observation.todaySameMetadata,count+' unchanged Today report metadata is reused');check(observation.calendarDomRetained,count+' unchanged calendar keeps its existing day nodes');check(observation.folderRetained&&observation.folderOpenPreserved,count+' unchanged Folders keeps tree nodes and expanded state');check(observation.exportRetained,count+' unchanged Exports keeps preview nodes');same(observation.calendarRepeatedBuilds,0,count+' unchanged calendar avoids another metadata build');same(observation.calendarReturnBuilds,0,count+' returning to a calendar month reuses its model');const recovered=await page.evaluate(()=>{const b=window.__qaBench;b.showPage('reports');b.showReportsView('calendar');b.state.calendarMonth='invalid';b.renderCalendar();const empty=document.querySelectorAll('#calendar-grid button').length===0;b.state.calendarMonth='2026-11';document.getElementById('calendar-month').value='2026-11';b.renderCalendar();return {empty,count:document.querySelectorAll('#calendar-grid button').length};});check(recovered.empty&&recovered.count===30,count+' a valid cached month restores calendar days after invalid input');await checkBounds(page,count);await checkInvalidation(page,count);if(count===counts[0])await mediaCacheCheck(page);}
   }finally{await context.close();}}
  }
  check(!errors.length,'No unexpected browser errors');same(external,[],'No external requests');same(submitted,[],'Read-only caching checks submit no mutation action');result.status='PASS';result.assertions=checks.length;
 }catch(error){result.status='FAIL';result.error=error.stack;process.exitCode=1;console.error(error.stack);}
 finally{result.sourceHashesAtEnd=hashAssets(web);result.sourceHashesStable=JSON.stringify(result.sourceHashes)===JSON.stringify(result.sourceHashesAtEnd);if(!result.sourceHashesStable){result.status='FAIL';result.error='Product source changed during the focused flow.';process.exitCode=1;}result.testedFiles=Object.fromEntries(Object.entries(result.sourceHashesAtEnd).map(([name,sha])=>['App/Web/'+name,sha]));result.requests=requests;fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');await browser?.close();server?.closeAllConnections?.();await new Promise(resolve=>server.close(resolve));console.log(result.status+' focused navigation cache: '+checks.length+' assertions.');}
})().catch(error=>{console.error(error);process.exitCode=1;server?.close();});
