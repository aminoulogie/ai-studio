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
console.log('Claude observer checks passed: notices, false positives, origins, ordered visible-text export and shared memory read-back.');
