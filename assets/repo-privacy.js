/* Repository publishing is for app source only. Session state stays in local app storage. */
(function(root){
'use strict';
function repoPrivatePath(path){
  if(typeof path!=='string'||!path||path.split('/').some(p=>p==='..'))return true;
  if(/(^|\/)\.env(?:\.|$)/i.test(path)&&!/(?:example|sample|template)$/.test(path))return true;
  return /(^|\/)(?:\.git|\.studio|\.aistudio|webkit|indexeddb|localstorage|application support|memory|memories|sessions?|conversations?|chat[-_]history|snapshots?|credentials?|tokens?|profiles?|exports?|backups?)(?:[.\/_-]|$)/i.test(path)||
    /(?:^|\/)(?:ai_models[^/]*|models\.json|cl_convs[^/]*|gh_token[^/]*)$/i.test(path)||
    /\.(?:aistudio|ipa|sqlite3?|db|pem|key|mobileprovision)$/i.test(path);
}
function assertRepoPublishable(files,{secrets=[],messages=[]}={}){
  const privateText=messages.filter(m=>m.role==='user'&&typeof m.content==='string'&&m.content.length>=40).map(m=>m.content);
  for(const [path,content] of Object.entries(files)){
    if(repoPrivatePath(path))throw new Error('Private state cannot be published to GitHub: '+path);
    if(typeof content!=='string')throw new Error('Only text source files can be committed.');
    if(secrets.some(secret=>secret&&secret.length>=8&&content.includes(secret)))throw new Error('A local credential was found in '+path+'. Remove it before committing.');
    try{
      const data=JSON.parse(content);
      if(data&&typeof data==='object'&&(data.app==='AI Studio Context'||data.source==='claude.ai'&&Array.isArray(data.messages)||['cl_convs','gh_token','studio_credentials_v1'].some(k=>Object.prototype.hasOwnProperty.call(data,k))))throw new Error('Private session export');
    }catch(e){if(e.message==='Private session export')throw new Error('A private session export cannot be published: '+path);}
    if(privateText.some(text=>content.includes(text)))throw new Error('Conversation text was found in '+path+'. Keep chat history on this device.');
  }
}
root.repoPrivatePath=repoPrivatePath;root.assertRepoPublishable=assertRepoPublishable;
if(typeof module!=='undefined')module.exports={repoPrivatePath,assertRepoPublishable};
})(typeof globalThis!=='undefined'?globalThis:this);
