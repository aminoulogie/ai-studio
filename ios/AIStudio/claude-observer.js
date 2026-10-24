/* Visible Claude page observation only. No cookies, tokens, password fields or private APIs. */
(function(){
  'use strict';
  if(location.protocol!=='https:'||location.hostname!=='claude.ai')return;
  const bridge=window.webkit?.messageHandlers?.claudeObserver;
  if(!bridge)return;
  const visible=el=>!!(el.getClientRects().length)&&getComputedStyle(el).visibility!=='hidden';
  const isLimit=text=>
    /(?:you(?:'|’)?ve reached (?:your|the) (?:message |usage )?limit|(?:message|usage|rate) limit (?:reached|exceeded)|out of (?:free )?messages|(?:hit|reached) your (?:free )?(?:plan )?limit)/i.test(text)||
    /(?:limit|messages|usage)[\s\S]{0,100}(?:try again|resets? (?:at|in)|come back)/i.test(text);
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
      bridge.postMessage({event:'limit',notice:text,snapshot:snapshot()});
    }
    if(!signedIn&&document.querySelector('[contenteditable="true"][role="textbox"],textarea[placeholder*="Claude"]')){
      signedIn=true;bridge.postMessage({event:'signedIn'});
    }
  }
  globalThis.claudeCheckLimits=()=>{lastLimit='';check();};
  const observer=new MutationObserver(()=>{
    if(scheduled)return;scheduled=true;setTimeout(check,800);
  });
  observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
  check();
})();
