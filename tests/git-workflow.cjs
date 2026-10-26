// Committing through the GitHub API: conflicts stop the commit, file modes are kept, never a force push.
const assert=require('node:assert/strict');
const {makeGitHub}=require('../assets/github.js');
function fakeGitHub({conflict=false,race=false,head='head'}={}){
  const calls=[];
  const fetch=async(url,opts={})=>{
    const path=url.replace('https://api.github.com',''),method=opts.method||'GET';
    calls.push({path,method,body:opts.body&&JSON.parse(opts.body),auth:opts.headers.Authorization});
    const ok=data=>({ok:true,status:200,json:async()=>data});
    if(path.includes('/git/ref/heads/'))return ok({object:{sha:head}});
    if(path.includes('/git/commits/')&&method==='GET')return ok({tree:{sha:'head-tree'}});
    if(path.includes('/git/trees/')&&method==='GET')return ok({tree:[{path:'run.sh',type:'blob',mode:'100755',sha:path.includes('/trees/base')?'original':conflict?'remote-edit':'original'}]});
    if(path.endsWith('/git/blobs'))return ok({sha:'blob'});
    if(path.endsWith('/git/trees'))return ok({sha:'new-tree'});
    if(path.endsWith('/git/commits'))return ok({sha:'commit'});
    if(path.includes('/git/refs/heads/')){if(race)return {ok:false,status:422,json:async()=>({message:'Update is not a fast forward'})};return ok({});}
    if(path.includes('/contents/'))return {ok:false,status:404,json:async()=>({message:'Not Found'})};
    throw new Error('Unexpected '+path);
  };
  return {gh:makeGitHub(()=>'secret-token',fetch),calls};
}
(async()=>{
  const job={repo:'owner/repo',branch:'feature/test',files:{'run.sh':'new content'},orig:{'run.sh':'old content'},baseSHA:'base',message:'Save task'};
  let f=fakeGitHub();
  assert.equal(await f.gh.commit(job),'commit');
  assert.ok(f.calls.every(c=>c.auth==='Bearer secret-token'));
  assert.ok(f.calls.some(c=>c.path.endsWith('/ref/heads/feature%2Ftest')),'branch names are encoded');
  assert.equal(f.calls.find(c=>c.path.endsWith('/git/trees')&&c.method==='POST').body.tree[0].mode,'100755','executable mode kept');
  assert.deepEqual(f.calls.find(c=>c.path.endsWith('/git/commits')&&c.method==='POST').body.parents,['head']);
  assert.equal(f.calls.find(c=>c.method==='PATCH').body.force,false,'never force-push');
  f=fakeGitHub({conflict:true});
  await assert.rejects(()=>f.gh.commit(job),/changed run\.sh/);
  assert.equal(f.calls.filter(c=>c.method==='POST').length,0,'nothing written when GitHub changed the file');
  f=fakeGitHub({race:true});
  await assert.rejects(()=>f.gh.commit(job),/fast forward[\s\S]*edits are kept/);
  f=fakeGitHub({head:'base'});
  assert.equal(await f.gh.commit(job),'commit','no remote change since the session started');
  assert.equal(await fakeGitHub().gh.readFile('owner/repo','missing.txt','head'),null,'a missing file reads as null');
  console.log('Git workflow checks passed: conflicts, races, file modes, encoded branches, no force push.');
})().catch(e=>{console.error(e);process.exitCode=1;});
