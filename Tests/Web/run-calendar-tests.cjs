'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,'../../App/Web/app.js'),'utf8');
const start = source.indexOf('/* CTQA_CALENDAR_START */'), end = source.indexOf('/* CTQA_CALENDAR_END */');
assert.ok(start >= 0 && end > start, 'The delivered app bundle contains its calendar rules.');
const calendarSource = source.slice(start + '/* CTQA_CALENDAR_START */'.length, end);
const calendarModule = { exports: {} };
vm.runInThisContext('(function(module,exports){' + calendarSource + '\n})', {filename:'calendar-rules-from-app-bundle.js'})(calendarModule, calendarModule.exports);
const { build } = calendarModule.exports;
const checks = [];
const id = n => n.toString(16).padStart(64, '0');
function check(name, run) { run(); checks.push(name); }
function fixture(date = '2024-03-04') {
  return { today: { date }, scanners: [
    { id: 'A', name: 'Synthetic scanner A', dailySchedule: 'AllDays', activeFrom: '2024-03-01', excludedDates: ['2024-03-02'], status: 'Connected' },
    { id: 'B', name: 'Synthetic scanner B', dailySchedule: 'Weekdays', activeFrom: '2024-03-01', excludedDates: [], status: 'Offline' },
    { id: 'C', name: 'Synthetic scanner C', dailySchedule: 'Off', excludedDates: [], status: 'Unknown' }
  ], records: [] };
}
const daily = (n, scanner, date, extra = {}) => ({ id: id(n), scanner, date, category: 'Daily', pending: false, isReference: false, hasReferenceEvidence: false, ...extra });
check('Month boundaries, leap years and weekday identity remain timezone independent', () => {
  for (const [month, count, weekday] of [['2024-02',29,4],['2023-02',28,3],['1900-02',28,4],['2000-02',29,2],['2026-11',30,0],['2026-12',31,2]]) {
    const calendar = build(fixture('2026-12-31'), month, 'A');
    assert.equal(calendar.days.length, count); assert.equal(calendar.days[0].weekday, weekday);
    assert.equal(calendar.days.at(-1).date, `${month}-${count}`);
  }
});
check('Schedules, exclusions and active dates count expected archive receipts only', () => {
  const data = fixture(); data.scanners[0].activeFrom = '2024-03-02';
  const result = build(data, '2024-03');
  assert.deepEqual(result.days.slice(0,4).map(day => day.expected), [1,0,1,2]);
  assert.equal(result.summary.expected, 4); assert.equal(result.summary.notReceived, 4);
  assert.equal(result.days[1].status, 'NotScheduled');
});
check('Pending, reference, suspected reference and Monthly files cannot supply Daily receipt', () => {
  const data = fixture();
  data.records = [daily(1,'A','2024-03-04',{pending:true}), daily(2,'A','2024-03-04',{isReference:true}), daily(3,'A','2024-03-04',{hasReferenceEvidence:true}), daily(4,'A','2024-03-04',{category:'Monthly'}), daily(5,'B','2024-03-04')];
  const result = build(data, '2024-03'); const day = result.days[3];
  assert.equal(day.status, 'Partial'); assert.equal(day.expected,2); assert.equal(day.received,1); assert.deepEqual(day.reportIds,[id(5)]);
  assert.equal(day.scanners[1].received,true); assert.equal(result.scanners[1].status,'Offline');
});
check('Future dates stay neutral and do not increase receipt or missing counts', () => {
  const data = fixture(); data.records = [daily(1,'A','2024-03-05')];
  const result = build(data, '2024-03'); const day = result.days[4];
  assert.equal(day.future,true); assert.equal(day.status,'Future'); assert.equal(day.expected,0); assert.equal(day.received,0); assert.equal(day.totalReceived,0);
  assert.equal(day.scanners[0].received,false); assert.deepEqual(day.reportIds,[id(1)]);
  assert.equal(result.summary.expected,5); assert.equal(result.summary.received,0);
});
check('Off-schedule saved reports stay visible without creating an expected test', () => {
  const data = fixture(); data.records = [daily(1,'C','2024-03-02')];
  const result = build(data,'2024-03','C'); const day = result.days[1];
  assert.equal(day.required,false); assert.equal(day.status,'Received'); assert.equal(day.expected,0); assert.equal(day.totalReceived,1); assert.equal(result.summary.expected,0);
});
check('Calendar selection isolates scanners and rejects unknown or invalid dates', () => {
  const data = fixture(); data.records = [daily(1,'A','2024-03-04'), daily(2,'B','2024-03-04'), daily(3,'A','2024-02-31'), daily(4,'Unknown','2024-03-04')];
  const result = build(data,'2024-03','A'); assert.equal(result.scanners.length,1); assert.equal(result.days[3].received,1); assert.deepEqual(result.days[3].reportIds,[id(1)]);
  assert.throws(() => build(data,'2024-13'), /valid calendar/); assert.throws(() => build(data,'2024-2'), /valid calendar/); assert.throws(() => build(data,'2024-03','Unknown'), /configured scanner/);
  assert.throws(() => build({ ...data, today: { date: '2024-02-31' } },'2024-03'), /Refresh/);
});
check('Duplicate records do not multiply report links and the snapshot stays unchanged', () => {
  const data = fixture(); const record = daily(31,'A','2024-03-04'); data.records = [record, {...record,id:record.id.toUpperCase()}];
  const before = JSON.stringify(data); const result = build(data,'2024-03','A');
  assert.deepEqual(result.days[3].reportIds,[id(31)]); assert.equal(result.days[3].scanners[0].count,1);
  result.days[3].reportIds.length=0; assert.equal(JSON.stringify(data),before);
});
check('Same-day Monthly PDFs are linked without inventing Daily receipt', () => {
  const data = fixture();
  data.records = [daily(50,'A','2024-03-04',{category:'Monthly'}),daily(51,'A','2024-03-04',{category:'Monthly'}),daily(52,'B','2024-03-04')];
  const before=JSON.stringify(data), result=build(data,'2024-03'), day=result.days[3];
  assert.deepEqual(day.monthlyReportIds,[id(50),id(51)]);
  assert.deepEqual(day.scanners[0].monthlyReportIds,[id(50),id(51)]);
  assert.equal(day.scanners[0].received,false); assert.equal(day.received,1);
  assert.equal(day.monthlyAvailable,1); assert.equal(result.summary.monthlyAvailable,1);
  assert.deepEqual(day.reportIds,[id(52)]); assert.equal(JSON.stringify(data),before);
  const selected=build(data,'2024-03','B'); assert.deepEqual(selected.days[3].monthlyReportIds,[]);
  data.records.push(daily(53,'A','2024-03-04'));
  assert.equal(build(data,'2024-03','A').summary.monthlyAvailable,0);
});
check('Monthly links exclude pending, reference, duplicate, other-day and other-scanner PDFs', () => {
  const data=fixture(); const monthly=(n,extra={})=>daily(n,'A','2024-03-04',{category:'Monthly',...extra});
  data.records=[monthly(60),monthly(60),monthly(61,{pending:true}),monthly(62,{isReference:true}),monthly(63,{hasReferenceEvidence:true}),monthly(64,{category:'Other'}),monthly(65,{date:'2024-03-03'}),monthly(66,{scanner:'Unknown'})];
  const result=build(data,'2024-03','A'); assert.deepEqual(result.days[3].monthlyReportIds,[id(60)]);
  assert.deepEqual(result.days[2].monthlyReportIds,[id(65)]); assert.equal(result.days[3].received,0);
  data.records=[monthly(67,{date:'2024-03-05'})];
  const future=build(data,'2024-03','A'); assert.equal(future.days[4].status,'Future'); assert.equal(future.summary.monthlyAvailable,0);
});
const result = { passed: true, checkCount: checks.length, checks, syntheticOnly: true, scope: 'Pure cached metadata calendar rules. Does not read PDFs, contact scanners or establish clinical test completion.', timezone: process.env.TZ || 'process default' };
const outputIndex = process.argv.indexOf('--output');
if (outputIndex >= 0) { const output=path.resolve(process.argv[outputIndex+1]); fs.mkdirSync(path.dirname(output),{recursive:true}); fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n'); }
console.log(JSON.stringify(result,null,2));
