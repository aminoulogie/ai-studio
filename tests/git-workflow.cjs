const fs=require('node:fs'),assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const {assertRepoPublishable}=require('../assets/repo-privacy.js');
const block=html.slice(html.indexOf('function codeAutoCommitKey()'),html.indexOf('/* ===================== STATE'));
async function scenario({conflict=false,race=false,automatic=false,enabled=true}={}){
  const state={repo:'owner/repo',branch:'feature/test',staged:{'run.sh':'new content'},orig:{'run.sh':'old content'},baseSHA:'old',busy:false};
  const calls=[],logs=[];let confirmations=0;
  const ghFetch=async(path,opts={})=>{
    calls.push({path,opts});
    if(path.includes('/ref/heads/'))return {object:{sha:'head'}};
    if(path.endsWith('/commits/head'))return {tree:{sha:'head-tree'}};
    if(path.includes('/trees/')&&!opts.method)return {tree:[{path:'run.sh',sha:path.includes('/trees/old')?'original':conflict?'remote-edit':'original',mode:'100755',type:'blob'}]};
    if(path.endsWith('/blobs'))return {sha:'blob'};
    if(path.endsWith('/trees'))return {sha:'new-tree'};
    if(path.endsWith('/commits'))return {sha:'commit'};
    if(path.includes('/refs/heads/')){if(race)throw new Error('Non-fast-forward');return {};}
    throw new Error('Unexpected '+path);
  };
  const deps={assertRepoPublishable,localCommitSecrets:()=>[],codeState:state,ghFetch,toast:()=>{},confirm:()=>{confirmations++;return true;},
    document:{getElementById:id=>id==='codeMsg'?{value:'Save task'}:{}},
    ls:()=>enabled?'1':'0',saveCodeSession:async()=>{},renderCodeChanges:()=>{},codeLog:(kind,message)=>logs.push(message),esc:x=>x};
  const api=new Function(...Object.keys(deps),block+';return {codeCommit};')(...Object.values(deps));
  await api.codeCommit(automatic?{automatic:true}:{});
  return {state,calls,logs,confirmations};
}
(async()=>{
  let s=await scenario();
  assert.deepEqual(s.state.staged,{});
  assert.deepEqual(s.state.orig,{},'Clear stale original text after advancing the base');
  assert.equal(s.state.baseSHA,'commit');
  assert.equal(s.confirmations,1);
  const tree=JSON.parse(s.calls.find(c=>c.path.endsWith('/trees')&&c.opts.method==='POST').opts.body);
  assert.equal(tree.tree[0].mode,'100755','Preserve executable mode');
  const patch=JSON.parse(s.calls.find(c=>c.opts.method==='PATCH').opts.body);
  assert.equal(patch.force,false);
  assert.ok(s.calls.find(c=>c.path.endsWith('/ref/heads/feature%2Ftest')));
  s=await scenario({conflict:true});
  assert.ok(s.state.staged['run.sh']);
  assert.ok(s.logs.some(x=>x.includes('conflict')));
  assert.equal(s.calls.filter(c=>c.opts.method==='POST').length,0);
  s=await scenario({race:true});assert.ok(s.state.staged['run.sh']);assert.equal(s.state.committing,false);
  s=await scenario({automatic:true});assert.equal(s.confirmations,0);assert.deepEqual(s.state.staged,{});
  s=await scenario({automatic:true,enabled:false});assert.equal(s.calls.length,0);assert.ok(s.state.staged['run.sh']);
  console.log('Git workflow checks passed: conflicts, races, file modes, tracking and opt-in automatic commits.');
})().catch(e=>{console.error(e);process.exitCode=1;});
