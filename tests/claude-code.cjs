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
  const document={documentElement:{},addEventListener(){},querySelectorAll(s){
    if(s.includes('ProseMirror'))return [editor];
    if(s.includes('send-button'))return withSend?[send]:[];
    if(s.includes('stop-button'))return busy?[stop]:[];
    if(s.includes('model-selector'))return [{...send,innerText:'Sonnet in Claude'}];
    return [];
  }};
  const ctx={location:{protocol:'https:',hostname:'claude.ai',href:'https://claude.ai/chat/test'},document,
    HTMLTextAreaElement:Area,Event:class{},InputEvent:class{},getComputedStyle:()=>({visibility:'visible'}),
    MutationObserver:class{observe(){}},Date:{now:()=>now},claudeVisibleSnapshot:()=>({messages})};
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
f=fixture({draft:'Keep my draft'});assert.equal(f.ctx.claudeBeginCodeRequest({id:'x',prompt:'replace'}).phase,'draftPresent');assert.equal(f.editor.value,'Keep my draft');assert.equal(f.ctx.claudeComposerBusyState().hasDraft,true);
f=fixture();f.ctx.claudeBeginCodeRequest({id:'x',prompt:'[AI Studio task x]\nTask'});f.tick(9000);
assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'prepared','Unconfirmed submission needs manual Send');
f=fixture();f.ctx.claudeBeginCodeRequest({id:'x',prompt:'[AI Studio task x]\\nTask'});
f.messages([{role:'user',content:'[AI Studio task x]\\nTask'},{role:'assistant',content:'Very quick answer'}]);
f.ctx.claudeCodeRequestStatus('x');f.tick(3000);
assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'needsConfirmation','Unknown completion markup must not silently apply output');
f.ctx.claudeConfirmCodeReply('x');assert.equal(f.ctx.claudeCodeRequestStatus('x').phase,'complete');
/* Lead + sub-agents */
const plan=api.parseLeadPlan('```json\n{"subtasks":[{"title":"UI","instructions":"Fix the button","files":["a.js"],"mode":"edit"},{"title":"API","instructions":"Fix the call","files":["b.js"]}]}\n```',2);
assert.equal(plan.length,2);assert.equal(plan[1].mode,'edit');assert.deepEqual(plan[0].files,['a.js']);
assert.equal(api.parseLeadPlan('Here is the fix, no json.',2),null);
assert.equal(api.parseLeadPlan('```json\n{"subtasks":[{"title":"x","instructions":"only one"}]}\n```',2),null,'one part is not worth delegating');
assert.equal(api.parseLeadPlan('```json\n{"subtasks":[{"instructions":"a","files":["a.js"]},{"instructions":"b","files":["a.js"]}]}\n```',2),null,'overlapping edits are refused');
assert.equal(api.parseLeadPlan('```json\n{"subtasks":[{"instructions":"a","files":["../x"]},{"instructions":"b","files":["/etc/passwd"]}]}\n```',2)[0].files.length,0,'unsafe paths are dropped');
assert.ok(api.looksLikePlan('```json\n{"subtasks":[]}\n```'));assert.ok(!api.looksLikePlan('plain answer'));
const pool=[{id:'lead',enabled:true,status:'Active',busy:false,limited:false,percent:10,number:1},
  {id:'b',enabled:true,status:'Active',busy:false,limited:false,percent:50,number:2},
  {id:'c',enabled:true,status:'Active',busy:false,limited:false,percent:20,number:3},
  {id:'d',enabled:true,status:'Rate-Limited',busy:false,limited:true,percent:100,number:4},
  {id:'e',enabled:true,status:'Active',busy:true,limited:false,percent:0,number:5},
  {id:'f',enabled:false,status:'Active',busy:false,limited:false,percent:0,number:6}];
assert.deepEqual(api.pickSubAgentContainers(pool,'lead',3).map(p=>p.id),['c','b'],'skips lead, limited, busy and paused containers; least used first');
assert.equal(api.pickSubAgentContainers(pool,'lead',1).length,1);
const merge=api.buildIntegrationPrompt({id:'m1',task:'Do it',repo:'o/r',branch:'main',base:'abc',results:[{index:1,title:'UI',mode:'edit',ok:true,container:'A',text:'done'},{index:2,title:'API',mode:'edit',ok:false,container:'B',text:'FAILED: limit'}]});
assert.match(merge,/^\[AI Studio task m1\]/);assert.match(merge,/SUBTASK 2: API \(edit, FAILED, B\)/);
assert.match(api.buildLeadPlanBlock(2),/2 other Claude containers/);
assert.equal(api.formatClaudeReset(0),'');assert.equal(api.formatClaudeReset(90*60),'in 1h 30m');assert.equal(api.formatClaudeReset(20),'in 1m');
console.log('Claude Code checks passed: context selection, private paths, effort, composer submission, streaming completion, manual fallbacks, and lead/sub-agent planning.');
