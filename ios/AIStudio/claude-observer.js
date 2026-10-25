/* Visible Claude page observation, plus typing shared memory into the message box (never sending it). No cookies, tokens, password fields or private APIs. */
(function(){
  'use strict';
  if(location.protocol!=='https:'||location.hostname!=='claude.ai')return;
  const bridge=window.webkit?.messageHandlers?.claudeObserver;
  if(!bridge)return;
  const visible=el=>!!(el.getClientRects().length)&&getComputedStyle(el).visibility!=='hidden';
  const isLimit=text=>
    /(?:you(?:'|’)?ve reached (?:your|the) (?:message |usage )?limit|(?:message|usage|rate) limit (?:reached|exceeded)|out of (?:free )?messages|(?:hit|reached) your (?:free )?(?:plan )?limit)/i.test(text)||
    /(?:limit|messages|usage)[\s\S]{0,100}(?:try again|resets? (?:at|in)|come back)/i.test(text);
  function resetDelay(text){
    const match=text.match(/(?:try again|resets?|come back) in\s+(?:(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\s*)?(?:(\d+)\s*(?:minutes?|mins?))?/i);
    if(!match||(!match[1]&&!match[2]))return null;
    const seconds=(Number(match[1]||0)*3600)+(Number(match[2]||0)*60);
    return seconds>0&&seconds<=86400?seconds:null;
  }
  function messages(){
    const items=[];
    // Keep document order. These selectors are best-effort public DOM markers, not an API.
    for(const el of document.querySelectorAll('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]')){
      if(el.parentElement?.closest('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]'))continue;
      const text=el.innerText?.trim();if(!text)continue;
      items.push({role:el.getAttribute('data-testid')==='user-message'?'user':'assistant',content:text});
    }
    return items;
  }
  function snapshot(){
    return {url:location.href,messages:messages(),partial:true,version:1};
  }
  // This function is invoked in the isolated content world by the native Export button.
  globalThis.claudeVisibleSnapshot=snapshot;
  let scheduled=false,lastLimit='',signedIn=false;
  function check(){
    scheduled=false;
    // Restrict detection to notices, not arbitrary conversation text containing "limit".
    const notices=Array.from(document.querySelectorAll('[role="alert"],[role="status"],[data-testid*="usage-limit"],[data-testid*="rate-limit"]'));
    const notice=notices.find(el=>visible(el)&&!el.closest('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]')&&isLimit(el.innerText||''));
    const text=(notice?.innerText||'').trim().slice(0,2000);
    if(!text){lastLimit='';}
    else if(text!==lastLimit){
      lastLimit=text;
      bridge.postMessage({event:'limit',notice:text,retryAfterSeconds:resetDelay(text),snapshot:snapshot()});
    }
    if(!signedIn&&document.querySelector('[contenteditable="true"][role="textbox"],textarea[placeholder*="Claude"]')){
      signedIn=true;bridge.postMessage({event:'signedIn'});
    }
  }
  // Shared memory helpers. They only type into the message box (the user presses send) and read the last visible reply.
  globalThis.claudeInsertText=text=>{
    const box=document.querySelector('[contenteditable="true"][role="textbox"]');
    if(box){
      box.focus();
      const sel=window.getSelection&&window.getSelection();
      if(sel){const r=document.createRange();r.selectNodeContents(box);r.collapse(false);sel.removeAllRanges();sel.addRange(r);}
      return !!document.execCommand('insertText',false,String(text));
    }
    const area=document.querySelector('textarea[placeholder*="Claude"]');
    if(!area)return false;
    area.focus();
    const setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
    setter.call(area,(area.value?area.value+'\n':'')+String(text));
    area.dispatchEvent(new Event('input',{bubbles:true}));
    return true;
  };
  globalThis.claudeMemoryProposal=()=>{
    const replies=messages().filter(m=>m.role==='assistant');
    const last=replies[replies.length-1];
    if(!last)return null;
    const found=[...last.content.matchAll(/<<<STUDIO_MEMORY\s*([\s\S]*?)\s*STUDIO_MEMORY>>>/g)];
    const body=found.length?found[found.length-1][1].trim():'';
    return body?body.slice(0,4000):null;
  };
  // Code tab bridge: report progress, press send, press stop. Only called by native code after the person sends from the Code tab.
  globalThis.claudeStatus=()=>{
    const items=messages();
    const assistants=items.filter(m=>m.role==='assistant');
    return {
      users:items.filter(m=>m.role==='user').length,
      assistants:assistants.length,
      streaming:!!(document.querySelector('[data-is-streaming="true"]')||document.querySelector('button[aria-label*="Stop"]')),
      last:assistants.length?assistants[assistants.length-1].content:'',
      loggedOut:/^\/(login|logout)/.test(location.pathname||'')
    };
  };
  globalThis.claudeSubmit=()=>{
    const btn=document.querySelector('button[aria-label="Send message"],button[aria-label="Send Message"],button[aria-label*="Send"]');
    if(!btn||btn.disabled||btn.getAttribute('aria-disabled')==='true')return false;
    btn.click();return true;
  };
  globalThis.claudeStop=()=>{
    const btn=document.querySelector('button[aria-label*="Stop"]');
    if(!btn)return false;
    btn.click();return true;
  };
  globalThis.claudeCheckLimits=()=>{lastLimit='';check();};
  const observer=new MutationObserver(()=>{
    if(scheduled)return;scheduled=true;setTimeout(check,800);
  });
  observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
  check();
})();
