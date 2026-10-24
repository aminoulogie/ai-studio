/* Code-tab automation uses the visible composer only. No Claude cookies, tokens or private endpoints. */
(function(root){
'use strict';
if(location.protocol!=='https:'||location.hostname!=='claude.ai')return;
let request=null;
const visible=el=>!!el&&!!el.getClientRects().length&&getComputedStyle(el).visibility!=='hidden';
const all=s=>Array.from(document.querySelectorAll(s)).filter(visible);
const snapshot=()=>typeof root.claudeVisibleSnapshot==='function'?root.claudeVisibleSnapshot():{messages:[]};
const assistants=()=>snapshot().messages.filter(m=>m.role==='assistant');
const generating=()=>all('button[data-testid="stop-button"],button[aria-label*="Stop response"],button[aria-label*="Stop generating"],[data-is-streaming="true"]').length>0;
function editor(){
  return all('div.ProseMirror[contenteditable="true"],[contenteditable="true"][role="textbox"],textarea[placeholder*="Claude"]')[0];
}
function fill(el,text){
  el.focus();
  if(el.tagName==='TEXTAREA'){
    const setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
    setter.call(el,text);
    el.dispatchEvent(new Event('input',{bubbles:true}));
  }else{
    const selection=getSelection(),range=document.createRange();
    range.selectNodeContents(el);selection.removeAllRanges();selection.addRange(range);
    if(!document.execCommand('insertText',false,text)){
      el.textContent=text;
      el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:text}));
    }
  }
}
function begin(input){
  if(!input||typeof input.id!=='string'||typeof input.prompt!=='string'||input.prompt.length>160000)throw new Error('Invalid Code request');
  if(request){
    if(request.id!==input.id)return {phase:'busy'};
    return status(input.id);
  }
  if(generating())return {phase:'busy'};
  const composer=editor();
  if(!composer)return {phase:'needsLogin',detail:'Open the Claude tab and sign in to this container.'};
  const draft=(composer.value??composer.innerText??composer.textContent??'').trim();
  if(draft)return {phase:'draftPresent',detail:'The Claude composer already contains a draft. Send or clear it in the Claude tab first.'};
  const history=assistants();
  request={id:input.id,phase:'prepared',baseline:history.length,lastBefore:history.at(-1)?.content||'',text:'',changedAt:Date.now(),submittedAt:Date.now()};
  fill(composer,input.prompt);
  const send=all('button[data-testid="send-button"],button[aria-label="Send message"],button[aria-label="Send Message"],button[aria-label="Send prompt"]')
    .find(b=>!b.disabled&&b.getAttribute('aria-disabled')!=='true');
  if(send){request.phase='submitted';send.click();}
  // If Claude changes its button markup, preserve the filled draft and ask for one manual Send.
  return status(input.id);
}
function status(id){
  if(!request||request.id!==id)return {phase:'notStarted',url:location.href};
  if(request.phase==='stopped')return {id:request.id,phase:'stopped',text:request.text,url:location.href};
  const history=assistants(),last=history.at(-1)?.content||'';
  const echoed=snapshot().messages.some(m=>m.role==='user'&&m.content.includes('[AI Studio task '+request.id+']'));
  if(echoed)request.confirmed=true;
  if(!request.confirmed&&Date.now()-request.submittedAt>8000)request.phase='prepared';
  const fresh=history.length>request.baseline||(last&&last!==request.lastBefore);
  if(request.confirmed&&fresh&&last!==request.text){request.text=last;request.changedAt=Date.now();request.phase='responding';}
  const busy=generating();
  if(request.confirmed&&fresh&&request.text&&!busy&&Date.now()-request.changedAt>=2500)request.phase='complete';
  if(request.phase==='prepared'&&request.confirmed)request.phase='submitted';
  return {id:request.id,phase:request.phase,text:request.text,url:location.href,generating:busy,
    model:all('[data-testid="model-selector-dropdown"],button[data-testid="model-selector"]')[0]?.innerText?.trim()||'Claude web'};
}
document.addEventListener('click',event=>{
  if(request&&event.isTrusted&&event.target?.closest?.('button[data-testid="stop-button"],button[aria-label*="Stop response"],button[aria-label*="Stop generating"]'))request.phase='stopped';
},true);
function cancel(id){
  if(!request||request.id!==id)return;
  const stop=all('button[data-testid="stop-button"],button[aria-label*="Stop response"],button[aria-label*="Stop generating"]')[0];
  if(stop)stop.click();
  request=null;
}
root.claudeBeginCodeRequest=begin;
root.claudeCodeRequestStatus=status;
root.claudeCancelCodeRequest=cancel;
})(globalThis);
