const {webkit,chromium}=require('playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const root=path.join(__dirname,'..');
const server=http.createServer((req,res)=>{
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  const file=path.join(root,pathname==='/'?'index.html':pathname);
  if(!file.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
  fs.readFile(file,(err,data)=>{if(err){res.writeHead(404);res.end();return;}
    const mime={'.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.html':'text/html'}[path.extname(file)]||'text/plain';
    res.setHeader('Content-Type',mime);res.end(data);
  });
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url='http://127.0.0.1:'+server.address().port;
  fs.mkdirSync(path.join(root,'test-artifacts'),{recursive:true});
  for(const [name,engine,viewport] of [['iphone',webkit,{width:390,height:844}],['desktop',chromium,{width:1440,height:1000}]]){
    const browser=await engine.launch();const page=await browser.newPage({viewport,deviceScaleFactor:1,isMobile:name==='iphone',hasTouch:name==='iphone'});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.route('**/*',async route=>{
      const request=route.request(),u=new URL(request.url());
      if(u.hostname==='127.0.0.1'){await route.continue();return;}
      if(u.hostname==='api.github.com'){
        let data=[];
        if(u.pathname==='/user/repos')data=[{full_name:'aminoulogie/ai-studio',default_branch:'main'}];
        else if(u.pathname.endsWith('/branches'))data=[{name:'main'}];
        else if(u.pathname.includes('/git/trees/'))data={tree:[{path:'index.html',type:'blob'}]};
        else if(u.pathname.includes('/contents/'))data=[];
        await route.fulfill({json:data});return;
      }
      if(u.hostname==='openrouter.ai'){
        await route.fulfill({json:{choices:[{message:{role:'assistant',content:'Ready to help.'},finish_reason:'stop'}],usage:{prompt_tokens:2,completion_tokens:3}}});return;
      }
      await route.fulfill({contentType:'text/javascript',body:'window.hljs={highlightElement(){}};'});
    });
    await page.goto(url);
    await page.waitForSelector('.welcome h1');
    assert.ok(await page.locator('.welcome h1').innerText());
    assert.equal(await page.evaluate(()=>Object.keys(convs).length),0,'Fresh install has no saved conversations');
    assert.equal(await page.evaluate(()=>document.getElementById('modelSelect').options.length),0,'Fresh install has no configured models');
    assert.equal(await page.evaluate(()=>ghToken),'','Fresh install has no GitHub token');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No page overflow');
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-chat.png'),fullPage:true});
    if(name==='iphone')console.log('STUDIO_PREVIEW_BASE64:'+ (await page.screenshot({type:'jpeg',quality:65})).toString('base64'));
    // The drawer must receive real pointer events above its scrim.
    if(name==='iphone'){
      await page.locator('.studio-tab').last().click();
      await page.locator('#sidebar .provider-btn[data-p="openrouter"]').click();
      assert.equal(await page.evaluate(()=>curProvider),'openrouter');
      await page.locator('#sidebar .nav-item').filter({hasText:'Code'}).click();
      await page.waitForFunction(()=>activeTab==='code'&&!document.getElementById('overlay').classList.contains('show'));
      await page.locator('.studio-tab[data-tab="chat"]').click();
    }
    await page.evaluate(()=>{openAppearance();});
    await page.locator('.appearance-card').nth(1).click();
    assert.equal(await page.evaluate(()=>localStorage.getItem('studio_art')),'lagoon');
    await page.evaluate(()=>closeSheet());
    await page.evaluate(()=>{
      localStorage.setItem('ai_provider','openrouter');localStorage.setItem('ai_key_openrouter','test-key');
      localStorage.setItem('ai_models_openrouter',JSON.stringify([{v:'test-model',l:'Test model'}]));localStorage.setItem('ai_model_openrouter','test-model');
      localStorage.setItem('gh_token','test-gh');localStorage.setItem('code_repo','aminoulogie/ai-studio');
    });
    await page.reload();await page.locator('.studio-tab[data-tab="code"]').click();
    await page.waitForFunction(()=>document.getElementById('codeBranch').value==='main');
    for(const id of ['codeMicBtn','codeAskBtn','codeOptBtn','codeRunBtn'])assert.ok(await page.locator('#'+id).isVisible());
    assert.ok(await page.evaluate(()=>document.getElementById('codeTask').getBoundingClientRect().height<=120),'Code input must stay compact');
    assert.equal(await page.locator('#codePermissionsBtn').isVisible(),false,'Workspace options start folded');
    await page.locator('#codeHeadToggle').click();
    await page.locator('#codePermissionsBtn').click();
    assert.ok(await page.locator('#codeAutoCommit').isVisible());
    await page.evaluate(()=>closeSheet());
    await page.locator('#codeTask').fill('Tell me about this project');
    await page.locator('#codeRunBtn').click();
    await page.waitForFunction(()=>!codeState.busy&&codeState.msgs.some(m=>m.content==='Ready to help.'));
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-code.png'),fullPage:true});
    await page.evaluate(async()=>{
      codeState.staged['demo.txt']='pending work';codeState.orig['demo.txt']='old';
      await saveCodeSession();
    });
    await page.reload();await page.locator('.studio-tab[data-tab="code"]').click();
    await page.waitForFunction(()=>codeState.staged['demo.txt']==='pending work');
    assert.equal(await page.evaluate(()=>codeState.orig['demo.txt']),'old');
    await page.locator('#codeOptBtn').click();
    assert.ok(await page.locator('#optMenu').isVisible());
    await page.locator('#codeTask').fill('Keep this draft');
    await page.evaluate(()=>{codeState.controller=new AbortController();codeState.busy=true;codeRun();});
    assert.equal(await page.evaluate(()=>codeState.controller.signal.aborted),true);
    await page.evaluate(()=>{codeState.busy=false;setStudioTheme('dark');});
    await page.screenshot({path:path.join(root,'test-artifacts',name+'-dark.png'),fullPage:true});
    assert.deepEqual(errors,[],name+' browser exceptions');
    await browser.close();
  }
  console.log('WebKit iPhone and Chromium desktop smoke tests passed.');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>server.close());
