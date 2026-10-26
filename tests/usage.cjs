// Usage estimates for free containers and claude.ai's official numbers for the rest.
const assert=require('node:assert/strict');
const U=require('../assets/usage.js');
const t0=Date.UTC(2026,9,26,12),min=60e3;
const rec=U.blank();
// A fresh chat costs its message and reply; a follow-up also re-reads the chat so far.
assert.equal(U.record(rec,{inChars:36000,outChars:3600,fresh:true,now:t0}),11000);
assert.equal(U.record(rec,{inChars:3600,outChars:3600,fresh:false,now:t0+30*min}),13000);
assert.equal(rec.chat,13000);assert.equal(rec.win.tokens,24000);
let e=U.estimate(rec,{samples:[],now:t0+31*min});
assert.equal(e.cap,U.PRIOR_SESSION,'a starting guess until real limits are seen');
assert.equal(e.pct,16);assert.equal(e.resetAt,t0+U.WINDOW);
assert.equal(e.messagesLeft,10);assert.ok(e.runsOutAt>t0&&e.runsOutAt<t0+U.WINDOW,'predicts running out before the reset at this pace');
assert.equal(e.context.limit,200000);assert.equal(U.estimate(rec,{role:'manager'}).context.limit,1000000);
// A new 5-hour window starts clean; the chat context does not.
U.record(rec,{inChars:3600,outChars:0,fresh:true,now:t0+6*60*min});
assert.equal(rec.win.tokens,1000);assert.equal(rec.win.msgs,1);
// Limits teach the session size: the median of the last 12.
const r2=U.blank();U.record(r2,{inChars:3.6*90000,outChars:0,now:t0});
assert.equal(U.recordLimit(r2,t0+min),90000);assert.equal(U.recordLimit(r2,t0+2*min),null,'one measurement per window');
const tiny=U.blank();U.record(tiny,{inChars:360,now:t0});assert.equal(U.recordLimit(tiny,t0),null,'tiny windows are not measurements');
assert.equal(U.capacity([100000,120000,90000]),100000);
const many=Array.from({length:15},(_,i)=>(i+1)*10000);
assert.equal(U.capacity(many),95000,'only the last 12 count');
e=U.estimate(rec,{samples:many.slice(0,12),now:t0+6*60*min});assert.equal(e.calibrated,true);assert.equal(e.calibration,12);
// Prediction before sending: size, the usual reply ratio, and the chat it joins.
assert.equal(U.predict(3600,[]),1350);
assert.equal(U.predict(3600,[{in:10000,out:5000}]),1500);
assert.equal(U.predict(3600,[],{chat:20000}),21350);
// claude.ai's Usage page in its own words.
const page='Plan usage\nCurrent session\n52% used\nResets in 3 hr 39 min\nWeekly limits\nAll models\n7% used\nResets Mon 3:59 AM\nLearn more';
const off=U.parseOfficial(page,t0);
assert.deepEqual(off.session,{pct:52,reset:'in 3 hr 39 min',resetAt:t0+219*min});
assert.equal(off.weekly.pct,7);assert.equal(off.weekly.reset,'Mon 3:59 AM');
assert.equal(U.parseOfficial('Settings\nProfile'),null);
assert.equal(U.fmtTokens(576000),'576k');assert.equal(U.fmtTokens(1000000),'1M');assert.equal(U.fmtIn(219*min),'3 hr 39 min');
console.log('Usage checks passed: per-window tokens, follow-up cost, 12-limit calibration, run-out prediction, claude.ai usage page.');
