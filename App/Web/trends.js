'use strict';
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const MAX_POINTS = 1000;
  const METRICS = {WaterCTNumber:{label:'Water CT number',unit:'HU',axisLabel:'Hounsfield units (HU)'},ImageNoise:{label:'Image noise',unit:'HU',axisLabel:'Hounsfield units (HU)'},SliceThickness:{label:'Slice thickness',unit:'mm',axisLabel:'Millimetres (mm)'},Lightmarker:{label:'Light marker alignment',unit:'mm',axisLabel:'Millimetres (mm)'},ExternalLightmarker:{label:'External light marker',unit:'mm',axisLabel:'Millimetres (mm)'},TopogramPosition:{label:'Topogram position',unit:'mm',axisLabel:'Millimetres (mm)'},SagittalCoronalLightmarker:{label:'Sagittal / coronal alignment',unit:'mm',axisLabel:'Millimetres (mm)'},TablePosition:{label:'Table position',unit:'mm',axisLabel:'Millimetres (mm)'}};
  const metricDefinition=()=>METRICS[state.metric]||METRICS.WaterCTNumber;
  const metricLabel=()=>metricDefinition().label;
  const metricUnit=()=>metricDefinition().unit;
  const PERIODS = new Set(['30','90','365','all']);
  const state = {ready:false, api:null, openRecord:null, readPending:null, isBusy:()=>false, isBackgroundReading:()=>false, snapshot:null, sourceRevision:'', dataRevision:'', scanners:[], scanner:'', metric:'WaterCTNumber', series:'', seriesLabel:'', period:'90', data:null, dataKey:'', dirty:true, loading:false, controller:null, generation:0, requestKey:'', reading:false, error:'', notice:''};
  const $ = id => document.getElementById(id);
  const text = value => value == null ? '' : String(value);
  const list = value => Array.isArray(value) ? value : [];
  const number = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
  const format = value => new Intl.NumberFormat(undefined,{maximumFractionDigits:6}).format(value);
  const count = value => Math.max(0,Math.floor(Number(value)||0)).toLocaleString();
  const visible = () => document.body.dataset.page === 'trends';
  function field(object,...names) {
    if (!object || typeof object !== 'object') return undefined;
    for (const name of names) {
      if (Object.prototype.hasOwnProperty.call(object,name)) return object[name];
      const key=Object.keys(object).find(item=>item.toLowerCase()===name.toLowerCase());
      if (key !== undefined) return object[key];
    }
  }
  function snapshotRevision(snapshot) {
    const supplied=text(field(snapshot,'trendsRevision'));
    if(/^[0-9a-f]{64}$/i.test(supplied))return 'validated:'+supplied.toLowerCase();
    // Compatibility for an older local helper: compare only known graph data,
    // never object identity, job progress, appearance or connection messages.
    // The current helper supplies its validated opaque revision instead.
    const scalar=value=>['string','number','boolean'].includes(typeof value)?value:null;
    const scanners=normalizeScanners(field(snapshot,'scanners')).map(item=>[item.id,item.name]).sort((a,b)=>a[0].localeCompare(b[0]));
    const records=list(field(snapshot,'records')).map(record=>{
      const content=field(record,'content')||{};
      const measurements=list(field(content,'measurements')).slice(0,100).map(row=>['label','value','unit','page','lower','upper','context'].map(name=>scalar(field(row,name)))).map(row=>JSON.stringify(row)).sort();
      const components=list(field(content,'components')).map(row=>['name','result','page'].map(name=>scalar(field(row,name)))).map(row=>JSON.stringify(row)).sort();
      return JSON.stringify([
        ...['id','scanner','date','time','stamp','isReference','hasReferenceEvidence'].map(name=>scalar(field(record,name))),
        ...['status','profileId','date','time','dateStatus','readPages','pages','completeRead','measurementStatus','isReference','hasReferenceEvidence'].map(name=>scalar(field(content,name))),measurements,components
      ]);
    }).sort();
    const analysis=field(snapshot,'analysis')||{};
    return 'legacy:'+JSON.stringify([scanners,records,['cached','pending','errors','measurementUpgradePending','unsupportedUpgradePending'].map(name=>scalar(field(analysis,name)))]);
  }
  function html(tag,className,value) {
    const node=document.createElement(tag);
    if (className) node.className=className;
    if (value !== undefined) node.textContent=value;
    return node;
  }
  function svg(tag,attributes={},value) {
    const node=document.createElementNS(NS,tag);
    for (const [key,item] of Object.entries(attributes)) node.setAttribute(key,String(item));
    if (value !== undefined) node.textContent=value;
    return node;
  }
  function setText(id,value) {const node=$(id);if(node)node.textContent=value;}
  function localDate(value) {
    const match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(text(value).slice(0,10));
    if (!match) return null;
    const [year,month,day]=match.slice(1).map(Number), date=new Date(0);
    date.setFullYear(year,month-1,day);date.setHours(12,0,0,0);
    return date.getFullYear()===year && date.getMonth()===month-1 && date.getDate()===day ? date : null;
  }
  function dateKey(date) {
    return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
  }
  function dateLabel(value,year=true) {
    const date=localDate(value);
    return date ? new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',...(year?{year:'numeric'}:{})}).format(date) : 'Date unavailable';
  }
  function windowDates() {
    if (state.period==='all') return {};
    const end=new Date();end.setHours(12,0,0,0);
    const start=new Date(end);start.setDate(start.getDate()-Number(state.period)+1);
    return {start:dateKey(start),end:dateKey(end)};
  }
  function query() {
    const params=new URLSearchParams({metric:state.metric});
    if(state.scanner)params.set('scanner',state.scanner);
    if(state.series)params.set('series',state.series);
    const dates=windowDates();
    if(dates.start)params.set('start',dates.start);
    if(dates.end)params.set('end',dates.end);
    return params.toString();
  }
  function options(control,items,selected,emptyLabel) {
    if(!control)return;
    const desired=items.length ? items : [{value:'',label:emptyLabel}];
    if(control.options.length!==desired.length || desired.some((item,index)=>control.options[index].value!==item.value || control.options[index].textContent!==item.label)) {
      control.replaceChildren();
      for(const item of desired){const option=html('option','',item.label);option.value=item.value;control.append(option);}
    }
    control.value=selected;
    if(control.selectedIndex<0)control.selectedIndex=0;
    control.disabled=!items.length;
  }
  function normalizeScanners(value) {
    const seen=new Set();
    return list(value).map(item=>({id:text(field(item,'id','scannerId','scanner')),name:text(field(item,'name','scannerName'))})).filter(item=>item.id&&!seen.has(item.id)&&seen.add(item.id));
  }
  function updateScanners(scanners) {
    if(scanners.length)state.scanners=scanners;
    const previous=state.scanner;
    if(!state.scanners.some(item=>item.id===state.scanner))state.scanner=state.scanners[0]?.id||'';
    options($('trend-scanner'),state.scanners.map(item=>({value:item.id,label:item.name||item.id})),state.scanner,'No saved scanners');
    if(previous!==state.scanner){state.series='';state.seriesLabel='';state.data=null;state.dataKey='';state.dirty=true;}
  }
  function currentSeries() {return state.data?.series.find(item=>item.key===state.series)||null;}
  function contextLabel(series) {
    if(!series)return 'Measurement context unavailable';
    return series.label || [series.mode&&`Mode ${series.mode}`,series.system&&`System ${series.system}`,series.slice&&`Slice ${series.slice}`].filter(Boolean).join(' · ') || 'Context not printed';
  }
  function normalizeData(raw) {
    const series=list(raw.series).map(item=>({key:text(item.key),label:text(item.label),metric:text(item.metric),mode:text(item.mode),system:text(item.system),slice:text(item.slice),count:Number(item.count)||0})).filter(item=>item.key&&(!item.metric||item.metric===state.metric));
    const selected=text(raw.selectedSeries);
    const selectedSeries=series.find(item=>item.key===selected);
    const dates=windowDates();let omitted=0, invalidBounds=0;
    const points=[];
    if(selectedSeries)for(const item of list(raw.points)) {
      const date=text(item.date).slice(0,10), value=number(item.value),recordId=text(item.recordId),unit=text(item.unit);
      if(!localDate(date)||value===null||!recordId||unit!==metricUnit()){omitted++;continue;}
      if((dates.start&&date<dates.start)||(dates.end&&date>dates.end)){omitted++;continue;}
      let lower=number(item.lower),upper=number(item.upper);
      if(lower!==null&&upper!==null&&lower>upper){lower=null;upper=null;invalidBounds++;}
      points.push({recordId,date,time:text(item.time),value,unit:metricUnit(),lower,upper,page:Number.isInteger(item.page)&&item.page>0?item.page:null,reviewWarning:item.reviewWarning===true,outsidePrintedRange:item.outsidePrintedRange===true||(lower!==null&&value<lower)||(upper!==null&&value>upper),warnings:list(item.warnings).map(text)});
    }
    points.sort((a,b)=>a.date.localeCompare(b.date)||a.time.localeCompare(b.time)||a.recordId.localeCompare(b.recordId));
    const pendingIds=[...new Set(list(raw.pendingIds).map(text).filter(Boolean))].slice(0,100);
    return {series,selectedSeries:selectedSeries?.key||'',points,pendingIds,coverage:raw.coverage||{},summary:raw.summary||{},message:text(raw.message),notes:list(raw.notes).map(text).filter(Boolean),pointLimitReached:raw.pointLimitReached===true,dataLimitReached:raw.dataLimitReached===true,totalPointCount:Number(raw.totalPointCount)||points.length,omitted,invalidBounds,contextMissing:!selectedSeries&&list(raw.points).length>0};
  }
  function pendingIds() {return state.data?.pendingIds||[];}
  function updateReadButton() {
    const button=$('trend-read-pending');if(!button)return;
    const pending=pendingIds().length,background=Boolean(state.isBackgroundReading()),busy=state.reading||background||Boolean(state.isBusy());
    button.disabled=state.loading||busy||!pending;
    button.textContent=busy?(state.reading?'Reading measurements…':background?'Background reading in progress':'Another task is running…'):pending?`Read ${Math.min(20,pending)} saved PDF${Math.min(20,pending)===1?'':'s'}`:'No measurements waiting';
    button.title=background?'Finish or stop the current background reading before starting another batch. Use Pause or Resume in the reading status bar.':pending>20?'Reads the next 20 saved PDFs; completed measurements remain cached.':'Read printed measurements from saved PDFs.';
  }
  function renderCoverage() {
    const coverage=state.data?.coverage;
    if(!coverage){setText('trend-coverage',state.loading?'Checking saved measurement coverage…':'Measurements appear after supported PDFs have been read.');return;}
    const data=state.data,series=currentSeries(),readings=Number(data?.summary?.count??data?.totalPointCount??data?.points?.length)||0;
    const details=[`${count(coverage.readReports)} of ${count(coverage.savedReports)} saved PDFs read for this scanner and period`,`${count(coverage.pendingReports)} waiting for text or measurement reading`,`${count(readings)} ${metricLabel()} readings${series?' · '+contextLabel(series):' in the selected context'}`];
    const hasSpecificAvailability=number(coverage.metricNotPresentReports)!==null&&number(coverage.metricUnavailableReports)!==null;
    if(hasSpecificAvailability){
      if(coverage.metricNotPresentReports>0)details.push(`${count(coverage.metricNotPresentReports)} PDFs do not contain this test section`);
      if(coverage.metricUnavailableReports>0)details.push(`${count(coverage.metricUnavailableReports)} PDFs have no usable value for this measurement`);
    }else if(Number(coverage.unsupportedReports)>0)details.push(`${count(coverage.unsupportedReports)} PDFs have no usable value for this measurement; the test may be absent or its evidence unresolved`);
    for(const [key,label] of [['failedReports','PDFs could not be read'],['conflicts','with conflicting evidence'],['unknownDates','without a usable printed date'],['referenceReports','reference documents excluded from current readings']])if(Number(coverage[key])>0)details.push(`${count(coverage[key])} ${label}`);
    setText('trend-coverage',details.join(' · ')+'. One PDF can contain several readings.');
  }
  function boundsLabel(point) {
    if(point.lower!==null&&point.upper!==null)return `${format(point.lower)} to ${format(point.upper)} ${point.unit||metricUnit()}`;
    if(point.lower!==null)return `Lower: ${format(point.lower)} ${point.unit||metricUnit()}`;
    if(point.upper!==null)return `Upper: ${format(point.upper)} ${point.unit||metricUnit()}`;
    return 'Not printed';
  }
  function pointLabel(point,series) {
    return `${dateLabel(point.date)}${point.time?' at '+point.time:''}: ${format(point.value)} ${point.unit||metricUnit()}. Printed limits: ${boundsLabel(point)}. ${contextLabel(series)}.${point.outsidePrintedRange?' Outside printed range.':''}${point.reviewWarning?' Source report needs review.':''} Open source PDF${point.page?', page '+point.page:''}.`;
  }
  function openSource(event,point) {
    event.preventDefault();
    if(typeof state.openRecord==='function')state.openRecord(point.recordId,point.page);
  }
  function renderTable(points,series) {
    const body=$('trend-table-body');if(!body)return;body.replaceChildren();
    if(!points.length){const row=html('tr'),cell=html('td','muted',state.loading?'Loading saved measurements…':'No dated readings in this view.');cell.colSpan=5;row.append(cell);body.append(row);return;}
    const fragment=document.createDocumentFragment();
    for(const point of [...points].reverse()) {
      const row=html('tr'),date=html('td'),value=html('td'),bounds=html('td','',boundsLabel(point)),context=html('td','',contextLabel(series)),source=html('td');
      const dateText=html('time','',dateLabel(point.date));dateText.dateTime=point.date;date.append(dateText);
      if(point.time)date.append(html('div','muted',point.time));
      value.append(html('span','',`${format(point.value)} ${point.unit||metricUnit()}`));
      if(point.outsidePrintedRange){const warning=html('div','', 'Outside printed range');warning.style.color='var(--amber)';value.append(warning);}
      if(point.reviewWarning)context.append(html('div','muted','Review source report'));
      const link=html('a','text-button',`Open PDF${point.page?' · p. '+point.page:''}`);link.href='#review';link.setAttribute('aria-label',`Open source PDF for ${dateLabel(point.date)}${point.page?', page '+point.page:''}`);link.addEventListener('click',event=>openSource(event,point));source.append(link);
      row.append(date,value,bounds,context,source);fragment.append(row);
    }
    body.append(fragment);
  }
  function emptyChart(title,message,retry=false) {
    const container=$('trend-chart');if(!container)return;
    container.replaceChildren();container.setAttribute('role','group');container.setAttribute('aria-label','Measurement trend chart');container.style.display='block';
    const empty=html('div','trend-empty');empty.style.margin='0 auto';empty.append(html('h3','',title),html('p','',message));
    if(retry){const button=html('button','button button-small button-outline','Try again');button.type='button';button.style.marginTop='16px';button.addEventListener('click',()=>{state.dirty=true;load();});empty.append(button);}
    container.append(empty);
  }
  function renderChart(points,series) {
    const container=$('trend-chart');if(!container)return;
    if(!points.length){emptyChart(state.loading?'Loading measurements…':state.error?'Measurements could not load':'No readings in this period',state.error||state.data?.message||'Choose another period or read supported saved PDFs. Different modes, systems and slices remain separate.',Boolean(state.error));return;}
    container.replaceChildren();container.style.display='block';container.setAttribute('role','group');container.setAttribute('aria-label',`${metricLabel()} readings and source reports`);
    const width=960,height=410,left=75,right=790,top=62,bottom=330;
    const chart=svg('svg',{viewBox:`0 0 ${width} ${height}`,role:'group','aria-labelledby':'qa-trend-svg-title qa-trend-svg-description'});
    chart.append(svg('title',{id:'qa-trend-svg-title'},`${metricLabel()} in ${metricUnit()} — ${contextLabel(series)}`));
    chart.append(svg('desc',{id:'qa-trend-svg-description'},`${points.length} dated printed readings. Horizontal axis: printed report date. Vertical axis: ${metricDefinition().axisLabel}. Dashed lines and shading show reference limits printed in each source PDF where available. Amber diamonds are outside the printed range. These descriptions do not create clinical approval. Focus a point for its value and limits, then activate it to open the source report. The table below contains the same readings.`));
    const allValues=points.flatMap(point=>[point.value,...(point.lower===null?[]:[point.lower]),...(point.upper===null?[]:[point.upper])]);
    let min=Math.min(...allValues),max=Math.max(...allValues);const padding=Math.max((max-min)*.12,(max===min?Math.max(Math.abs(min)*.1,.5):.05));min-=padding;max+=padding;
    const first=localDate(points[0].date).getTime(),last=localDate(points[points.length-1].date).getTime();
    const x=point=>last===first?(left+right)/2:left+(localDate(point.date).getTime()-first)/(last-first)*(right-left);
    const y=value=>bottom-(value-min)/(max-min)*(bottom-top);
    for(let tick=0;tick<=4;tick++) {
      const value=min+(max-min)*tick/4,position=y(value);
      chart.append(svg('line',{x1:left,y1:position,x2:right,y2:position,class:'chart-grid'}));
      chart.append(svg('text',{x:left-12,y:position+4,'text-anchor':'end',class:'chart-label'},new Intl.NumberFormat(undefined,{maximumFractionDigits:3}).format(value)));
    }
    chart.append(svg('line',{x1:left,y1:top,x2:left,y2:bottom,class:'chart-axis'}),svg('line',{x1:left,y1:bottom,x2:right,y2:bottom,class:'chart-axis'}));
    chart.append(svg('text',{x:20,y:(top+bottom)/2,transform:`rotate(-90 20 ${(top+bottom)/2})`,'text-anchor':'middle'},metricDefinition().axisLabel));
    const dates=[...new Set(points.map(point=>point.date))],tickIndexes=[...new Set([0,Math.floor((dates.length-1)/2),dates.length-1])];
    for(const index of tickIndexes){const date=dates[index],position=x({date});chart.append(svg('line',{x1:position,y1:bottom,x2:position,y2:bottom+5,class:'chart-axis'}),svg('text',{x:position,y:bottom+22,'text-anchor':'middle',class:'chart-label'},dateLabel(date,first===last||new Date(first).getFullYear()!==new Date(last).getFullYear())));}
    chart.append(svg('text',{x:(left+right)/2,y:bottom+49,'text-anchor':'middle',class:'chart-label'},'Printed report date'));
    // Bounds follow each PDF's own reference values, with gaps wherever a bound was absent.
    let band=[];
    const flushBand=()=>{if(!band.length)return;if(band.length===1){const p=band[0];chart.append(svg('rect',{x:x(p)-6,y:y(p.upper),width:12,height:Math.max(1,y(p.lower)-y(p.upper)),class:'limit-band'}));}else{const vertices=[...band.map(p=>`${x(p)},${y(p.upper)}`),...band.slice().reverse().map(p=>`${x(p)},${y(p.lower)}`)].join(' ');chart.append(svg('polygon',{points:vertices,class:'limit-band'}));}band=[];};
    for(const point of points){if(point.lower!==null&&point.upper!==null)band.push(point);else flushBand();}flushBand();
    for(const [bound,label] of [['lower','Lower printed'],['upper','Upper printed']]) {
      let segment=[];
      const flush=()=>{if(!segment.length)return;const vertices=segment.map(point=>`${x(point)},${y(point[bound])}`).join(' ');if(segment.length===1)chart.append(svg('line',{x1:x(segment[0])-7,y1:y(segment[0][bound]),x2:x(segment[0])+7,y2:y(segment[0][bound]),class:'limit-line'}));else chart.append(svg('polyline',{points:vertices,class:'limit-line'}));segment=[];};
      for(const point of points){if(point[bound]!==null)segment.push(point);else flush();}flush();
      const recent=points.slice().reverse().find(point=>point[bound]!==null);
      if(recent){const other=bound==='lower'?recent.upper:recent.lower,offset=other===recent[bound]?(bound==='lower'?15:-6):4;chart.append(svg('text',{x:right+12,y:y(recent[bound])+offset,class:'chart-label'},`${label}: ${format(recent[bound])} ${metricUnit()}`));}
    }
    if(points.length>1)chart.append(svg('polyline',{points:points.map(point=>`${x(point)},${y(point.value)}`).join(' '),class:'data-line'}));
    const tooltip=html('p','small','Focus or point to a reading to see its printed value and source PDF.');tooltip.id='trend-tooltip';tooltip.style.minHeight='3.5em';tooltip.style.color='var(--ink)';tooltip.style.lineHeight='1.8';tooltip.setAttribute('aria-live','polite');tooltip.setAttribute('aria-atomic','true');
    for(const point of points) {
      const px=x(point),py=y(point.value),description=pointLabel(point,series),link=svg('a',{href:'#review',tabindex:'0',role:'link','aria-label':description});
      link.append(svg('title',{},description));
      const shape=point.outsidePrintedRange?svg('path',{class:'data-point',d:`M ${px} ${py-6} L ${px+6} ${py} L ${px} ${py+6} L ${px-6} ${py} Z`}):svg('circle',{class:'data-point',cx:px,cy:py,r:4.5});
      if(point.outsidePrintedRange){shape.style.fill='var(--amber)';shape.style.stroke='var(--white)';}
      link.append(shape);
      // A transparent target makes small points usable without obscuring their printed values.
      link.append(svg('circle',{cx:px,cy:py,r:10,fill:'transparent',stroke:'none'}));
      const show=()=>{tooltip.textContent=description;};link.addEventListener('focus',show);link.addEventListener('pointerenter',show);link.addEventListener('click',event=>openSource(event,point));link.addEventListener('keydown',event=>{if(event.key===' '){event.preventDefault();if(typeof state.openRecord==='function')state.openRecord(point.recordId,point.page);}});chart.append(link);
    }
    const legend=html('div','small');legend.id='trend-legend';legend.setAttribute('aria-label','Chart legend');legend.style.display='flex';legend.style.flexWrap='wrap';legend.style.gap='8px 22px';legend.style.marginBottom='8px';legend.style.color='var(--ink)';
    const legendItem=(kind,label,color)=>{
      const item=html('span',''),marker=svg('svg',{width:24,height:12,viewBox:'0 0 24 12','aria-hidden':'true',focusable:'false'});
      item.style.display='inline-flex';item.style.alignItems='center';item.style.gap='6px';marker.style.width='24px';marker.style.height='12px';marker.style.minHeight='0';marker.style.color=`var(${color})`;
      if(kind==='outside')marker.append(svg('path',{d:'M12 1 17 6 12 11 7 6Z',fill:'currentColor',stroke:'none'}));
      else{
        marker.append(svg('line',{x1:1,y1:6,x2:23,y2:6,stroke:'currentColor','stroke-width':kind==='limits'?1.5:2,...(kind==='limits'?{'stroke-dasharray':'4 3'}:{})}));
        if(kind==='value')marker.append(svg('circle',{cx:12,cy:6,r:3.5,fill:'currentColor',stroke:'var(--white)','stroke-width':1.5}));
      }
      item.append(marker,document.createTextNode(label));legend.append(item);
    };
    legendItem('value','Printed value','--teal');
    if(points.some(point=>point.lower!==null||point.upper!==null))legendItem('limits','Printed reference limits','--amber');
    if(points.some(point=>point.outsidePrintedRange))legendItem('outside','Outside printed range','--amber');
    container.append(legend,chart,tooltip);
  }
  function render() {
    if(!visible())return;
    const data=state.data,allPoints=data?.points||[],points=allPoints.slice(-MAX_POINTS),series=currentSeries();
    const seriesOptions=(data?.series||[]).map(item=>({value:item.key,label:contextLabel(item)}));
    if(state.series&&!seriesOptions.some(item=>item.value===state.series))seriesOptions.unshift({value:state.series,label:`${state.seriesLabel||'Selected context'} · ${state.loading?'loading…':'no readings in this period'}`});
    else if(!state.series&&seriesOptions.length)seriesOptions.unshift({value:'',label:'Choose a series'});
    options($('trend-series'),seriesOptions,state.series,state.loading?'Loading series…':'No measured series');
    setText('trend-chart-title',`${metricLabel()} · printed values & reference limits`);
    const latest=allPoints[allPoints.length-1],first=allPoints[0];
    setText('trend-latest',latest?`${format(latest.value)} ${metricUnit()}`:'—');
    setText('trend-latest-detail',latest?`${dateLabel(latest.date)}${latest.outsidePrintedRange?' · Outside printed range':''}`:'No dated printed value in this period');
    const summary=data?.summary||{},fullSummary=summary.scope==='selectedPeriod'&&number(summary.first)!==null&&number(summary.latest)!==null&&!data.omitted;
    const complete=Boolean(first&&latest&&!data?.dataLimitReached&&(!data?.pointLimitReached||fullSummary));
    const change=complete?(fullSummary?summary.latest-summary.first:latest.value-first.value):null;
    setText('trend-change',change===null?'—':`${change>0?'+':''}${format(change)} ${metricUnit()}`);
    setText('trend-change-detail',!complete&&(data?.pointLimitReached||data?.dataLimitReached)?'Narrow the period to compare its first and latest readings.':first&&latest?`${dateLabel(fullSummary?summary.firstDate:first.date)} to ${dateLabel(fullSummary?summary.latestDate:latest.date)} · latest minus first`:'Latest minus first value in the selected period');
    setText('trend-count',points.length.toLocaleString());
    renderCoverage();renderChart(points,series);renderTable(points,series);updateReadButton();
    const notes=['Printed limits describe the source PDF. Change is latest minus first in the selected period; it does not create clinical approval.'];
    if(state.loading)notes.push('Updating saved measurements…');
    if(state.error)notes.push(`Could not refresh: ${state.error}`);
    if(state.notice)notes.push(state.notice);
    if(data?.contextMissing)notes.push('Readings were withheld because their measurement series could not be verified.');
    if(data?.omitted)notes.push(`${count(data.omitted)} invalid or out-of-period readings were omitted.`);
    if(data?.invalidBounds)notes.push(`${count(data.invalidBounds)} inconsistent printed ranges were omitted; their values remain visible.`);
    if(allPoints.length>MAX_POINTS||data?.pointLimitReached)notes.push(`Showing the latest ${points.length.toLocaleString()} of ${count(Math.max(data.totalPointCount,allPoints.length))} matching readings. Choose a shorter period to see more detail.`);
    if(data?.message&&allPoints.length)notes.push(data.message);
    if(data)notes.push(...data.notes);
    setText('trend-status',[...new Set(notes)].join(' '));
  }
  async function load() {
    if(!state.ready||!visible())return;
    const requestKey=query();
    if(state.loading&&state.requestKey===requestKey)return;
    if(state.controller)state.controller.abort();
    const controller=new AbortController(),generation=++state.generation,revision=state.sourceRevision,requestedSeries=state.series;
    let queryChanged=false;
    state.controller=controller;state.requestKey=requestKey;state.loading=true;state.dirty=false;state.error='';render();
    try {
      const raw=await state.api(`/api/trends?${requestKey}`,{signal:controller.signal});
      if(generation!==state.generation||controller.signal.aborted)return;
      if(requestKey!==query()){state.dirty=true;queryChanged=true;return;}
      const scanners=normalizeScanners(raw?.scanners),previousScanner=state.scanner;
      if(scanners.length)updateScanners(scanners);
      const backendScanner=text(raw?.selection?.scanner);
      if(!previousScanner&&backendScanner&&state.scanners.some(item=>item.id===backendScanner))state.scanner=backendScanner;
      if(previousScanner!==state.scanner){state.loading=false;state.dirty=true;state.controller=null;if(visible())load();return;}
      const data=normalizeData(raw||{});
      if(requestedSeries&&data.selectedSeries&&requestedSeries!==data.selectedSeries){data.points=[];data.contextMissing=true;data.selectedSeries='';}
      state.data=data;state.series=data.selectedSeries||requestedSeries;
      if(data.selectedSeries)state.seriesLabel=contextLabel(data.series.find(item=>item.key===data.selectedSeries));
      // A default series becomes part of the current key, avoiding an unnecessary second fetch.
      state.dataKey=query();state.dataRevision=revision;state.dirty=revision!==state.sourceRevision;state.notice='';
    } catch(error) {
      if(generation!==state.generation||error?.name==='AbortError')return;
      state.error=error instanceof Error?error.message:'The saved measurements could not be loaded.';state.dirty=true;
    } finally {
      if(generation===state.generation){state.loading=false;state.controller=null;render();if((queryChanged||revision!==state.sourceRevision)&&visible())load();}
    }
  }
  function changed(kind) {
    if(state.controller)state.controller.abort();state.generation++;state.loading=false;state.controller=null;
    state.scanner=$('trend-scanner')?.value||'';
    state.metric=Object.prototype.hasOwnProperty.call(METRICS,$('trend-metric')?.value)?$('trend-metric').value:'WaterCTNumber';
    state.period=PERIODS.has($('trend-period')?.value)?$('trend-period').value:'90';
    state.series=kind==='scanner'||kind==='metric'?'':$('trend-series')?.value||'';
    if(kind==='scanner'||kind==='metric')state.seriesLabel='';
    else if(kind==='series')state.seriesLabel=$('trend-series')?.selectedOptions[0]?.textContent||'';
    state.data=null;state.dataKey='';state.dirty=true;state.error='';state.notice='';load();
  }
  async function readMeasurements() {
    if(state.loading||state.reading||state.isBusy()||state.isBackgroundReading())return;
    const ids=pendingIds().slice(0,20);if(!ids.length||typeof state.readPending!=='function')return;
    state.reading=true;state.notice=`Reading printed measurements from ${count(ids.length)} saved PDF${ids.length===1?'':'s'}.`;render();
    try{await state.readPending(ids);state.dirty=true;}
    catch(error){state.notice=error instanceof Error?error.message:'These saved PDFs could not be read. Try again.';}
    finally{state.reading=false;render();}
  }
  function init({api,openRecord,readPending,isBusy,isBackgroundReading}={}) {
    if(state.ready)return;
    if(typeof api!=='function')throw new TypeError('QaTrends requires the authenticated local API helper.');
    state.api=api;state.openRecord=openRecord;state.readPending=readPending;state.isBusy=typeof isBusy==='function'?isBusy:()=>false;
    state.isBackgroundReading=typeof isBackgroundReading==='function'?isBackgroundReading:()=>false;
    options($('trend-metric'),Object.entries(METRICS).map(([value,definition])=>({value,label:definition.label})),state.metric,'No supported measurements');
    state.period=PERIODS.has($('trend-period')?.value)?$('trend-period').value:'90';
    for(const kind of ['scanner','metric','series','period'])$('trend-'+kind)?.addEventListener('change',()=>changed(kind));
    $('trend-read-pending')?.addEventListener('click',readMeasurements);
    $('trend-status')?.setAttribute('role','status');$('trend-status')?.setAttribute('aria-live','polite');
    state.ready=true;updateReadButton();
  }
  function refresh(snapshot) {
    if(!state.ready)return;
    const revision=snapshotRevision(snapshot),changedRevision=revision!==state.sourceRevision;
    state.snapshot=snapshot;
    if(changedRevision){
      const previousScanner=state.scanner;
      state.sourceRevision=revision;state.dirty=true;state.scanners=normalizeScanners(field(snapshot,'scanners'));updateScanners(state.scanners);
      if(previousScanner!==state.scanner){if(state.controller)state.controller.abort();state.generation++;state.loading=false;state.controller=null;}
    }
    updateReadButton();
    if((changedRevision||(state.dataKey&&state.dataKey!==query()))&&visible())load();
  }
  function show() {
    if(!state.ready||!visible())return;
    render();if(state.dirty||state.dataKey!==query())load();
  }
  window.QaTrends={init,show,refresh};
})();
