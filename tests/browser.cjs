// End-to-end: the page in WebKit (iPhone) and Chromium (desktop) with a fake iOS bridge and a fake GitHub.
// A team task goes manager → plan → two sub-agents in parallel → edits staged → review → commit.
const {webkit,chromium}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const root=path.join(__dirname,'..');
const server=http.createServer((req,res)=>{
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  const file=path.join(root,pathname==='/'?'index.html':pathname);
  if(!file.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
  fs.readFile(file,(err,data)=>{if(err){res.writeHead(404);res.end();return;}
    res.setHeader('Content-Type',{'.js':'text/javascript','.css':'text/css','.html':'text/html'}[path.extname(file)]||'text/plain');res.end(data);
  });
});
const FILES={'index.html':'<button class="send">Send</button>\n<p>Hello</p>\n','app.js':'const size = 12;\nfunction go(){\n  return size;\n}\n','README.md':'# Demo\n'};
// The fake iOS app: containers, and Claude replies that stream in over a few events.
const nativeMock=`(()=>{
  const profiles=[{id:'M',name:'Opus account',status:'Active',enabled:true,manager:true,busy:false,ready:true},
    {id:'W1',name:'Free 1',status:'Active',enabled:true,manager:false,busy:false,ready:true},
    {id:'W2',name:'Free 2',status:'Active',enabled:true,manager:false,busy:false,ready:true}];
  window.__sent=[];window.__ops=[];let memory='';
  const plan='\\u0060\\u0060\\u0060json\\n'+JSON.stringify({summary:'Bigger send button and size',answer:'',tasks:[
    {title:'Make the send button bigger',files:['index.html'],instructions:'Add class big to the send button in index.html'},
    {title:'Raise the size',files:['app.js'],instructions:'Change size from 12 to 16 in app.js'}]})+'\\n\\u0060\\u0060\\u0060';
  function reply(o){
    if(o.role==='manager')return plan;
    if(/YOUR TASK:\\nAdd class big/.test(o.text))return 'I made the button bigger.\\n\\u0060\\u0060\\u0060\\n@@@ FILE: index.html\\n@@@ OLD\\n<button class="send">Send</button>\\n@@@ NEW\\n<button class="send big">Send</button>\\n@@@ END\\n\\u0060\\u0060\\u0060';
    if(/YOUR TASK:\\nChange size/.test(o.text))return 'Size is now 16.\\n\\u0060\\u0060\\u0060\\n@@@ FILE: app.js\\n@@@ OLD\\nconst size = 12;\\n@@@ NEW\\nconst size = 16;\\n@@@ END\\n\\u0060\\u0060\\u0060';
    if(/AI Studio · compress/.test(o.text))return '## Goal\\nA demo app.\\n## Next step\\nKeep going.';
    if(/AI Studio · questions/.test(o.text))return '\\u0060\\u0060\\u0060json\\n{"questions":[{"q":"Which color?","options":["Orange","Blue"]},{"q":"Rounded?","options":["Yes","No"]}]}\\n\\u0060\\u0060\\u0060';
    if(/AI Studio · prompt fixer/.test(o.text))return '\\u0060\\u0060\\u0060text\\nMake the send button 20% larger in index.html and keep its color.\\n\\u0060\\u0060\\u0060';
    if(/AI Studio · follow-up/.test(o.text))return 'Sure, still the same demo app.';
    return 'This project is a small demo app.\\n<<<REMEMBER\\n- The user calls the project the demo\\nREMEMBER>>>';
  }
  const emit=p=>setTimeout(()=>window.onClaudeStream&&window.onClaudeStream(p),0);
  window.webkit={messageHandlers:{native:{postMessage:async o=>{
    window.__ops.push(o.op);
    switch(o.op){
      case 'credentialGet':return localStorage.getItem('__gh')||'';
      case 'credentialSet':localStorage.setItem('__gh',o.value||'');return true;
      case 'memoryGet':return memory;
      case 'memorySet':memory=o.text;return memory;
      case 'claudeProfiles':return profiles;
      case 'claudeStop':return true;
      case 'openClaude':return true;
      case 'claudeSetEnabled':{const p=profiles.find(p=>p.id===o.profile);p.enabled=o.enabled;p.ready=o.enabled;return true;}
      case 'dictateStart':setTimeout(()=>window.onDictation({text:'make it blue',final:true}),20);return true;
      case 'dictateStop':return true;
      case 'claudeUsage':return {text:o.profile==='M'?'Plan usage\\nCurrent session\\n52% used\\nResets in 3 hr 39 min\\nWeekly limits\\nAll models\\n7% used\\nResets Mon 3:59 AM':'Settings',signedOut:false};
      case 'claudeSetManager':profiles.forEach(p=>p.manager=p.id===o.profile);return true;
      case 'claudeSend':{
        window.__sent.push({role:o.role,text:o.text,profile:o.profile,moveOnLimit:o.moveOnLimit,files:(o.images||[]).map(i=>i.mime)});
        // A pinned container that has hit its limit hands the job back so the page can compress the chat.
        if(o.profile&&window.__limited===o.profile){setTimeout(()=>emit({id:o.id,state:'limited',account:'Free 1',profile:o.profile,note:'Free 1 reached its limit.'}),20);return {account:'Free 1',profile:o.profile};}
        const who=o.role==='manager'?profiles[0]:profiles[1+(window.__sent.filter(s=>s.role!=='manager').length-1)%2];
        const text=reply(o),base={id:o.id,account:who.name,profile:who.id,role:o.role};
        setTimeout(()=>{
          if(o.role==='manager')emit({...base,state:'awaiting',note:'Press Send in Opus account'});
          emit({...base,state:'streaming',text:text.slice(0,20)});
          const finish=()=>window.__slow?setTimeout(finish,50):emit({...base,state:'done',text});
          setTimeout(finish,60);
        },30);
        return {account:who.name,profile:who.id};
      }
      case 'studioUpdateStatus':return {builtIn:1,running:1,nativeLevel:3};
      default:throw new Error('unexpected op '+o.op);
    }
  }}}};
})();`;
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url='http://127.0.0.1:'+server.address().port;
  fs.mkdirSync(path.join(root,'test-artifacts'),{recursive:true});
  const phone=process.env.PW_CHROMIUM_ONLY?chromium:webkit;
  for(const [name,engine,viewport] of [['iphone',phone,{width:390,height:844}],['desktop',chromium,{width:1440,height:1000}]]){
    const browser=await engine.launch();
    const page=await browser.newPage({viewport,deviceScaleFactor:2,isMobile:name==='iphone',hasTouch:name==='iphone'});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    page.on('dialog',d=>d.accept());
    const commits=[];
    await page.route('**/*',async route=>{
      const request=route.request(),u=new URL(request.url());
      if(u.hostname==='127.0.0.1'){await route.continue();return;}
      if(u.hostname==='api.github.com'){
        const p=u.pathname,m=request.method();
        let data={};
        if(p==='/user')data={login:'tester',avatar_url:''};
        else if(p==='/user/repos')data=[{full_name:'tester/demo',default_branch:'main',private:true,permissions:{push:true}}];
        else if(p.endsWith('/branches'))data=[{name:'main'},{name:'dev'}];
        else if(p.includes('/git/ref/heads/'))data={object:{sha:'base1'}};
        else if(p.includes('/git/trees/')&&m==='GET')data={tree:Object.keys(FILES).map(f=>({path:f,type:'blob',mode:'100644',sha:'s-'+f}))};
        else if(p.includes('/contents/')){const f=decodeURIComponent(p.split('/contents/')[1]);data=FILES[f]==null?null:{type:'file',encoding:'base64',content:Buffer.from(FILES[f]).toString('base64')};if(!data){await route.fulfill({status:404,json:{message:'Not Found'}});return;}}
        else if(p.includes('/git/commits/')&&m==='GET')data={tree:{sha:'tree1'}};
        else if(p.endsWith('/git/blobs'))data={sha:'blob'};
        else if(p.endsWith('/git/trees'))data={sha:'tree2'};
        else if(p.endsWith('/git/commits')){commits.push(JSON.parse(request.postData()));data={sha:'c0ffee1234567'};}
        else if(p.includes('/git/refs/heads/')&&m==='PATCH'){assert.equal(JSON.parse(request.postData()).force,false,'never force-push');data={};}
        await route.fulfill({json:data});return;
      }
      await route.fulfill({contentType:'text/javascript',body:'window.hljs={highlightElement(){}};'});
    });
    // 1. Fresh install in a plain browser: no data, greeting, no overflow.
    if(process.env.DEBUG)console.log(name,'step 1');
    await page.goto(url);
    await page.waitForSelector('.hello h1');
    assert.match(await page.locator('.hello h1').innerText(),/have a think|Good|Up late/);
    assert.equal(await page.evaluate(()=>S.token),'','Fresh install has no GitHub token');
    assert.equal(await page.evaluate(()=>Object.values(S.sessions).filter(s=>s.log.length).length),0,'Fresh install has no sessions');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No page overflow');
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-home.png')});
    // 2. The app: connect GitHub, pick a repository, run a team task.
    if(process.env.DEBUG)console.log(name,'step 2');
    await page.addInitScript(nativeMock);
    await page.goto(url);await page.waitForFunction(()=>window.studioInitialized);
    await page.evaluate(()=>openSettings());
    await page.fill('#ghTokenInput','github_pat_test_token_123');
    await page.click('#sheetBody button:text-is("Connect")');
    await page.waitForFunction(()=>S.token&&S.user?.login==='tester');
    await page.evaluate(()=>openRepoPicker());
    await page.click('#repoList .row');
    await page.click('#branchList .row >> nth=0');
    await page.waitForFunction(()=>ls('repo')==='tester/demo'&&ls('branch')==='main');
    assert.match(await page.locator('.plan-pill').innerText(),/demo · main/);
    if(process.env.DEBUG)console.log(await page.evaluate(()=>({p:S.profiles.length,mode:teamMode(),html:document.getElementById('footModel').innerHTML})));
    assert.match(await page.locator('#footModel').innerText(),/Opus 5\.5[\s\S]*\+2/);
    await page.emulateMedia({colorScheme:'dark'});
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-home-dark.png')});
    await page.click('.composer .plain');
    await page.waitForSelector('.mi');
    assert.ok(await page.locator('.mi',{hasText:'Upload or add files'}).isVisible());
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-add.png')});
    await page.evaluate(()=>closeSheet());
    await page.fill('#task','Make the send button bigger and raise the size');
    await page.evaluate(()=>{window.__slow=true;});
    await page.click('#send');
    await page.waitForSelector('.think .dots');
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-live.png')});
    await page.evaluate(()=>{window.__slow=false;});
    await page.waitForFunction(()=>!S.busy&&Object.keys(sess().staged).length===2,null,{timeout:15000});
    const sent=await page.evaluate(()=>window.__sent);
    assert.equal(sent[0].role,'manager','the manager plans first');
    assert.match(sent[0].text,/At most 2 tasks|At most 3 tasks/);
    assert.equal(sent.filter(s=>s.role==='worker').length,2,'two sub-agents ran');
    for(const s of sent.filter(s=>s.role==='worker'))assert.match(s.text,/@@@ FILE:/,'sub-agents get the edit format');
    assert.equal(await page.evaluate(()=>sess().staged['app.js']),'const size = 16;\nfunction go(){\n  return size;\n}\n');
    assert.match(await page.evaluate(()=>sess().staged['index.html']),/class="send big"/);
    assert.equal(await page.locator('.srow.done').count(),3,'manager + two tasks done');
    assert.ok(await page.locator('.think.closed').count(),'the thinking block folds when done');
    await page.click('.think-head');await page.click('.srow >> nth=1');
    assert.match(await page.locator('#changes').innerText(),/2 files changed/);
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-team.png')});
    // 3. Review and commit.
    if(process.env.DEBUG)console.log(name,'step 3');
    await page.click('#changes >> text=Review');
    await page.waitForSelector('details.file');
    assert.match(await page.locator('#commitMsg').inputValue(),/Bigger send button/);
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-review.png')});
    await page.click('text=Commit & push');
    await page.waitForFunction(()=>!Object.keys(sess().staged).length&&sess().log.some(e=>e.k==='commit'));
    assert.equal(commits.length,1);assert.deepEqual(commits[0].parents,['base1']);
    assert.equal(await page.evaluate(()=>sess().baseSHA),'c0ffee1234567');
    // 4. A quick question skips the manager.
    if(process.env.DEBUG)console.log(name,'step 4');
    await page.fill('#task','What does this app do?');
    await page.click('#send');
    await page.waitForFunction(()=>!S.busy&&sess().log.filter(e=>e.k==='reply').at(-1)?.state==='done');
    assert.equal((await page.evaluate(()=>window.__sent)).at(-1).role,'worker');
    assert.match(await page.locator('.reply').last().innerText(),/small demo app/);
    // 6. Memory learned from the reply, with Undo; voice typing; prompt fixer; question mode; a limit hands the chat over compressed.
    if(process.env.DEBUG)console.log(name,'step 6');
    assert.match(await page.evaluate(()=>S.memory),/calls the project the demo/,'memory learned from a reply');
    assert.ok(await page.locator('text=Memory updated').isVisible());
    assert.doesNotMatch(await page.locator('.reply').last().innerText(),/REMEMBER/,'memory blocks are hidden');
    await page.click('#micBtn');
    await page.waitForFunction(()=>document.getElementById('task').value==='make it blue');
    await page.click('#fixBtn');await page.click('.mi >> text=For coding');
    await page.waitForFunction(()=>/20% larger/.test(document.getElementById('task').value));
    await page.click('#fixBtn');await page.click('.mi >> text=Undo');
    assert.equal(await page.inputValue('#task'),'make it blue','undo brings the draft back');
    assert.ok((await page.evaluate(()=>window.__sent)).filter(x=>/follow-up/.test(x.text)).length===0);
    // Same container keeps the conversation (pinned, fresh:false); then it hits its limit.
    await page.fill('#task','And what about the colors?');await page.click('#send');
    await page.waitForFunction(()=>!S.busy&&sess().log.filter(e=>e.k==='reply').at(-1).state==='done'&&sess().log.filter(e=>e.k==='reply').length>=2);
    let sent2=await page.evaluate(()=>window.__sent);
    assert.ok(sent2.at(-1).profile&&/follow-up/.test(sent2.at(-1).text),'follow-ups stay in the same container');
    await page.evaluate(()=>{window.__limited=sess().thread.profile;setTeamMode('single',true);});
    await page.fill('#task','Now make the header orange');await page.click('#send');
    await page.waitForFunction(()=>!S.busy&&sess().log.some(e=>e.k==='handover'),null,{timeout:15000}).catch(async e=>{
      console.log(JSON.stringify(await page.evaluate(()=>({log:sess().log.slice(-4).map(e=>({k:e.k,state:e.state,note:e.note})),sent:window.__sent.slice(-3).map(x=>({role:x.role,profile:x.profile,m:x.moveOnLimit,t:x.text.slice(0,40)})),thread:sess().thread,busy:S.busy}))));throw e;});
    sent2=await page.evaluate(()=>window.__sent);
    const compress=sent2.findIndex(x=>/\[AI Studio · compress\]/.test(x.text));
    assert.ok(compress>0,'the conversation was compressed by a sub-agent');
    assert.match(sent2[compress+1].text,/handover[\s\S]*## Goal[\s\S]*Last messages, word for word/,'the next container gets the summary and the last messages');
    assert.match(sent2[compress+1].text,/Now make the header orange/);
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-handover.png')});
    await page.evaluate(()=>{window.__limited=null;setTeamMode('team',true);});
    await page.click('text=Undo');
    assert.doesNotMatch(await page.evaluate(()=>S.memory),/calls the project/,'undo removes the learned line');
    await page.click('#askBtn');
    await page.fill('#task','Restyle the send button');await page.click('#send');
    await page.waitForSelector('.qcard .opt');
    await page.click('.opt >> text=Orange');
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-questions.png')});
    await page.click('.qact >> text=Continue');
    await page.waitForFunction(()=>!S.busy&&sess().log.filter(e=>e.k==='user').at(-1).text.includes('Which color? → Orange'));
    await page.click('#askBtn');
    // 7. Usage per container (official for the manager, estimated for free ones), any file type, research.
    if(process.env.DEBUG)console.log(name,'step 7');
    await page.evaluate(()=>openTeam());
    await page.waitForFunction(()=>usageDB().profiles.M?.official?.session?.pct===52);
    await page.click('.ctr >> nth=0');
    await page.waitForSelector('.ctr[open] .ucard');
    assert.match(await page.locator('.ctr[open]').innerText(),/Current session[\s\S]*52% used[\s\S]*All models[\s\S]*7% used/);
    await page.click('.ctr >> nth=1');
    assert.match(await page.locator('.ctr[open] >> nth=1').innerText(),/Learning your free plan: 0 of 12/);
    assert.ok(await page.evaluate(()=>Object.values(usageDB().profiles).some(r=>r.win?.tokens>0)),'tokens were counted');
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-usage.png')});
    await page.evaluate(()=>closeSheet());
    await page.setInputFiles('#fileInput',{name:'plan.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 test')});
    assert.match(await page.locator('#atts').innerText(),/plan\.pdf/);
    await page.evaluate(()=>{ls('research','1');setTeamMode('single',true);});
    await page.fill('#task','Summarize the attached plan');
    assert.match(await page.locator('#footNote').innerText(),/tokens · about \d+% of a free session/);
    await page.click('#send');
    await page.waitForFunction(()=>!S.busy&&window.__sent.at(-1).files.includes('application/pdf'));
    assert.match((await page.evaluate(()=>window.__sent)).at(-1).text,/Research: search the web/);
    await page.evaluate(()=>{ls('research','0');setTeamMode('team',true);});
    // 5. Sessions survive a reload; settings and team sheets open; dark mode.
    if(process.env.DEBUG)console.log(name,'step 5');
    await page.waitForTimeout(500);
    await page.reload();await page.waitForFunction(()=>window.studioInitialized);
    assert.ok(await page.evaluate(()=>sess().log.some(e=>e.k==='commit')),'session restored');
    await page.evaluate(()=>openTeam());
    assert.ok(await page.locator('text=Sub-agents at once').isVisible());
    await page.evaluate(()=>closeSheet());
    await page.emulateMedia({colorScheme:'light'});
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-light.png')});
    await page.evaluate(()=>{ls('studio_theme','dark');applyTheme();});
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-dark.png')});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No page overflow');
    assert.deepEqual(errors,[],name+' browser exceptions');
    await browser.close();
  }
  console.log('Browser checks passed: team run, parallel sub-agents, edits, review, commit, quick question, restore, iPhone and desktop.');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{server.close();setTimeout(()=>process.exit(),100);});
