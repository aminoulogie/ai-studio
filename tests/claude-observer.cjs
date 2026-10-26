const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('ios/AIStudio/claude-observer.js','utf8');
function run({host='claude.ai',notice='',insideChat=false,loggedIn=false,reply='Work completed'}={}){
  const posted=[];
  const node=(role,text)=>({innerText:text,getAttribute:k=>k==='data-testid'?role:null,
    getClientRects:()=>[{}],parentElement:{closest:()=>null},closest:()=>insideChat?{}:null});
  const messages=[node('user-message','Original goal 🌍'),node('assistant-message',reply)];
  const alert=node('usage-limit',notice);
  const context={location:{protocol:'https:',hostname:host,href:'https://'+host+'/chat/example'},
    window:{webkit:{messageHandlers:{claudeObserver:{postMessage:m=>posted.push(m)}}}},
    document:{documentElement:{},querySelectorAll:s=>s.startsWith('[data-testid="user-message"]')?messages:(notice?[alert]:[]),
      querySelector:()=>loggedIn?{}:null},
    MutationObserver:class{observe(){}},getComputedStyle:()=>({visibility:'visible'}),setTimeout:()=>1};
  vm.runInNewContext(source,context);
  return {posted,context};
}
for(const notice of ["You've reached your limit","You’ve reached your message limit","Usage limit reached. Try again in 3 hours","You are out of messages"]){
  const {posted}=run({notice});
  assert.equal(posted.filter(x=>x.event==='limit').length,1,notice);
  assert.equal(posted[0].snapshot.messages[0].content,'Original goal 🌍');
  assert.equal(posted[0].snapshot.partial,true);
}
assert.equal(run({notice:'Usage limit reached',insideChat:true}).posted.length,0,'Ignore text inside a conversation');
assert.equal(run({notice:'You are approaching your usage limit'}).posted.length,0,'Do not rotate on a warning');
assert.equal(run({host:'accounts.google.com',notice:"You've reached your limit"}).posted.length,0,'No observer on login pages');
assert.equal(run({loggedIn:true}).posted[0].event,'signedIn');
assert.equal(run({notice:'Usage limit reached. Try again in 2 hours 15 minutes'}).posted[0].retryAfterSeconds,8100);
assert.equal(run({notice:'Usage limit reached. Try again in 25 minutes'}).posted[0].retryAfterSeconds,1500);
const {context}=run();
assert.equal(context.claudeVisibleSnapshot().messages.map(x=>x.role).join(','),'user,assistant');
const withBlock=run({reply:'Done.\n<<<STUDIO_MEMORY\n- Prefers French and English\n- Short answers\nSTUDIO_MEMORY>>>'}).context;
assert.equal(withBlock.claudeMemoryProposal(),'- Prefers French and English\n- Short answers','Read the proposed memory from the last reply');
assert.equal(run().context.claudeMemoryProposal(),null,'No block means no proposal');
assert.equal(run({reply:'<<<STUDIO_MEMORY\n\nSTUDIO_MEMORY>>>'}).context.claudeMemoryProposal(),null,'An empty block is ignored');
assert.equal(run({reply:'<<<STUDIO_MEMORY\n'+'x'.repeat(5000)+'\nSTUDIO_MEMORY>>>'}).context.claudeMemoryProposal().length,4000,'Proposals are capped');
assert.equal(run().context.claudeInsertText('hello'),false,'Report failure when the message box is missing');

