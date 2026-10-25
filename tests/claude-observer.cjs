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
// Code tab send/stop: claude.ai button labels follow the page language, and an unlabeled button is never guessed.
function runButtons(items,{box=true}={}){
  const clicks=[],keys=[];
  const btns=items.map(x=>typeof x==='string'?{label:x}:x).map(b=>({
    getAttribute:k=>k==='aria-label'?b.label:null,getClientRects:()=>[{}],disabled:!!b.disabled,click:()=>clicks.push(b.label)}));
  const scope={querySelectorAll:()=>btns,parentElement:null};
  const middle={querySelectorAll:()=>[],parentElement:scope};
  const boxEl={parentElement:middle,focus(){},dispatchEvent:e=>keys.push(e.type)};
  const context={location:{protocol:'https:',hostname:'claude.ai',href:'https://claude.ai/chat/x',pathname:'/chat/x'},
    window:{webkit:{messageHandlers:{claudeObserver:{postMessage(){}}}}},
    document:{documentElement:{},querySelectorAll:s=>s.startsWith('button')?btns:[],
      querySelector:s=>box&&s.includes('contenteditable')?boxEl:null},
    MutationObserver:class{observe(){}},getComputedStyle:()=>({visibility:'visible'}),setTimeout:()=>1,
    KeyboardEvent:class{constructor(type,init){this.type=type;Object.assign(this,init);}}};
  vm.runInNewContext(source,context);
  return {context,clicks,keys};
}
for(const [label,others] of [['Send message',['Add files']],['Envoyer le message',['Joindre un fichier','Dicter']],
  ['Enviar mensaje',['Adjuntar archivo']],['Nachricht senden',['Datei anhängen']],['发送消息',['添加文件']],['送信',[]],['Отправить сообщение',[]]]){
  const t=runButtons([...others,label]);
  assert.equal(t.context.claudeSubmit(),true,'find send in: '+label);
  assert.deepEqual(t.clicks,[label],'press only the send button: '+label);
}
for(const items of [[''],['Add files','Use voice mode'],['Joindre un fichier'],['Send feedback'],[{label:'Send message',disabled:true}]]){
  const t=runButtons(items);
  assert.equal(t.context.claudeSubmit(),false,'no send button to press: '+JSON.stringify(items));
  assert.deepEqual(t.clicks,[],'nothing pressed: '+JSON.stringify(items));
}
for(const label of ['Stop response','Arrêter la réponse','Detener respuesta','停止']){
  const t=runButtons([label]);
  assert.equal(t.context.claudeStatus().streaming,true,'streaming seen from: '+label);
  assert.equal(t.context.claudeStop(),true,'stop pressed: '+label);
  assert.equal(t.context.claudeSubmit(),false,'a stop button is never pressed as send: '+label);
}
assert.equal(runButtons(['Send message']).context.claudeStatus().streaming,false,'a send button is not streaming');
const enter=runButtons(['']);
assert.equal(enter.context.claudeSubmitKey(),true,'Enter fallback works with a message box');
assert.deepEqual(enter.keys,['keydown','keypress','keyup'],'Enter fallback sends a full key press');
assert.equal(runButtons([],{box:false}).context.claudeSubmitKey(),false,'Enter fallback needs a message box');
assert.equal(runButtons([],{box:false}).context.claudeSubmitDiag(),'no message box found');
assert.equal(runButtons(['Envoyer le message','',{label:'Dicter',disabled:true}]).context.claudeSubmitDiag(),'Envoyer le message | unlabeled | Dicter (disabled)','diagnostic names the visible buttons');
console.log('Claude observer checks passed: notices, false positives, origins, ordered visible-text export, shared memory read-back, send/stop in several languages and the Enter fallback.');
