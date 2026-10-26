// The team's text protocol: manager plan, sub-agent edit blocks, exact application, repair, diff.
const assert=require('node:assert/strict');
require('../assets/repo-privacy.js');
const A=require('../assets/agents.js');
const fence='```';

// Plans: fenced JSON, prose around it, trailing commas, private paths dropped, task cap.
let plan=A.parsePlan('Here is the plan:\n'+fence+'json\n{"summary":"Bigger button","tasks":[{"title":"Button","files":["./index.html","memory/notes.md"],"instructions":"Make it bigger"},{"title":"x","files":[],"instructions":"y"},],}\n'+fence);
assert.equal(plan.summary,'Bigger button');
assert.deepEqual(plan.tasks[0].files,['index.html'],'private paths never reach a sub-agent');
assert.equal(A.parsePlan(JSON.stringify({tasks:[1,2,3].map(n=>({title:'t'+n,instructions:'do '+n}))}),2).tasks.length,2,'task cap');
assert.equal(A.parsePlan('{"summary":"","answer":"It is a demo.","tasks":[]}').answer,'It is a demo.');
assert.equal(A.parsePlan('no json here'),null);

// Edit blocks: several per code block, CONTENT, missing END before the next FILE, unfinished stream ignored.
const reply=['Done.',fence,'@@@ FILE: src/app.js','@@@ OLD','  const size = 12;','@@@ NEW','  const size = 16;','@@@ OLD','go()','@@@ NEW','run()','@@@ END',
  '@@@ FILE: docs/new.md','@@@ CONTENT','# Title',fence+'js','x',fence,'@@@ END',fence,
  fence,'@@@ FILE: a.txt','@@@ OLD','one','@@@ NEW','two',fence,fence,'@@@ FILE: b.txt','@@@ CONTENT','b',fence,'Then streaming:',fence,'@@@ FILE: c.txt','@@@ OLD','half'].join('\n');
const edits=A.parseEdits(reply);
assert.deepEqual(edits.map(e=>e.path+':'+e.kind),['src/app.js:replace','src/app.js:replace','docs/new.md:write','a.txt:replace','b.txt:write']);
assert.equal(edits[4].new,'b','an unterminated block ends at its closing fence');
assert.equal(edits[2].new,'# Title\n'+fence+'js\nx\n'+fence,'code fences inside a file are kept');
assert.equal(edits[3].new,'two','a missing END closes at the next FILE without the fence');

// Applying: exact, then tolerant of trailing spaces, indentation and "N: " prefixes. Never guesses between two matches.
let r=A.applyEdits(edits,{'src/app.js':'function a(){\n  const size = 12;   \n  go()\n}\n','a.txt':'zero\none\n'});
assert.equal(r.texts['src/app.js'],'function a(){\n  const size = 16;   \n  run()\n}\n');
assert.equal(r.texts['docs/new.md'],'# Title\n'+fence+'js\nx\n'+fence+'\n');
assert.equal(r.texts['a.txt'],'zero\ntwo\n');
assert.equal(r.failed.length,0);
r=A.applyEdits([{path:'x.js',kind:'replace',old:'  if (a) {\n    b();',new:'if (a) {\n  c();'}],{'x.js':'if (a) {\n  b();\n}\n'});
assert.equal(r.texts['x.js'],'if (a) {\n  c();\n}\n','indentation-tolerant match');
r=A.applyEdits([{path:'x.js',kind:'replace',old:'12: b();',new:'c();'}],{'x.js':'a();\nb();\n'});
assert.equal(r.texts['x.js'],'a();\nc();\n','line-number prefixes from excerpts are ignored');
r=A.applyEdits([{path:'x.js',kind:'replace',old:'b();',new:'c();'}],{'x.js':'b();\nb();\n'});
assert.match(r.failed[0].reason,/2 times/,'ambiguous OLD is refused');
r=A.applyEdits([{path:'x.js',kind:'replace',old:'nope',new:'c'},{path:'gone.js',kind:'replace',old:'a',new:'b'},{path:'.env',kind:'write',new:'SECRET=1'}],{'x.js':'a','gone.js':null});
assert.deepEqual(r.failed.map(f=>f.reason),['OLD text was not found in the file','the file does not exist','private files stay on the device']);
assert.equal(r.texts['.env'],undefined);

// Repair prompt carries the failed edit and the current file.
const repair=A.repairPrompt({goal:'g',failed:r.failed.slice(0,1),files:[{path:'x.js',text:'a'}],repo:'o/r',branch:'main'});
assert.match(repair,/@@@ OLD\nnope/);assert.match(repair,/=== FILE x\.js ===\na/);

// Reading: edit blocks hidden from the reply, streaming blocks too.
assert.equal(A.stripEdits(reply).split('\n')[0],'Done.');
assert.doesNotMatch(A.stripEdits(reply),/@@@/);

// Prompts: the manager sees the tree, never private files; sub-agents see their task, files and the format.
const paths=['index.html','src/app.js','memory/me.md','README.md'];
const m=A.managerPrompt({task:'Make the button bigger',repo:'o/r',branch:'main',paths,files:[],maxTasks:3});
assert.match(m,/At most 3 tasks/);assert.doesNotMatch(m,/memory\/me\.md/);
const w=A.workerPrompt({task:'Edit the button',goal:'Bigger button',repo:'o/r',branch:'main',files:[{path:'index.html',text:'<b>'},{path:'new.css',text:null}]});
assert.match(w,/YOUR TASK:\nEdit the button/);assert.match(w,/@@@ FILE:/);assert.match(w,/new\.css \(does not exist yet\)/);
const big='line\n'.repeat(20000)+'the button lives here\n'+'line\n'.repeat(20000);
const ex=A.sourceExcerpt(big,'button',16000);
assert.ok(ex.partial&&ex.text.length<=16000&&/\d+: the button lives here/.test(ex.text),'large files are excerpted around the task');
assert.deepEqual(A.contextPaths(paths,'fix src/app.js please',{max:2}),['src/app.js','index.html']);

// Diff, pool, quick questions.
assert.deepEqual(A.diffStats('a\nb\nc','a\nB\nc\nd'),{add:2,del:1});
assert.deepEqual(A.lineDiff('a\nb','a\nc').map(x=>x.t),[' ','-','+']);
(async()=>{
  let live=0,peak=0;const done=[];
  await A.pool([1,2,3,4,5],2,async n=>{live++;peak=Math.max(peak,live);await new Promise(r=>setTimeout(r,5));done.push(n);live--;});
  assert.equal(peak,2,'never more than the limit at once');assert.equal(done.length,5);
  assert.equal(A.isQuickQuestion('hi'),true);assert.equal(A.isQuickQuestion('What does this app do?'),true);
  assert.equal(A.isQuickQuestion('Can you add a dark mode?'),false);assert.equal(A.isQuickQuestion('Redesign the settings page'),false);
  console.log('Agent checks passed: plans, edit blocks, tolerant exact apply, repair, prompts, excerpts, diff, parallel pool.');
})().catch(e=>{console.error(e);process.exitCode=1;});