// Code tab bridge: the page language must not decide whether Send can be found.
function runBox(labels,{noBox=false}={}){
  const clicked=[],events=[];
  const mk=(label,disabled=false)=>({disabled,
    getAttribute:k=>k==='aria-label'?label:(k==='aria-disabled'&&disabled?'true':null),
    getClientRects:()=>[{}],click:()=>clicked.push(label)});
  const buttons=labels.map(l=>typeof l==='string'?mk(l):mk(l.label,l.disabled));
  const scope={parentElement:null,querySelectorAll:()=>buttons};
  const box={parentElement:scope,focus(){},dispatchEvent:e=>events.push(e.type)};
  const ctx={location:{protocol:'https:',hostname:'claude.ai',href:'https://claude.ai/chat/x',pathname:'/chat/x'},
    window:{webkit:{messageHandlers:{claudeObserver:{postMessage:()=>{}}}}},
    document:{documentElement:{},querySelectorAll:s=>s.includes('button')?buttons:[],
      querySelector:s=>noBox?null:(s.includes('contenteditable')?box:null)},
    MutationObserver:class{observe(){}},getComputedStyle:()=>({visibility:'visible'}),setTimeout:()=>1,
    KeyboardEvent:class{constructor(type,init){this.type=type;Object.assign(this,init)}}};
  vm.runInNewContext(source,ctx);
  return {context:ctx,clicked,events};
}
let r=runBox(['Attach file','Send message']);
assert.equal(r.context.claudeSubmit(),true,'English Send button');
assert.deepEqual(r.clicked,['Send message']);
r=runBox(['Joindre un fichier','Envoyer le message','Commande vocale']);
assert.equal(r.context.claudeSubmit(),true,'French Send button');
assert.deepEqual(r.clicked,['Envoyer le message'],'Only the Send button is pressed, never attach or voice');
r=runBox([{label:'Send message',disabled:true}]);
assert.equal(r.context.claudeSubmit(),false,'A disabled Send button is not pressed');
assert.deepEqual(r.clicked,[]);
r=runBox(['Attach file','Dictate']);
assert.equal(r.context.claudeSubmit(),false,'Never guess a button that is not Send');
assert.deepEqual(r.clicked,[]);
assert.equal(r.context.claudeSubmitKey(),true,'Enter fallback reaches the message box');
assert.deepEqual(r.events,['keydown','keypress','keyup']);
r=runBox([],{noBox:true});
assert.equal(r.context.claudeSubmit(),false);
assert.equal(r.context.claudeSubmitKey(),false,'No Enter fallback without a message box');
assert.equal(r.context.claudeSubmitDiag(),'no message box found');
r=runBox(['Attach file',{label:'Send message',disabled:true}]);
assert.equal(r.context.claudeSubmitDiag(),'Attach file | Send message (disabled)','Failure can say which buttons were visible');
r=runBox(['Stop response']);
assert.equal(r.context.claudeStatus().streaming,true,'Stop button means Claude is answering');
assert.equal(r.context.claudeStop(),true);
assert.deepEqual(r.clicked,['Stop response']);
r=runBox(['Arrêter la réponse']);
assert.equal(r.context.claudeStatus().streaming,true,'French Stop button means Claude is answering');
assert.equal(r.context.claudeStop(),true);
r=runBox(['Send message']);
assert.equal(r.context.claudeStatus().streaming,false);
assert.equal(r.context.claudeStop(),false,'Stop must not press Send');
assert.equal(run().context.claudeAttachImages('[]'),0,'No photos means nothing attached');
assert.equal(run().context.claudeAttachImages('not json'),0,'Bad input attaches nothing');
// Replies keep code blocks verbatim (with fences) so edits apply exactly; the code block's label and Copy button are skipped.
{
  const el=(tag,kids=[],extra={})=>{const e={nodeType:1,tagName:tag,childNodes:kids,...extra};kids.forEach((k,i)=>{k.parentElement=e;k.nextElementSibling=kids.slice(i+1).find(x=>x.nodeType===1)||null;});
    e.querySelector=sel=>{const walk=n=>{for(const c of n.childNodes||[]){if(c.nodeType===1&&(sel==='pre'&&c.tagName==='PRE'||sel==='code'&&c.tagName==='CODE'))return c;const f=walk(c);if(f)return f;}return null;};return walk(e);};
    if(!('innerText' in e))e.innerText=kids.map(k=>k.innerText??k.nodeValue??'').join('');return e;};
  const txt=t=>({nodeType:3,nodeValue:t});
  const code=el('CODE',[],{className:'language-js',textContent:'@@@ FILE: a.js\n@@@ OLD\n  x  = 1;\n@@@ NEW\n  x = 2;\n@@@ END\n'});
  const block=el('DIV',[el('DIV',[],{innerText:'javascript'}),el('PRE',[code]),el('BUTTON',[],{innerText:'Copy'})]);
  const reply=el('DIV',[el('P',[],{innerText:'I changed it.'}),block,el('P',[],{innerText:'Done.'})],{getAttribute:k=>k==='data-is-streaming'?'false':null,getClientRects:()=>[{}]});
  const ctx={location:{protocol:'https:',hostname:'claude.ai',href:'https://claude.ai/chat/x',pathname:'/chat/x'},
    window:{webkit:{messageHandlers:{claudeObserver:{postMessage:()=>{}}}}},
    document:{documentElement:{},querySelectorAll:s=>s.startsWith('[data-testid="user-message"]')?[reply]:[],querySelector:()=>null},
    MutationObserver:class{observe(){}},getComputedStyle:()=>({visibility:'visible'}),setTimeout:()=>1};
  reply.parentElement={closest:()=>null};
  vm.runInNewContext(source,ctx);
  assert.equal(ctx.claudeStatus().last,'I changed it.\n\n```js\n@@@ FILE: a.js\n@@@ OLD\n  x  = 1;\n@@@ NEW\n  x = 2;\n@@@ END\n```\n\nDone.','code kept exactly, label and Copy skipped');
}
console.log('Claude observer checks passed: replies with exact code blocks, notices, false positives, origins, ordered visible-text export, shared memory read-back, send/stop in any language, Enter fallback.');
