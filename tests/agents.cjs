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
// Auto: the boss picks each task's model and effort from the allowed lists; anything else is dropped.
const auto=A.managerPrompt({task:'t',repo:'o/r',branch:'b',paths:[],pick:{models:['Haiku 4.5','Sonnet 5.5'],efforts:A.EFFORTS}});
assert.match(auto,/"model" is one of Haiku 4\.5, Sonnet 5\.5 and "effort" is one of Low, Medium/);
assert.match(auto,/"model":"Sonnet 5\.5","effort":"Medium"/);
assert.doesNotMatch(A.managerPrompt({task:'t',repo:'o/r',branch:'b',paths:[]}),/"model"/,'fixed settings: the boss does not choose');
const picked=A.parsePlan('{"tasks":[{"title":"a","instructions":"x","model":"sonnet 5.5","effort":"high"},{"title":"b","instructions":"y","model":"GPT-9","effort":"turbo"}]}');
assert.deepEqual([picked.tasks[0].model,picked.tasks[0].effort,picked.tasks[1].model,picked.tasks[1].effort],['Sonnet 5.5','High','','']);

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

// claude.ai's icon glyphs and the button and time lines under a reply are dropped.
assert.equal(A.stripEdits('Tell me what to change.\n\n\uE001\n\u{F0123}\u{F0012}\njust now\nCopy\nRetry'),'Tell me what to change.');
assert.equal(A.cleanReply('Edit the file'),'Edit the file','real sentences that start with Edit stay');
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

// Shared memory: new lines from REMEMBER blocks, no duplicates, no secrets, size limit; hidden from the reply.
const learned=A.parseMemory('Done.\n<<<REMEMBER\n- Prefers French\n- Uses tabs\nREMEMBER>>>');
assert.deepEqual(learned,['Prefers French','Uses tabs']);
let mem=A.mergeMemory('- Uses tabs',[...learned,'token ghp_abcdefghijklmnop'],4000);
assert.deepEqual(mem.added,['Prefers French']);assert.equal(mem.next,'- Uses tabs\n- Prefers French');
assert.equal(A.mergeMemory('x'.repeat(3995),['too long'],4000).added.length,0,'memory never passes its limit');
assert.equal(A.stripEdits('Hi\n<<<REMEMBER\n- a\nREMEMBER>>>'),'Hi');
// claude.ai's header and thinking title never reach memory or the reply.
const scraped='Claude responded: <<<REMEMBER\n\nDefining fonts\n\nDefining fonts\n\n'+fence+'json\n{"tasks":[]}\n'+fence+'\n\n<<<REMEMBER\n- Fonts come before Cursor call\nREMEMBER>>>';
assert.deepEqual(A.parseMemory(scraped),['Fonts come before Cursor call']);
assert.equal(A.cleanReply(scraped).split('\n')[0],fence+'json');
assert.equal(A.cleanReply('Claude a répondu : Salut\nSalut'),'Salut');
assert.match(A.workerPrompt({task:'t',repo:'o/r',branch:'b',files:[]}),/<<<REMEMBER/,'every message asks for new memory');
// Compression at a limit: the transcript, a compress request, and a handover with the last messages word for word.
const log=[{k:'user',text:'Build a todo app'},{k:'reply',text:'Done.\n```\n@@@ FILE: a.js\n@@@ CONTENT\nx\n@@@ END\n```',applied:['a.js']},{k:'user',text:'Make it blue'},{k:'reply',text:'Blue now.'}];
const tr=A.transcript(log);
assert.match(tr,/ME: Build a todo app/);assert.match(tr,/\[edited: a\.js\]/);assert.doesNotMatch(tr,/@@@/,'no edit blocks in the transcript');
assert.match(A.compressPrompt({transcript:tr,repo:'o/r',branch:'main'}),/## Goal[\s\S]*## Open problems/);
const hand=A.handoverText('## Goal\nTodo app',log,2);
assert.match(hand,/## Goal\nTodo app[\s\S]*Last messages, word for word:\nME: Make it blue\n\nCLAUDE: Blue now\./);
assert.match(A.workerPrompt({task:'Next',repo:'o/r',branch:'b',single:true,handover:hand}),/reached its usage limit[\s\S]*Todo app/);
assert.match(A.workerPrompt({task:'Next',followUp:true,files:[]}),/^\[AI Studio · follow-up\]\nNext/,'follow-ups in the same chat stay short');
assert.ok(A.transcript([{k:'user',text:'x'.repeat(100000)}],1000).length<1100,'long sessions are cut in the middle');
// Question mode and prompt fixer.
assert.deepEqual(A.parseQuestions('```json\n{"questions":[{"q":"Color?","options":["Red","Blue",]}]}\n```'),[{q:'Color?',options:['Red','Blue']}]);
assert.deepEqual(A.parseQuestions('no'),[]);
assert.equal(A.parseFixed('Here:\n```text\nBetter prompt\n```'),'Better prompt');
assert.match(A.fixPrompt('make it nice','short'),/Shorter/);
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
