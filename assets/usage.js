/* Usage per container. Anthropic shows official numbers on claude.ai's Usage page (read for any account that has
   it, like the Opus manager). Free accounts get an estimate: tokens per 5-hour window, learned from real limits. */
(function(root){
'use strict';
const HOUR=3600e3,WINDOW=5*HOUR,WEEK=7*24*HOUR;
/** About 3.6 characters per token for mixed English and code. */
const tokensOf=chars=>Math.ceil(Math.max(0,chars||0)/3.6);
/** Until real limits have been seen, a free 5-hour session is assumed to hold about this many tokens. */
const PRIOR_SESSION=150000;
const CALIBRATION=12;
const CONTEXT={manager:1000000,worker:200000};

function blank(){return {win:null,chat:0,hist:[],samples:[],official:null};}
function windowAt(rec,now){
  if(!rec.win||now-rec.win.start>=WINDOW)rec.win={start:now,tokens:0,msgs:0,limited:false};
  return rec.win;
}
/** One message. A follow-up makes Claude re-read the whole chat, so its cost includes what the chat already holds. */
function record(rec,{inChars=0,outChars=0,fresh=true,now=Date.now()}){
  const win=windowAt(rec,now),inT=tokensOf(inChars),outT=tokensOf(outChars);
  const before=fresh?0:rec.chat,cost=before+inT+outT;
  rec.chat=before+inT+outT;
  win.tokens+=cost;win.msgs++;
  rec.hist.push({t:now,tokens:cost,in:inT,out:outT});
  rec.hist=rec.hist.filter(h=>now-h.t<WEEK).slice(-500);
  return cost;
}
/** The account hit its limit: the tokens used in this window are one measurement of how big a session is. */
function recordLimit(rec,now=Date.now()){
  const win=rec.win&&now-rec.win.start<WINDOW?rec.win:null;
  if(!win||win.limited)return null;
  win.limited=true;
  if(win.tokens<2000)return null; // too little to be a real measurement (a limit from a chat outside the app)
  return win.tokens;
}
function median(list){const a=[...list].sort((x,y)=>x-y),m=a.length>>1;return a.length%2?a[m]:Math.round((a[m-1]+a[m])/2);}
/** Session size: the median of measured limits (the last 12), or the starting guess. */
function capacity(samples){return samples&&samples.length?median(samples.slice(-CALIBRATION)):PRIOR_SESSION;}
function estimate(rec,{samples=[],role='worker',now=Date.now()}={}){
  const win=rec.win&&now-rec.win.start<WINDOW?rec.win:null;
  const cap=capacity(samples),used=win?win.tokens:0;
  const resetAt=win?win.start+WINDOW:null;
  const perMsg=win&&win.msgs?used/win.msgs:null;
  // At the pace of this window so far, when would the account run out?
  const rate=win&&now-win.start>60e3?used/(now-win.start):0;
  const emptyAt=rate>0?now+Math.max(0,cap-used)/rate:null;
  const limit=CONTEXT[role]||CONTEXT.worker;
  return {
    cap,used,pct:Math.min(100,Math.round(used/cap*100)),resetAt,
    messagesLeft:perMsg?Math.max(0,Math.floor((cap-used)/perMsg)):null,
    runsOutAt:emptyAt&&resetAt&&emptyAt<resetAt?emptyAt:null,
    calibration:Math.min(CALIBRATION,samples.length),calibrated:samples.length>=CALIBRATION,
    week:rec.hist.filter(h=>now-h.t<WEEK).reduce((n,h)=>n+h.tokens,0),
    context:{used:rec.chat,limit,pct:Math.min(100,Math.round(rec.chat/limit*100))}
  };
}
/** Expected cost of a message before it is sent: its size, the usual reply size for its length, and the chat it joins. */
function predict(inChars,hist=[],{chat=0}={}){
  const ins=hist.reduce((n,h)=>n+(h.in||0),0),outs=hist.reduce((n,h)=>n+(h.out||0),0);
  const ratio=ins>5000?Math.min(3,outs/ins):0.35;
  const inT=tokensOf(inChars);
  return chat+inT+Math.round(inT*ratio);
}
/** claude.ai's own Usage page as text, e.g. "Current session 52% used Resets in 3 hr 39 min … All models 7% used Resets Mon 3:59 AM". */
function parseOfficial(text,now=Date.now()){
  const t=String(text||'');
  const STOPS=/(?:Current session|Weekly limits|All models|Opus only|Sonnet only|Extra usage|Context window)/gi;
  const section=label=>{
    const i=t.search(label);if(i<0)return null;
    const from=i+(t.slice(i).match(label)?.[0].length||0);
    STOPS.lastIndex=from;const next=STOPS.exec(t);
    const seg=t.slice(from,next?next.index:t.length);
    const pct=seg.match(/(\d{1,3})\s*%\s*used/i);if(!pct)return null;
    const reset=seg.match(/Resets?\s+([^\n]+)/i);
    return {pct:Math.min(100,+pct[1]),reset:reset?reset[1].trim().slice(0,40):'',resetAt:reset?resetTime(reset[1],now):null};
  };
  const session=section(/Current session/i),weekly=section(/All models/i);
  return session||weekly?{session,weekly,at:now}:null;
}
/** claude.ai's usage endpoint: {"five_hour":{"utilization":37,"resets_at":"…Z"},"seven_day":{…}}. Exact numbers and times. */
function parseApi(json,now=Date.now()){
  let u;try{u=typeof json==='string'?JSON.parse(json):json;}catch{return null;}
  if(!u||typeof u!=='object')return null;
  const win=w=>{
    if(!w||typeof w!=='object'||!Number.isFinite(+w.utilization))return null;
    const at=w.resets_at?Date.parse(w.resets_at):NaN;
    return {pct:Math.max(0,Math.min(100,Math.round(+w.utilization))),reset:'',resetAt:Number.isFinite(at)?at:null};
  };
  const session=win(u.five_hour),weekly=win(u.seven_day);
  return session||weekly?{session,weekly,at:now,exact:true}:null;
}
/** A window as claude.ai reads at this moment: once its reset time has passed it is back to 0%. */
function current(w,now=Date.now()){
  if(!w)return null;
  if(w.resetAt&&w.resetAt<=now)return {...w,pct:0,reset:'',resetAt:null,wasReset:true};
  return w;
}
/** "Resets in 4 hr 28 min (2:50 PM)", from the exact time when there is one. */
function resetWords(w,now=Date.now()){
  if(!w)return '';
  if(w.wasReset)return 'Reset since the last check';
  if(w.resetAt){
    const d=new Date(w.resetAt),clock=d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
    const day=w.resetAt-now>20*HOUR?d.toLocaleDateString([],{weekday:'short'})+' ':'';
    return 'Resets in '+fmtIn(w.resetAt-now)+' ('+day+clock+')';
  }
  return w.reset?'Resets '+w.reset:'';
}
/** "in 3 hr 39 min" → a time; a weekday and clock time is left as words. */
function resetTime(words,now){
  const m=String(words).match(/in\s+(?:(\d+)\s*(?:hr|hour)s?)?\s*(?:(\d+)\s*min)?/i);
  if(!m||(!m[1]&&!m[2]))return null;
  return now+((+m[1]||0)*60+(+m[2]||0))*60e3;
}
function fmtTokens(n){return n>=1e6?(n/1e6).toFixed(1).replace(/\.0$/,'')+'M':n>=1000?Math.round(n/1000)+'k':String(Math.round(n));}
function fmtIn(ms){if(ms<=0)return 'now';const m=Math.round(ms/60e3);return m<60?m+' min':Math.floor(m/60)+' hr '+(m%60)+' min';}
const api={tokensOf,record,recordLimit,capacity,estimate,predict,parseOfficial,parseApi,current,resetWords,fmtTokens,fmtIn,blank,PRIOR_SESSION,CALIBRATION,WINDOW,CONTEXT};
root.StudioUsage=api;
if(typeof module!=='undefined')module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
