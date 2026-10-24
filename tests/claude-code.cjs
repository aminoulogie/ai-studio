const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {repoPrivatePath}=require('../assets/repo-privacy.js');
global.repoPrivatePath=repoPrivatePath;
const api=require('../assets/claude-code.js');
const selected=api.selectClaudeContextPaths(['.env','memory/user.md','src/chat.js','README.md','assets/studio.css'],'fix chat button');
assert.ok(selected.includes('src/chat.js'));assert.ok(!selected.includes('.env'));assert.ok(!selected.includes('memory/user.md'));
assert.throws(()=>api.selectClaudeContextPaths(['.env'],'task',['.env']),/private/);
assert.throws(()=>api.selectClaudeContextPaths(['src/a.js'],'task',['src/missing.js']),/missing/);
const excerpt=api.claudeSourceExcerpt('line\n'.repeat(8000),'line',2000);
assert.ok(excerpt.length<=2000);assert.match(excerpt,/PARTIAL SOURCE/);
const prompt=api.buildClaudeCodePrompt({id:'request-1',task:'Fix the screen',repo:'owner/repo',branch:'main',base:'test',effort:'high',files:[{path:'src/chat.js',content:'const x=1;'}]});
assert.match(prompt,/\[AI Studio task request-1\]/);assert.match(prompt,/thorough/);assert.match(prompt,/SOURCE FILE: src\/chat.js/);
assert.ok(!prompt.includes('Bearer '));
function fixture({withSend=true,draft=''}={}){
  let now=0,busy=false,messages=[],clicks=0;
  class Area {constructor(){this.tagName='TEXTAREA';this._value=draft;}get value(){return this._value;}set value(v){this._value=v;}focus(){}dispatchEvent(){}getClientRects(){return [{}];}}
  const editor=new Area(),send={getClientRects:()=>[{}],getAttribute:()=>null,disabled:false,click(){clicks++;}},stop={...send};
  const document={addEventListener(){},querySelectorAll(s){
    if(s.includes('ProseMirror'))return [editor];
    if(s.includes('send-button'))return withSend?[send]:[];
    if(s.includes('stop-button'))return busy?[stop]:[];
    if(s.includes('model-selector'))return [{...send,innerText:'Sonnet in Claude'}];
    return [];
  }};
  const ctx={location:{protocol:'https:',hostname:'claude.ai',href:'https://claude.ai/chat/test'},document,
    HTMLTextAreaElement:Area,Event:class{},InputEvent:class{},getComputedStyle:()=>({visibility:'visible'}),
    Date:{now:()=>now},claudeVisibleSnapshot:()=>({messages})};
  vm.createContext(ctx);vm.runInContext(fs.readFileSync('ios/AIStudio/claude-code-dom.js','utf8'),ctx);
  return {ctx,editor,get clicks(){return clicks;},tick:n=>now+=n,busy:v=>busy=v,messages:v=>messages=v};
}
let f=fixture();
let state=f.ctx.claudeBeginCodeRequest({id:'x',prompt:'[AI Studio task x]\nTask'});
assert.equal(state.phase,'submitted');assert.equal(f.clicks,1);
f.ctx.claudeBeginCodeRequest({id:'x',prompt:'same'});assert.equal(f.clicks,1,'Never click Send twice for the same request');
f.messages([{role:'user',content:'[AI Studio task x]\nTask'},{role:'assistant',content:'First partial answer'}]);f.busy(true);
assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'responding');
f.tick(5000);assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'responding','Streaming output is never complete');
f.busy(false);state=f.ctx.claudeCodeRequestStatus('x');assert.equal(state.phase,'complete');assert.equal(state.text,'First partial answer');
f=fixture({withSend:false});assert.equal(f.ctx.claudeBeginCodeRequest({id:'x',prompt:'[AI Studio task x]\nTask'}).phase,'prepared');assert.equal(f.clicks,0);assert.ok(f.editor.value.includes('Task'));
f=fixture({draft:'Keep my draft'});assert.equal(f.ctx.claudeBeginCodeRequest({id:'x',prompt:'replace'}).phase,'draftPresent');assert.equal(f.editor.value,'Keep my draft');
f=fixture();f.ctx.claudeBeginCodeRequest({id:'x',prompt:'[AI Studio task x]\nTask'});f.tick(9000);
assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'prepared','Unconfirmed submission needs manual Send');
console.log('Claude Code checks passed: context selection, private paths, effort, composer submission, streaming completion and manual fallbacks.');
