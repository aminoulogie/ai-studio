/* Visible Claude page observation and the Code tab bridge: type into the message box, press Send for sub-agents, read the reply. No cookies, tokens, password fields or private APIs. */
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
    if(match&&(match[1]||match[2])){
      const seconds=(Number(match[1]||0)*3600)+(Number(match[2]||0)*60);
      return seconds>0&&seconds<=86400?seconds:null;
    }
    // "resets at 2:50 PM" / "try again at 14:50": the next time the clock shows that.
    const at=text.match(/(?:try again|resets?|come back|available)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?\s?[Mm]\.?)?/i);
    if(!at||(!at[2]&&!at[3]))return null;
    let h=Number(at[1])%24;const m=Number(at[2]||0),pm=at[3]&&/p/i.test(at[3]);
    if(at[3])h=h%12+(pm?12:0);
    const now=new Date(),then=new Date(now);then.setHours(h,m,0,0);
    if(then<=now)then.setDate(then.getDate()+1);
    const seconds=Math.round((then-now)/1000);
    return seconds>0&&seconds<=86400?seconds:null;
  }
  // A reply's text with code blocks kept exactly (fenced), so edits can be applied character for character.
  // Rendered prose comes from innerText; a code block's label and copy button are skipped.
  const BLOCK=/^(P|DIV|UL|OL|LI|H[1-6]|BLOCKQUOTE|TABLE|TR|SECTION|ARTICLE|HR)$/;
  const hasPre=n=>!!n&&(n.tagName==='PRE'||!!n.querySelector?.('pre'));
  function replyText(el){
    if(!el.querySelector||!el.querySelector('pre'))return (el.innerText||'').trim();
    let out='';
    const walk=node=>{
      for(const child of node.childNodes){
        if(child.nodeType===3){out+=child.nodeValue;continue;}
        if(child.nodeType!==1||child.tagName==='BUTTON')continue;
        if(child.tagName==='PRE'){
          const code=child.querySelector('code')||child;
          const lang=((code.className||'').match(/language-([\w+#.-]+)/)||[])[1]||'';
          out+='\n```'+lang+'\n'+(code.textContent||'').replace(/\n$/,'')+'\n```\n';continue;
        }
        if(hasPre(child)){walk(child);continue;}
        // A code block's label sits in a short div or span right before it; prose (p, headings, lists) is always kept.
        if(/^(DIV|SPAN)$/.test(child.tagName)&&hasPre(child.nextElementSibling)&&(child.innerText||'').trim().length<40)continue;
        const block=BLOCK.test(child.tagName);
        out+=(block?'\n':'')+(child.innerText||'')+(block?'\n':'');
      }
    };
    walk(el);
    return out.replace(/\n{3,}/g,'\n\n').trim();
  }
  // Icon-font glyphs (copy, retry…) and the "just now" / button lines under a message are page chrome, not text.
  const CHROME_LINE=/^\s*(?:just now|\d+\s*(?:s|sec|secs|seconds?|m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)\s*ago|yesterday|copy|retry|edit|share|good response|bad response|give positive feedback|give negative feedback)\s*$/i;
  function clean(text){
    return String(text||'').replace(/[\uE000-\uF8FF\uFFFC\uFFFD]|[\u{F0000}-\u{FFFFD}]|[\u{100000}-\u{10FFFD}]/gu,'')
      .split('\n').filter(l=>!CHROME_LINE.test(l)).join('\n').replace(/[ \t]+$/gm,'').replace(/\n{3,}/g,'\n\n').trim();
  }
  function messages(){
    const items=[];
    // Keep document order. These selectors are best-effort public DOM markers, not an API.
    for(const el of document.querySelectorAll('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]')){
      if(el.parentElement?.closest('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]'))continue;
      const user=el.getAttribute('data-testid')==='user-message';
      const text=clean(user?el.innerText:replyText(el));if(!text)continue;
      items.push({role:user?'user':'assistant',content:text});
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
    try{if(typeof NodeFilter!=='undefined')checkPlan();}catch(e){}
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
  // Code tab bridge helpers. Button labels depend on the language of claude.ai, so several languages are matched
  // and an unlabeled button is never guessed.
  const SEND_RE=/\b(send|submit)\b|envoy|enviar|senden|absenden|invia|verstuur|wyślij|wyslij|отправ|发送|傳送|送信|전송|gönder|skicka|lähetä|odeslat|küld/i;
  const STOP_RE=/\bstop\b|arr[êe]t|detener|parar|stopp|ferma|zatrzym|останов|停止|中止|중지|durdur/i;
  const SKIP_RE=/stop|arr[êe]t|attach|upload|joindre|pi[eè]ce|adjunt|anhang|allegat|add (files|content)|ajouter|hinzuf|voice|vocal|dict|micro|\bmic\b|feedback|report|signal/i;
  const labelOf=el=>(el.getAttribute('aria-label')||el.getAttribute('title')||el.getAttribute('data-testid')||'').trim();
  const composerBox=()=>document.querySelector('[contenteditable="true"][role="textbox"]')||document.querySelector('textarea[placeholder*="Claude"]')||document.querySelector('textarea');
  function findButton(re,root){
    const list=Array.from((root||document).querySelectorAll('button,[role="button"]'));
    for(let i=list.length-1;i>=0;i--){
      const el=list[i];
      if(!visible(el))continue;
      const label=labelOf(el);
      if(label&&re.test(label)&&(re!==SEND_RE||!SKIP_RE.test(label)))return el;
    }
    return null;
  }
  function findSendButton(){
    let scope=composerBox();
    for(let i=0;i<6&&scope&&scope.parentElement;i++){
      scope=scope.parentElement;
      const found=findButton(SEND_RE,scope);
      if(found)return found;
    }
    return null;
  }
  // Code tab bridge: report progress, press send, press stop. Only called by native code after the person sends from the Code tab.
  globalThis.claudeStatus=()=>{
    const items=messages();
    const assistants=items.filter(m=>m.role==='assistant');
    return {
      users:items.filter(m=>m.role==='user').length,
      assistants:assistants.length,
      streaming:!!(document.querySelector('[data-is-streaming="true"]')||findButton(STOP_RE)),
      last:assistants.length?assistants[assistants.length-1].content:'',
      loggedOut:/^\/(login|logout)/.test(location.pathname||'')
    };
  };
  globalThis.claudeSubmit=()=>{
    const btn=findSendButton();
    if(!btn||btn.disabled||btn.getAttribute('aria-disabled')==='true')return false;
    btn.click();return true;
  };
  // Last resort when no send button can be found: press Enter in the message box. Native code then checks the message really went.
  globalThis.claudeSubmitKey=()=>{
    const box=composerBox();if(!box)return false;
    box.focus();
    const init={key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true};
    for(const type of ['keydown','keypress','keyup'])box.dispatchEvent(new KeyboardEvent(type,init));
    return true;
  };
  // Photos from the Code tab: put them in Claude's file input (or paste them) so they upload like normal attachments.
  // Returns how many were attached; native code refuses to send when this is lower than expected.
  globalThis.claudeAttachImages=json=>{
    try{
      const list=JSON.parse(json);if(!Array.isArray(list)||!list.length)return 0;
      const dt=new DataTransfer();
      for(const item of list){
        const bin=atob(String(item.data||''));const bytes=new Uint8Array(bin.length);
        for(let i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
        dt.items.add(new File([bytes],String(item.name||'photo.jpg'),{type:String(item.mime||'image/jpeg')}));
      }
      const input=Array.from(document.querySelectorAll('input[type="file"]')).find(el=>!el.disabled);
      if(input){
        input.files=dt.files;
        input.dispatchEvent(new Event('input',{bubbles:true}));
        input.dispatchEvent(new Event('change',{bubbles:true}));
        return dt.files.length;
      }
      const box=composerBox();if(!box)return 0;
      box.focus();
      box.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));
      return dt.files.length;
    }catch(e){return 0;}
  };
  // Names of the buttons around the message box, so a failure can say what was visible.
  globalThis.claudeSubmitDiag=()=>{
    const box=composerBox();if(!box)return 'no message box found';
    let scope=box;
    for(let i=0;i<4&&scope.parentElement;i++)scope=scope.parentElement;
    return Array.from(scope.querySelectorAll('button,[role="button"]')).filter(visible)
      .map(el=>(labelOf(el)||'unlabeled')+(el.disabled?' (disabled)':'')).slice(0,8).join(' | ').slice(0,300);
  };
  globalThis.claudeStop=()=>{
    const btn=findButton(STOP_RE);
    if(!btn)return false;
    btn.click();return true;
  };
  // Model pill: the model and effort Claude shows next to the message box, e.g. "Sonnet 5.5 · High". Read-only here;
  // switching opens Claude's own picker so the choice is made exactly where Claude offers it.
  const MODEL_RE=/\b(sonnet|opus|haiku|fable|mythos)\b/i;
  function modelButton(){
    const known=document.querySelector('[data-testid="model-selector-dropdown"]');
    if(known&&visible(known))return known;
    const list=Array.from(document.querySelectorAll('button,[role="button"]')).filter(visible);
    for(let i=list.length-1;i>=0;i--){
      const text=(list[i].innerText||'').trim();
      if(text&&text.length<=40&&MODEL_RE.test(text))return list[i];
    }
    return null;
  }
  globalThis.claudeModelInfo=()=>{
    const el=modelButton();if(!el)return '';
    const text=(el.innerText||'').split(/\n+/).map(s=>s.trim()).filter(Boolean).join(' ');
    return text.replace(/\s+(Low|Medium|High|Extra high|Max)$/i,' · $1').slice(0,60);
  };
  globalThis.claudeOpenModelPicker=()=>{
    const el=modelButton();if(!el)return false;
    for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){
      const Ctor=type.startsWith('pointer')&&typeof PointerEvent==='function'?PointerEvent:MouseEvent;
      el.dispatchEvent(new Ctor(type,{bubbles:true,cancelable:true,button:0,pointerType:'touch'}));
    }
    return true;
  };
  // Picks a model and effort in Claude's own menu, like a person would. Returns 'ok', or why it could not.
  const pause=ms=>new Promise(r=>setTimeout(r,ms));
  function press(el){
    for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){
      const Ctor=type.startsWith('pointer')&&typeof PointerEvent==='function'?PointerEvent:MouseEvent;
      el.dispatchEvent(new Ctor(type,{bubbles:true,cancelable:true,button:0,pointerType:'touch'}));
    }
  }
  const menuItems=()=>Array.from(document.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"],[role="radio"],[role="tab"],[role="menu"] button,[role="listbox"] button,[role="dialog"] button')).filter(visible);
  const firstLine=el=>((el.innerText||el.textContent||'').trim().split(/\n+/)[0]||'').trim();
  const wordRe=w=>new RegExp('\\b'+String(w).toLowerCase().replace(/^claude\s+/,'').replace(/[.]/g,'\\.').replace(/[-\s]+/g,'[-\\s]*')+'\\b','i');
  const closeMenu=()=>document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));
  globalThis.claudeSetModel=async(model,effort)=>{
    const now=()=>(globalThis.claudeModelInfo?.()||'');
    const needModel=!!model&&!wordRe(model).test(now());
    const needEffort=!!effort&&!wordRe(effort).test(now());
    if(!needModel&&!needEffort)return 'ok';
    let btn=modelButton();if(!btn)return 'no model menu on this page';
    if(needModel){
      press(btn);await pause(450);
      const item=menuItems().find(el=>el!==btn&&wordRe(model).test(firstLine(el)));
      if(!item){closeMenu();return 'model not offered: '+model;}
      press(item);await pause(600);
    }
    if(needEffort){
      if(!menuItems().length){btn=modelButton();if(!btn)return 'no model menu on this page';press(btn);await pause(450);}
      let item=menuItems().find(el=>wordRe(effort).test(firstLine(el)));
      if(!item){
        // Effort can sit in a sub-menu ("Effort ›", "Extended thinking ›").
        const sub=menuItems().find(el=>/effort|thinking|intensity/i.test(firstLine(el)));
        if(sub){press(sub);await pause(400);item=menuItems().find(el=>wordRe(effort).test(firstLine(el)));}
      }
      if(!item){closeMenu();return 'effort not offered: '+effort;}
      press(item);await pause(300);
    }
    closeMenu();
    return 'ok';
  };
  // The account's plan as claude.ai labels it ("Free plan", "Pro plan", "Max plan"), outside any conversation.
  const PLAN_RE=/^(free|pro|max|team|enterprise)(?:\s*\d+x)?\s+plan$/i;
  let planSeen='',planCheckedAt=0;
  function checkPlan(){
    if(Date.now()-planCheckedAt<15000)return;
    planCheckedAt=Date.now();
    const walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT);
    let n=0,node;
    while((node=walker.nextNode())&&n++<4000){
      const t=(node.nodeValue||'').trim();
      if(t.length>20||!PLAN_RE.test(t))continue;
      if(node.parentElement?.closest('[data-testid="user-message"],[data-testid="assistant-message"],[data-is-streaming]'))continue;
      const plan=t.match(PLAN_RE)[1].toLowerCase();
      if(plan!==planSeen){planSeen=plan;bridge.postMessage({event:'plan',plan});}
      return;
    }
  }
  globalThis.claudeCheckLimits=()=>{lastLimit='';check();};
  const observer=new MutationObserver(()=>{
    if(scheduled)return;scheduled=true;setTimeout(check,800);
  });
  observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
  check();
})();
