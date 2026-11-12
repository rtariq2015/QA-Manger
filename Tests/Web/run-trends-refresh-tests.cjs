'use strict';
// Controller regressions use actual refresh/load/normalization code with
// controlled promises. Browser rendering and real HTTP are tested separately.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),args={};
for(let i=2;i<process.argv.length;i+=2){if(!['--source','--output'].includes(process.argv[i])||!process.argv[i+1])throw new Error('Use --source FILE and/or --output FILE.');args[process.argv[i].slice(2)]=process.argv[i+1];}
const sourcePath=args.source?path.resolve(args.source):path.join(root,'App/Web/trends.js'),original=fs.readFileSync(sourcePath,'utf8');
let assertions=0;const results=[];
const check=(condition,message)=>{assertions++;if(!condition)throw new Error(message);};
const clone=value=>JSON.parse(JSON.stringify(value)),tick=()=>new Promise(resolve=>setImmediate(resolve));
async function flush(){for(let n=0;n<3;n++)await tick();}
function harness(){
 let source=original;
 for(const [start,end,replacement] of [['  function updateReadButton() {','  function renderCoverage()','  function updateReadButton() {}\n'],['  function render() {','  async function load()','  function render() {}\n']]){
  const a=source.indexOf(start),b=source.indexOf(end,a);if(a<0||b<=a)throw new Error('The controller render seam changed; inspect the regression fixture.');source=source.slice(0,a)+replacement+source.slice(b);
 }
 const exported='window.QaTrends={init,show,refresh};';if(!source.includes(exported))throw new Error('The controller export changed.');
 source=source.replace(exported,'window.__test={state,load,refresh,show,METRICS};'+exported);
 const context={window:{},document:{body:{dataset:{page:'trends'}},getElementById:()=>null},AbortController,URLSearchParams};
 vm.runInNewContext(source,context,{filename:'actual-trends-controller.js'});
 const api=context.window.__test,requests=[];api.state.ready=true;api.state.scanner='S';api.state.scanners=[{id:'S',name:'Synthetic scanner'}];api.state.period='all';
 api.state.api=(url,options)=>new Promise((resolve,reject)=>requests.push({url,signal:options?.signal,resolve,reject}));
 return {...api,requests,document:context.document};
}
function snapshot(revision='a',extra={}){return {trendsRevision:revision.repeat(64),scanners:[{id:'S',name:'Synthetic scanner'}],records:[],analysis:{cached:1,pending:0},...extra};}
function raw(scanner='S',value=0.25,metric='WaterCTNumber'){
 const table=metric==='TablePosition',unit=table?'mm':'HU',series=scanner+'|'+metric+(table?'|Unspecified|NotSpecified|ContinuousPosition1':'|Body|A|1');
 return {scanners:[{id:scanner,name:'Synthetic scanner'}],selection:{scanner},selectedSeries:series,series:[{key:series,label:table?'Continuous movement / Position 1':'Body / System A / Slice 1',metric,count:1}],points:[{recordId:'a'.repeat(64),date:'2026-10-19',time:'09:14:27',value,unit,lower:-1.5,upper:1.5,page:3}],pendingIds:[],coverage:{savedReports:1,readReports:1,pendingReports:0},summary:{count:1},totalPointCount:1};
}
async function scenario(name,body){try{await body();results.push({name,result:'PASS'});console.log('PASS '+name);}catch(error){results.push({name,result:'FAIL',detail:error.message});console.log('FAIL '+name+': '+error.message);}}
(async()=>{
 await scenario('Identical validated snapshots issue one request and settle while new object instances keep arriving',async()=>{
  const h=harness(),saved=snapshot();h.refresh(clone(saved));check(h.requests.length===1,'The initial graph request starts.');
  for(let n=0;n<5;n++){const next=clone(saved);next.scanners[0].status='Metadata '+n;next.settings={theme:n%2?'Dark':'Light'};h.refresh(next);}
  check(h.requests.length===1,'Five metadata-only snapshots do not start duplicate in-flight work.');h.requests[0].resolve(raw());await flush();
  check(h.state.loading===false&&h.state.dirty===false&&h.state.data.points.length===1,'The real load and normalization settle with visible saved data.');
  for(let n=0;n<5;n++)h.refresh(clone(saved));await flush();check(h.requests.length===1&&!h.state.loading,'Repeated settled snapshots do not refetch.');
  h.show();await flush();check(h.requests.length===1,'A default selected series is cached without an extra query.');
 });
 await scenario('Changes during one in-flight request coalesce into one follow-up for the latest revision',async()=>{
  const h=harness();h.refresh(snapshot('a'));h.refresh(snapshot('b'));h.refresh(snapshot('c'));h.refresh(snapshot('c'));
  check(h.requests.length===1,'Only one request runs while revisions change.');h.requests[0].resolve(raw('S',0.25));await flush();
  check(h.requests.length===2,'Exactly one follow-up processes the latest revision.');h.requests[1].resolve(raw('S',0.75));await flush();
  check(!h.state.loading&&!h.state.dirty&&h.state.data.points[0].value===0.75,'The latest response settles with its actual normalized value.');
  h.refresh(snapshot('c'));await flush();check(h.requests.length===2,'The latest unchanged revision does not request a third fetch.');
 });
 await scenario('Legacy helpers use stable graph semantics rather than object or record order',async()=>{
  const h=harness(),saved=snapshot();delete saved.trendsRevision;
  saved.records=[{id:'one',scanner:'S',date:'2026-10-19',content:{status:'Recognized',measurementStatus:'Extracted',measurements:[{label:'Water CT value',value:'0.25',unit:'HU',page:3,context:'Body / System A / Slice 1'}]}},{id:'two',scanner:'S',date:'2026-10-18',content:{status:'NotRead',measurements:[]}}];
  h.refresh(clone(saved));h.requests[0].resolve(raw());await flush();
  const reordered=clone(saved);reordered.records.reverse();reordered.scanners[0].message='Unrelated connection metadata';reordered.analysis.elapsed=500;h.refresh(reordered);await flush();
  check(h.requests.length===1&&!h.state.loading,'Equivalent reordered metadata does not refresh an older-helper graph.');
  const changed=clone(saved);changed.records[0].content.measurements[0].value='0.75';h.refresh(changed);
  check(h.requests.length===2,'A real public measurement change invalidates legacy-helper data.');h.requests[1].resolve(raw('S',0.75));await flush();check(h.state.data.points[0].value===0.75,'The changed current value is accepted.');
 });
 await scenario('Scanner changes abort stale requests and cannot overwrite the new selected scanner',async()=>{
  const h=harness();h.refresh(snapshot('a'));h.refresh(snapshot('b',{scanners:[{id:'T',name:'Synthetic replacement scanner'}]}));
  check(h.requests.length===2&&h.requests[0].signal.aborted,'The old scanner request is aborted when selection changes.');
  h.requests[0].resolve(raw('S',99));await flush();check(h.state.scanner==='T'&&h.state.data===null,'The stale response does not restore old scanner data.');
  h.requests[1].resolve(raw('T',0.5));await flush();check(!h.state.loading&&h.state.scanner==='T'&&h.state.data.points[0].value===0.5,'The current scanner response settles normally.');
 });
 await scenario('Unchanged snapshots do not turn one request failure into an automatic retry loop',async()=>{
  const h=harness();h.refresh(snapshot('a'));h.requests[0].reject(new Error('Synthetic controlled failure'));await flush();
  check(!h.state.loading&&typeof h.state.error==='string'&&h.state.error.length>0,'A failure settles and remains visible.');
  for(let n=0;n<5;n++)h.refresh(snapshot('a'));await flush();check(h.requests.length===1,'Identical snapshots do not silently retry the failure.');
  h.load();check(h.requests.length===2,'An explicit retry remains available.');h.requests[1].resolve(raw());await flush();check(!h.state.loading&&!h.state.error,'The successful retry clears the controlled error.');
 });
 await scenario('Hidden Trends coalesces changes until it is opened',async()=>{
  const h=harness();h.document.body.dataset.page='today';h.refresh(snapshot('a'));h.refresh(snapshot('b'));check(h.requests.length===0&&h.state.dirty,'Hidden snapshots do not start graph work.');
  h.document.body.dataset.page='trends';h.show();check(h.requests.length===1,'Opening Trends loads the latest available revision once.');h.requests[0].resolve(raw());await flush();
  h.show();h.refresh(snapshot('b'));await flush();check(h.requests.length===1&&!h.state.loading,'Reopening cached unchanged data performs no repeated work.');
 });
 await scenario('Table position retains millimetres and the explicitly selected movement context',async()=>{
  const h=harness();h.state.metric='TablePosition';check(h.METRICS.TablePosition?.unit==='mm','The fixed TablePosition descriptor is a millimetre metric.');
  h.refresh(snapshot('a'));h.requests[0].resolve(raw('S',0.23,'TablePosition'));await flush();
  check(h.state.data.points.length===1&&h.state.data.points[0].unit==='mm'&&h.state.data.points[0].value===0.23,'The current table value keeps its metric unit.');
  check(h.state.series.endsWith('|ContinuousPosition1')&&h.state.seriesLabel==='Continuous movement / Position 1','The displayed series uses the fixed method and position supplied by the validated backend.');
 });
 const report={tests:results.length,assertions,failed:results.filter(row=>row.result==='FAIL').length,syntheticOnly:true,controllerOnly:true,actualBrowser:false,sourceSHA256:crypto.createHash('sha256').update(original).digest('hex'),results,scope:'Actual App/Web/trends.js refresh/load/query/normalization functions with controlled asynchronous responses; DOM chart and read-button rendering are stubbed. No browser, PDF, network, hospital access or reader-speed claim. The separate actual-host browser workload covers rendered behavior.'};
 if(args.output){const out=path.resolve(args.output);fs.mkdirSync(path.dirname(out),{recursive:true});fs.writeFileSync(out,JSON.stringify(report,null,2)+'\n');}
 console.log('Result: '+(report.tests-report.failed)+'/'+report.tests+' controller scenarios; '+assertions+' assertions.');if(report.failed)process.exitCode=1;
})().catch(error=>{console.error(error.message);process.exitCode=1;});
