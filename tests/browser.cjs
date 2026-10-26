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
    return 'This project is a small demo app.';
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
      case 'claudeSetManager':profiles.forEach(p=>p.manager=p.id===o.profile);return true;
      case 'claudeSend':{
        window.__sent.push({role:o.role,text:o.text});
        const who=o.role==='manager'?profiles[0]:profiles[1+(window.__sent.filter(s=>s.role!=='manager').length-1)%2];
        const text=reply(o),base={id:o.id,account:who.name,profile:who.id,role:o.role};
        setTimeout(()=>{
          if(o.role==='manager')emit({...base,state:'awaiting',note:'Press Send in Opus account'});
          emit({...base,state:'streaming',text:text.slice(0,20)});
          setTimeout(()=>emit({...base,state:'done',text}),60);
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
    assert.match(await page.locator('.hello h1').innerText(),/Good|Up late/);
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
    assert.match(await page.locator('#repoChipText').innerText(),/demo · main/);
    assert.match(await page.locator('#teamChipText').innerText(),/Team · 3/);
    await page.fill('#task','Make the send button bigger and raise the size');
    await page.click('#send');
    await page.waitForFunction(()=>!S.busy&&Object.keys(sess().staged).length===2,null,{timeout:15000});
    const sent=await page.evaluate(()=>window.__sent);
    assert.equal(sent[0].role,'manager','the manager plans first');
    assert.match(sent[0].text,/At most 2 tasks|At most 3 tasks/);
    assert.equal(sent.filter(s=>s.role==='worker').length,2,'two sub-agents ran');
    for(const s of sent.filter(s=>s.role==='worker'))assert.match(s.text,/@@@ FILE:/,'sub-agents get the edit format');
    assert.equal(await page.evaluate(()=>sess().staged['app.js']),'const size = 16;\nfunction go(){\n  return size;\n}\n');
    assert.match(await page.evaluate(()=>sess().staged['index.html']),/class="send big"/);
    assert.equal(await page.locator('.step.done').count(),3,'manager + two tasks done');
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
    await page.waitForFunction(()=>!S.busy&&sess().log.at(-1).k==='reply'&&sess().log.at(-1).state==='done');
    assert.equal((await page.evaluate(()=>window.__sent)).at(-1).role,'worker');
    assert.match(await page.locator('.reply').last().innerText(),/small demo app/);
    // 5. Sessions survive a reload; settings and team sheets open; dark mode.
    if(process.env.DEBUG)console.log(name,'step 5');
    await page.waitForTimeout(500);
    await page.reload();await page.waitForFunction(()=>window.studioInitialized);
    assert.ok(await page.evaluate(()=>sess().log.some(e=>e.k==='commit')),'session restored');
    await page.evaluate(()=>openTeam());
    assert.ok(await page.locator('text=Sub-agents at once').isVisible());
    await page.evaluate(()=>closeSheet());
    await page.evaluate(()=>{ls('studio_theme','dark');applyTheme();});
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-dark.png')});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No page overflow');
    assert.deepEqual(errors,[],name+' browser exceptions');
    await browser.close();
  }
  console.log('Browser checks passed: team run, parallel sub-agents, edits, review, commit, quick question, restore, iPhone and desktop.');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{server.close();setTimeout(()=>process.exit(),100);});
