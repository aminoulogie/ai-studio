#!/usr/bin/env node
const {execFileSync}=require('node:child_process');
const fs=require('node:fs');
const {repoPrivatePath}=require('../assets/repo-privacy.js');
const staged=process.argv.includes('--staged');
const paths=execFileSync('git',staged?['diff','--cached','--name-only','--diff-filter=ACM','-z']:['ls-files','-z'],{encoding:'utf8'}).split('\0').filter(Boolean);
const failures=[];
const token=/(?:ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{70,}|sk-ant-[A-Za-z0-9_-]{40,})/;
for(const path of paths){
  if(repoPrivatePath(path)){failures.push(path+': private runtime data');continue;}
  const data=staged?execFileSync('git',['show',':'+path],{maxBuffer:32*1024*1024}):fs.readFileSync(path);
  if(data.includes(0))continue;
  const text=data.toString('utf8');
  if(token.test(text))failures.push(path+': credential-like content');
  try{
    const json=JSON.parse(text);
    if(json?.app==='AI Studio Context'||json?.source==='claude.ai'&&Array.isArray(json.messages)||
       json&&['cl_convs','gh_token','studio_credentials_v1'].some(k=>Object.hasOwn(json,k)))
      failures.push(path+': conversation or credential export');
  }catch{}
}
if(failures.length){
  console.error('Commit blocked. Keep chats, memory, credentials and runtime profiles on your device.\n'+failures.join('\n'));
  process.exitCode=1;
}else console.log('Repository privacy check passed.');
