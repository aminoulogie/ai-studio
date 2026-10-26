/* GitHub through its REST API: reading a pinned commit and committing staged edits without force. */
(function(root){
'use strict';
function makeGitHub(getToken,fetchImpl){
  const doFetch=fetchImpl||((...a)=>root.fetch(...a));
  async function gh(path,opts={}){
    const headers={'Authorization':'Bearer '+getToken(),'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28',
      ...(opts.body?{'Content-Type':'application/json'}:{}),...(opts.headers||{})};
    const res=await doFetch('https://api.github.com'+path,{...opts,headers,credentials:'omit',cache:'no-store'});
    if(!res.ok){
      const e=await res.json().catch(()=>({})),details=e.message||'GitHub '+res.status;
      const help=res.status===401?'Sign in again: the GitHub token expired or was revoked.':
        res.status===403?'Check the token has Contents: read and write for this repository, organization SSO, branch rules and API rate limits.':
        res.status===404?'Check repository access and the selected branch.':
        [409,422].includes(res.status)?'The branch changed or branch rules rejected the commit. Your edits are kept.':'';
      throw Object.assign(new Error(details+(help?' '+help:'')),{status:res.status});
    }
    return res.status===204?null:res.json();
  }
  const enc=p=>p.split('/').map(encodeURIComponent).join('/');
  async function headSHA(repo,branch){return (await gh('/repos/'+repo+'/git/ref/heads/'+encodeURIComponent(branch))).object.sha;}
  async function listFiles(repo,sha){
    const t=await gh('/repos/'+repo+'/git/trees/'+encodeURIComponent(sha)+'?recursive=1');
    return t.tree.filter(x=>x.type==='blob').map(x=>x.path);
  }
  /** File text at a commit, or null when it does not exist. */
  async function readFile(repo,path,ref){
    try{
      const file=await gh('/repos/'+repo+'/contents/'+enc(path)+'?ref='+encodeURIComponent(ref));
      if(Array.isArray(file)||file.type!=='file')throw new Error(path+' is not a file.');
      if(file.encoding==='base64'&&file.content)return new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(file.content.replace(/\s/g,'')),c=>c.charCodeAt(0)));
      // Files over 1 MB come without content; fetch the blob instead.
      const blob=await gh('/repos/'+repo+'/git/blobs/'+file.sha);
      return new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(blob.content.replace(/\s/g,'')),c=>c.charCodeAt(0)));
    }catch(e){if(e.status===404)return null;if(e instanceof TypeError&&/decode/i.test(e.message))throw new Error(path+' is not a text file.');throw e;}
  }
  /**
   * Commits {path: text} on top of the branch. Refuses when GitHub changed any of these files since `baseSHA`
   * (or since `orig` text for old sessions), keeps file modes, and never force-pushes.
   */
  async function commit({repo,branch,files,orig={},baseSHA,message}){
    const R='/repos/'+repo+'/git',paths=Object.keys(files);
    const head=await headSHA(repo,branch),base=await gh(R+'/commits/'+head);
    const remote=await gh(R+'/trees/'+base.tree.sha+'?recursive=1');
    if(remote.truncated)throw new Error('The repository is too large to check safely. Commit with Git on a computer.');
    const entries=new Map(remote.tree.map(x=>[x.path,x]));
    if(baseSHA&&baseSHA!==head){
      const original=await gh(R+'/trees/'+baseSHA+'?recursive=1');
      if(original.truncated)throw new Error('The original tree is too large to check safely.');
      const old=new Map(original.tree.map(x=>[x.path,x]));
      for(const f of paths)if(entries.get(f)?.sha!==old.get(f)?.sha||entries.get(f)?.mode!==old.get(f)?.mode)
        throw new Error('Someone changed '+f+' on GitHub since this session started. Your edits are kept: start a new session to pick up the latest code.');
    }else if(!baseSHA){
      for(const f of paths)if(((await readFile(repo,f,head))??'')!==(orig[f]??''))throw new Error('Someone changed '+f+' on GitHub. Your edits are kept.');
    }
    const tree=[];
    for(const f of paths){
      const old=entries.get(f);
      if(old&&(!['100644','100755'].includes(old.mode)||old.type!=='blob'))throw new Error('Unsupported file type: '+f);
      const blob=await gh(R+'/blobs',{method:'POST',body:JSON.stringify({content:files[f],encoding:'utf-8'})});
      tree.push({path:f,mode:old?.mode||'100644',type:'blob',sha:blob.sha});
    }
    const t=await gh(R+'/trees',{method:'POST',body:JSON.stringify({base_tree:base.tree.sha,tree})});
    const c=await gh(R+'/commits',{method:'POST',body:JSON.stringify({message,tree:t.sha,parents:[head]})});
    // A push that happened meanwhile makes this non-fast-forward, and GitHub rejects it. Never force.
    await gh(R+'/refs/heads/'+encodeURIComponent(branch),{method:'PATCH',body:JSON.stringify({sha:c.sha,force:false})});
    return c.sha;
  }
  return {gh,headSHA,listFiles,readFile,commit};
}
root.makeGitHub=makeGitHub;
if(typeof module!=='undefined')module.exports={makeGitHub};
})(typeof globalThis!=='undefined'?globalThis:this);
