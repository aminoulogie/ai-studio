// The companion's pure logic, kept apart from Electron so it can be tested on any machine.
'use strict';
const crypto=require('node:crypto');

/** A fresh 6-digit pairing code, shown on the PC and typed on the phone. */
function newCode(){return String(crypto.randomInt(0,1e6)).padStart(6,'0');}

/** The screenshot size sent to Claude: at most 1280 wide (and 1280 tall), same shape as the screen. */
function fitSize(width,height,max=1280){
  const k=Math.min(1,max/Math.max(width,height));
  return {w:Math.max(1,Math.round(width*k)),h:Math.max(1,Math.round(height*k))};
}

/** A point in screenshot pixels → a point on the screen (Windows display units). */
function mapPoint(p,shot,bounds){
  const x=Math.max(0,Math.min(shot.w-1,+p.x)),y=Math.max(0,Math.min(shot.h-1,+p.y));
  return {x:Math.round(bounds.x+x*bounds.width/shot.w),y:Math.round(bounds.y+y*bounds.height/shot.h)};
}

/** Pairing: the right code within the time allowed; five wrong codes lock pairing for a minute. */
function makeGate(code,{maxTries=5,lockMs=60e3,now=Date.now}={}){
  let tries=0,lockedUntil=0;
  return {
    check(given){
      if(now()<lockedUntil)return {ok:false,reason:'Too many wrong codes. Wait a minute.'};
      const a=Buffer.from(String(given||'').padEnd(6).slice(0,6)),b=Buffer.from(code);
      if(crypto.timingSafeEqual(a,b)){tries=0;return {ok:true};}
      if(++tries>=maxTries){tries=0;lockedUntil=now()+lockMs;}
      return {ok:false,reason:'Wrong code. Check the code on your PC.'};
    },
    get code(){return code;}
  };
}

/** Validates one message from the phone; returns null when it is not something the companion does. */
function readMessage(text){
  if(typeof text!=='string'||text.length>16000)return null;
  let m;try{m=JSON.parse(text);}catch{return null;}
  if(!m||typeof m!=='object')return null;
  switch(m.t){
    case 'hello':return {t:'hello',code:String(m.code||'')};
    case 'shot':return {t:'shot',id:String(m.id||'').slice(0,40)};
    case 'point':
      if(!Number.isFinite(+m.x)||!Number.isFinite(+m.y)||!Number.isFinite(+m.w)||!Number.isFinite(+m.h)||+m.w<=0||+m.h<=0)return null;
      return {t:'point',x:+m.x,y:+m.y,w:+m.w,h:+m.h,label:String(m.label||'').slice(0,40),say:String(m.say||'').slice(0,300)};
    case 'say':return {t:'say',text:String(m.text||'').slice(0,300)};
    case 'clear':return {t:'clear'};
    case 'ping':return {t:'ping'};
    default:return null;
  }
}

/** True once the real mouse is on the ghost cursor's target (within a small radius). */
function reached(cursor,target,radius=26){
  return !!target&&Math.hypot(cursor.x-target.x,cursor.y-target.y)<=radius;
}

/** The PC's addresses on the local network, for the pairing screen. */
function lanAddresses(ifaces){
  const out=[];
  for(const [name,list] of Object.entries(ifaces||{}))for(const a of list||[]){
    if(a.family!=='IPv4'&&a.family!==4)continue;
    if(a.internal)continue;
    const p=a.address.split('.').map(Number);
    const priv=p[0]===10||(p[0]===192&&p[1]===168)||(p[0]===172&&p[1]>=16&&p[1]<=31);
    if(priv)out.push({name,address:a.address});
  }
  // Wi-Fi and Ethernet first, virtual adapters (WSL, Hyper-V, VPN) last.
  const rank=n=>/vethernet|wsl|hyper|virtual|vbox|vmware|docker|tailscale|zerotier/i.test(n)?2:/wi-?fi|wlan|ethernet|eth|en\d/i.test(n)?0:1;
  return out.sort((a,b)=>rank(a.name)-rank(b.name));
}

module.exports={newCode,fitSize,mapPoint,makeGate,readMessage,reached,lanAddresses};
