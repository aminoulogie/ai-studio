/* Code request transport. Browser and iOS share the same limits and retry rules. */
const CODE_NATIVE_HOSTS=new Set(['api.openai.com','apikey.vnaipro.app','openrouter.ai','api.groq.com','api.cerebras.ai','router.huggingface.co','api.sambanova.ai','models.github.ai','api.cohere.ai','api.mistral.ai','ai-gateway.vercel.sh','text.pollinations.ai']);
function codeMessagesForRequest(messages,limit=64000){
  if(messages.length<2)return messages;
  const groups=[];
  for(const original of messages.slice(1)){
    const m={...original};
    // Old tool results can be re-read from the repository; preserve recent exact snippets.
    if(m.role==='tool'&&typeof m.content==='string'&&groups.length){
      m.content=m.content.length>12000?m.content.slice(0,12000)+'\n[Truncated; read a smaller line range.]':m.content;
    }
    if(m.role!=='tool')groups.push([m]);else if(groups.length)groups.at(-1).push(m);
  }
  const selected=[];let size=JSON.stringify(messages[0]).length;
  for(let i=groups.length-1;i>=0;i--){
    const n=JSON.stringify(groups[i]).length;
    if(selected.length&&size+n>limit)break;
    selected.unshift(groups[i]);size+=n;
  }
  const removed=groups.length-selected.length;
  const system={...messages[0]};
  if(removed)system.content+='\nOlder conversation steps were omitted to keep this request small. Pending edits are preserved. Re-read files when exact text is needed.';
  // Keep the original goal even after dropping old tool cycles.
  const goal=messages.find(m=>m.role==='user');
  const flat=selected.flat();
  if(goal&&!flat.some(m=>m.role==='user'&&m.content===goal.content))flat.unshift({...goal,content:typeof goal.content==='string'?goal.content.slice(0,12000):goal.content.filter(c=>c.type==='text').map(c=>c.text).join('\n').slice(0,12000)});
  return [system,...flat];
}
function codeResponsesInput(messages){
  return messages.filter(m=>m.role!=='system').flatMap(m=>{
    if(m.role==='tool')return [{type:'function_call_output',call_id:m.tool_call_id,output:m.content}];
    const out=[];
    if(m.content){
      const content=Array.isArray(m.content)?m.content.map(c=>c.type==='image_url'?{type:'input_image',image_url:c.image_url.url}:{type:'input_text',text:c.text}):m.content;
      out.push({role:m.role,content});
    }
    for(const c of m.tool_calls||[])out.push({type:'function_call',call_id:c.id,name:c.function.name,arguments:c.function.arguments});
    return out;
  });
}
function codeRetryable(e){
  return e.name!=='AbortError'&&(e.name==='TypeError'||e.name==='TimeoutError'||[408,429,500,502,503,504].includes(e.status)||/network|load failed|failed to fetch|connection|incomplete stream/i.test(e.message||''));
}
function codeDelay(ms,signal){
  return new Promise((resolve,reject)=>{
    if(signal.aborted){reject(new DOMException('Stopped','AbortError'));return;}
    const stop=()=>{clearTimeout(timer);reject(new DOMException('Stopped','AbortError'));};
    const timer=setTimeout(()=>{signal.removeEventListener('abort',stop);resolve();},ms);
    signal.addEventListener('abort',stop,{once:true});
  });
}
async function codeRequest(url,body,key,signal){
  const id='code-'+Date.now()+'-'+Math.random().toString(36).slice(2);
  const useNative=!!window.webkit?.messageHandlers?.native&&CODE_NATIVE_HOSTS.has(new URL(url).hostname);
  if(useNative){
    if(signal.aborted)throw new DOMException('Stopped','AbortError');
    const stop=()=>{native({op:'cancelRequest',id}).catch(()=>{});};
    signal.addEventListener('abort',stop,{once:true});
    try{
      const reply=await native({op:'aiRequest',id,url,body:JSON.stringify({...body,stream:false}),key});
      if(signal.aborted)throw new DOMException('Stopped','AbortError');
      const result=typeof reply==='string'?JSON.parse(reply):reply;
      if(result.status===0)throw Object.assign(new Error(result.error||'Native connection failed'),{name:'TypeError'});
      let j;try{j=JSON.parse(result.body);}catch{throw new Error('The provider returned an unreadable response.');}
      if(result.status<200||result.status>=300)throw Object.assign(new Error(j.error?.message||'Provider HTTP '+result.status),{status:result.status});
      return j;
    }finally{signal.removeEventListener('abort',stop);}
  }
  const headers={'Content-Type':'application/json',...(key?{Authorization:'Bearer '+key}:{})};
  const response=await fetch(url,{method:'POST',headers,body:JSON.stringify(body),signal});
  if(!response.ok){const j=await response.json().catch(()=>({}));throw Object.assign(new Error(j.error?.message||'Provider HTTP '+response.status),{status:response.status});}
  if(body.stream&&response.headers.get('content-type')?.includes('text/event-stream'))return readToolStream(response,{set textContent(value){codeStatus(value,'working');}});
  return response.json();
}
async function codeModelStep(prov,key,model,messages,signal){
  const input=codeMessagesForRequest(messages,typeof codeLean==='function'&&codeLean()?24000:64000);
  const useResp=prov==='openai';
  const tools=codeInterview?[]:CODE_TOOLS;
  const url=useResp?'https://api.openai.com/v1/responses':chatURL(prov);
  const body=useResp?{
    model,instructions:input[0].content,input:codeResponsesInput(input),store:false,
    tools:tools.map(t=>({type:'function',...t.function})),max_output_tokens:8192
  }:{model,messages:input,tools,max_tokens:8192,stream:true};
  // Retry only the model request. No edits have run for this response yet.
  for(let attempt=0;attempt<2;attempt++){
    const ctrl=new AbortController();let timedOut=false;
    const stop=()=>ctrl.abort();
    signal.addEventListener('abort',stop,{once:true});
    if(signal.aborted)ctrl.abort();
    const timer=setTimeout(()=>{timedOut=true;ctrl.abort();},180000);
    try{
      if(signal.aborted)throw new DOMException('Stopped','AbortError');
      let j;
      if(prov==='puter'){
        await ensurePuter();
        j=await Promise.race([
          puter.ai.chat(input,{model,tools}),
          new Promise((_,reject)=>{
            const abort=()=>reject(new DOMException('Stopped','AbortError'));
            if(ctrl.signal.aborted)abort();else ctrl.signal.addEventListener('abort',abort,{once:true});
          })
        ]);
        let m=j?.message||j||{}, content=m.content, calls=[...(m.tool_calls||[])];
        if(Array.isArray(content)){
          content.filter(b=>b.type==='tool_use').forEach(b=>calls.push({id:b.id,function:{name:b.name,arguments:b.input}}));
          content=content.filter(b=>b.type==='text').map(b=>b.text).join('');
        }
        return {content:typeof content==='string'?content:'',tool_calls:calls.map((c,i)=>({id:c.id||'call_'+i,type:'function',function:{name:c.function.name,arguments:typeof c.function.arguments==='string'?c.function.arguments:JSON.stringify(c.function.arguments||{})}}))};
      }
      j=await codeRequest(url,body,key,ctrl.signal);
      if(signal.aborted)throw new DOMException('Stopped','AbortError');
      if(j.error)throw Object.assign(new Error(j.error.message||'Provider error'),{status:j.error.code});
      if(j.usage)lastUsage={in:j.usage.prompt_tokens??j.usage.input_tokens??0,out:j.usage.completion_tokens??j.usage.output_tokens??0};
      if(useResp){
        if(j.status&&j.status!=='completed')throw new Error('The provider stopped before finishing ('+(j.incomplete_details?.reason||j.status)+'). Try a smaller task.');
        return {content:(j.output||[]).filter(o=>o.type==='message').flatMap(o=>o.content||[]).map(c=>c.text||'').join(''),tool_calls:(j.output||[]).filter(o=>o.type==='function_call').map(o=>({id:o.call_id,type:'function',function:{name:o.name,arguments:o.arguments}}))};
      }
      if(j.choices?.[0]?.finish_reason==='length')throw new Error('The answer reached the output limit. Ask for a smaller edit.');
      const m=j.choices?.[0]?.message;
      if(!m)throw new Error('The provider returned no answer.');
      return m;
    }catch(e){
      if(timedOut&&!signal.aborted)e=Object.assign(new Error('The provider did not finish within 3 minutes.'),{name:'TimeoutError'});
      if(signal.aborted)throw new DOMException('Stopped','AbortError');
      if(attempt||!codeRetryable(e))throw e;
      codeStatus('Reconnecting · one retry','working');
      await codeDelay(1500,signal);
    }finally{clearTimeout(timer);signal.removeEventListener('abort',stop);}
  }
}
async function readToolStream(res,el){
  const reader=res.body.getReader(),dec=new TextDecoder();
  let buffer='',content='',usage=null,finished=false,finishReason=null;
  const calls=[];
  function consume(line){
    if(!line.startsWith('data:'))return;
    const raw=line.slice(5).trim();if(raw==='[DONE]'){finished=true;return;}if(!raw)return;
    let ev;try{ev=JSON.parse(raw);}catch{throw new Error('The provider sent a malformed stream.');}
    if(ev.error)throw Object.assign(new Error(ev.error.message||'Provider stream error'),{status:ev.error.code});
    if(ev.usage)usage=ev.usage;
    const choice=ev.choices?.[0];if(!choice)return;
    if(choice.finish_reason){finished=true;finishReason=choice.finish_reason;}
    const d=choice.delta||{};
    if(d.content)content+=d.content;
    for(const tc of d.tool_calls||[]){
      const i=tc.index??0;
      const c=calls[i]||(calls[i]={id:'',type:'function',function:{name:'',arguments:''}});
      if(tc.id)c.id=tc.id;
      if(tc.function?.name)c.function.name+=tc.function.name;
      if(tc.function?.arguments)c.function.arguments+=tc.function.arguments;
    }
    el.textContent=calls.length?'Preparing changes…':'Writing response…';
  }
  try{
    while(true){
      const {done,value}=await reader.read();
      buffer+=done?dec.decode():dec.decode(value,{stream:true});
      const lines=buffer.split(/\r?\n/);buffer=lines.pop();
      lines.forEach(consume);
      if(done){if(buffer.trim())consume(buffer);break;}
    }
    if(!finished)throw new Error('Incomplete stream: the provider disconnected before finishing.');
    for(const c of calls.filter(Boolean)){
      if(!c.function.name||!c.id)throw new Error('Incomplete stream: missing tool details.');
      try{JSON.parse(c.function.arguments||'{}');}catch{throw new Error('Incomplete stream: unfinished edit arguments.');}
    }
    return {choices:[{finish_reason:finishReason,message:{role:'assistant',content,tool_calls:calls.filter(Boolean)}}],usage};
  }catch(e){try{await reader.cancel();}catch{}throw e;}
  finally{reader.releaseLock();}
}
let codeDBPromise;
function codeDB(){
  if(!codeDBPromise)codeDBPromise=new Promise((resolve,reject)=>{
    const req=indexedDB.open('ai-studio-code',1);
    req.onupgradeneeded=()=>req.result.createObjectStore('sessions');
    req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
  });
  return codeDBPromise;
}
async function saveCodeSession(){
  if(!codeState.repo||!codeState.branch)return;
  const key=codeState.repo+'@'+codeState.branch;
  const snapshot={repo:codeState.repo,branch:codeState.branch,staged:{...codeState.staged},orig:{...codeState.orig},msgs:codeState.msgs,baseSHA:codeState.baseSHA,claudeResult:codeState.claudeResult,interview:codeInterview,ts:Date.now()};
  try{
    const db=await codeDB();
    await new Promise((resolve,reject)=>{
      const tx=db.transaction('sessions','readwrite');tx.objectStore('sessions').put(snapshot,key);
      tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
    });
  }catch(e){codeStatus('Could not save recovery copy · keep this window open','warning');}
}
async function restoreCodeSession(){
  const key=codeState.repo+'@'+codeState.branch;
  try{
    const db=await codeDB();
    const saved=await new Promise((resolve,reject)=>{
      const req=db.transaction('sessions').objectStore('sessions').get(key);req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
    });
    if(!saved||key!==codeState.repo+'@'+codeState.branch||codeState.busy)return;
    Object.assign(codeState,{staged:saved.staged||{},orig:saved.orig||{},msgs:saved.msgs||[],baseSHA:saved.baseSHA||null,claudeResult:saved.claudeResult||null});
    codeInterview=!!saved.interview;document.getElementById('codeAskBtn').classList.toggle('lit',codeInterview);
    if(codeState.msgs.length)codeLog('step','Your last session is restored. Pending changes are ready to review; send a message to continue.');
    renderCodeChanges();
    if(saved.claudeResult&&typeof showSavedClaudeResult==='function')showSavedClaudeResult(saved.claudeResult);
  }catch{}
}
function codeStatus(text,state='idle'){
  const el=document.getElementById('codeStatus');if(!el)return;
  el.dataset.state=state;el.querySelector('span').textContent=text;
}
function codeErrorMessage(e){
  if(e.name==='AbortError')return 'Stopped. Your completed changes are saved on this device.';
  if(e.status===401||e.status===403)return 'The provider rejected your API key or model access. Check the key and selected model in Settings.';
  if(e.status===402||e.status===429)return 'This provider has reached a usage or rate limit. Wait, or choose another provider at the top.';
  if(e.name==='TimeoutError')return e.message+' Your completed changes are saved; try a smaller task or another model.';
  if(codeRetryable(e))return 'The provider connection failed after one retry. This can be a network, provider, or browser-access problem. Your completed changes are saved. Try another provider or resume below.';
  return e.message||'The request failed. Your completed changes are saved.';
}
