/* Cursor call: you talk on the phone, Claude looks at your PC screen and a ghost cursor on the PC shows where to go.
   One step = your words + a fresh screenshot sent to a free sub-agent, which answers what to say and where to point. */
(function(root){
'use strict';
const NEXT=['wait_for_click','listen','done'];
const APPS='Revit, AutoCAD, ETABS, Robot Structural Analysis, Excel, Word, Windows, the browser and the command prompt';

/** The message for one step. Each step goes to a new chat, so it carries the last few exchanges itself. */
function callPrompt({words,recap=[],shot,memory=''}){
  const w=shot?.w||1280,h=shot?.h||720;
  return [
    '[AI Studio · Cursor call]',
    'You are guiding me on my Windows PC, live, like a phone call. I talk, you answer out loud, and a ghost cursor on my screen points where you say.',
    'The attached image is my screen right now, '+w+' x '+h+' pixels. I often use '+APPS+'.',
    '',
    'Answer with ONLY this JSON, nothing before or after:',
    '{"say":"one or two short spoken sentences","point":{"x":0,"y":0,"label":"2-4 words"},"next":"wait_for_click"}',
    '',
    'Rules:',
    '- "say" is read aloud: plain words, no markdown, no lists, no emojis, under 35 words. One step at a time.',
    '- "point" is where I should click next, in pixels of the attached image (x from the left, y from the top), at the centre of the button, tab, menu item or field. Use null when there is nothing to click.',
    '- Only point at something you can actually see in the image. If you cannot find it, set point to null and say what to do so it shows (scroll, open the window, maximize it).',
    '- "next": "wait_for_click" when I should click the point, "listen" when you asked me something or I must type or decide, "done" when the task is finished.',
    '- Never tell me to run a command, delete, send, buy or install something without saying exactly what it does first.',
    memory?'\nWhat you know about me:\n'+memory:'',
    recap.length?'\nThe call so far (oldest first):\n'+recap.join('\n'):'',
    '',
    'ME NOW: '+(words||'(I did what you said. What next?)')
  ].filter(l=>l!=null).join('\n').replace(/\n{3,}/g,'\n\n');
}

/** Reads Claude's step. Points are clamped to the screenshot; anything malformed becomes a plain spoken answer. */
function parseStep(text,shot){
  const raw=String(text||'');
  const w=shot?.w||1280,h=shot?.h||720;
  let obj=null;
  const fenced=raw.match(/```(?:json)?\s*([\s\S]*?)```/);
  for(const cand of [fenced?.[1],raw.slice(raw.indexOf('{'),raw.lastIndexOf('}')+1)]){
    if(!cand)continue;
    try{obj=JSON.parse(cand.replace(/,\s*([}\]])/g,'$1'));break;}catch{}
  }
  if(!obj||typeof obj!=='object'){
    const say=raw.replace(/```[\s\S]*?```/g,'').replace(/[*_#`>]/g,'').replace(/\s+/g,' ').trim();
    return {say:say||'Sorry, I did not get that. Can you say it again?',point:null,next:'listen'};
  }
  let say=String(obj.say||'').replace(/[*_#`]/g,'').replace(/\s+/g,' ').trim();
  if(!say)say=obj.next==='done'?'Done.':'Look where the cursor points.';
  let point=null;
  const p=obj.point;
  if(p&&typeof p==='object'&&Number.isFinite(+p.x)&&Number.isFinite(+p.y)){
    const x=Math.round(+p.x),y=Math.round(+p.y);
    if(x>=0&&y>=0&&x<=w&&y<=h)point={x:Math.min(x,w-1),y:Math.min(y,h-1),label:String(p.label||'').replace(/\s+/g,' ').trim().slice(0,40)};
  }
  let next=NEXT.includes(obj.next)?obj.next:(point?'wait_for_click':'listen');
  if(next==='wait_for_click'&&!point)next='listen';
  return {say,point,next};
}

/** The last exchanges, one short line each, for the next step's message. */
function recapLines(history,n=6){
  return history.slice(-n).map(e=>(e.who==='me'?'ME: ':'YOU: ')+String(e.text||'').replace(/\s+/g,' ').trim().slice(0,240)+(e.point?' [pointed at '+(e.point.label||e.point.x+','+e.point.y)+']':''));
}

/** Pairing details typed on the phone: a private-network address and the 6-digit code shown on the PC. */
function parsePair(address,code){
  const m=String(address||'').trim().match(/^(?:ws:\/\/)?([A-Za-z0-9.-]+)(?::(\d{2,5}))?\/?$/);
  if(!m)return {error:'Type the address shown on your PC, like 192.168.1.20.'};
  const host=m[1],port=m[2]?+m[2]:8765;
  const ip=host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  const local=ip?(+ip[1]===10||(+ip[1]===192&&+ip[2]===168)||(+ip[1]===172&&+ip[2]>=16&&+ip[2]<=31)||(+ip[1]===169&&+ip[2]===254))
    :/^[A-Za-z0-9-]+(\.local)?$/.test(host);
  if(!local)return {error:'Only PCs on your own Wi-Fi can be paired (an address like 192.168.x.x).'};
  if(port<1024||port>65535)return {error:'The port must be between 1024 and 65535.'};
  const c=String(code||'').replace(/\D/g,'');
  if(c.length!==6)return {error:'Type the 6-digit code shown on your PC.'};
  return {host,port,code:c};
}

const api={callPrompt,parseStep,recapLines,parsePair,NEXT};
root.StudioCursor=api;
if(typeof module!=='undefined')module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
