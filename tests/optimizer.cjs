// Run from the repository root: node tests/optimizer.cjs
const fs=require('node:fs');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
new Function(html.match(/<script>([\s\S]*?)<\/script>/)[1]);

async function testOptimizer(html) {
  const assert=(value,message)=>{if(!value)throw new Error(message);};
  const block=html.slice(html.indexOf("let optTarget="),html.indexOf("/* ===================== INTERVIEW MODE"));
  const adapters=["callPuter","callAnthropic","callGemini","callResponses","callOpenAICompat"];
  const entries={}, calls=[], elements={};
  const ls=(key,value)=>value===undefined?entries[key]:(entries[key]=value);
  const node=id=>elements[id]||(elements[id]={value:'',innerHTML:'',style:{},classList:{add(){},remove(){}},appendChild(){},trim(){}});
  const providers={openrouter:{name:'OpenRouter',defaultModel:'paid'},pollinations:{name:'Pollinations'},puter:{name:'Puter',defaultModel:'puter-model'},groq:{name:'Groq',defaultModel:'llama'}};
  let allowed=true, fail=true, empty=false, draftChange=false;
  const adapter=async(p,key,model)=>{
    calls.push({p,model});if(draftChange)node('codeTask').value='new draft';
    if(empty)return '';if(fail&&p==='groq')throw new Error('quota exhausted');return 'improved';
  };
  const injected={
    activeTab:'code',document:{getElementById:node,createElement:()=>node('bubble')},AbortController:class{constructor(){this.signal={};}abort(){this.signal.aborted=true;}},
    setTimeout:()=>1,clearTimeout:()=>{},ls,PROVIDERS:providers,provReady:p=>!!ls('ai_key_'+p),
    privacyAllows:()=>allowed,curProvider:'groq',curModel:()=> 'selected-model',recordUsage(){},toast(){},showErr(){},codeLog(){},
    usesResponses:()=>false,esc:v=>v,autoResize(){},updateCtx(){},
    OPT_GOALS:{code:'Coding request'},callPuter:async()=> 'puter result',callAnthropic:adapter,callGemini:adapter,callResponses:adapter,callOpenAICompat:adapter
  };
  const api=new Function(...Object.keys(injected),block+'\nreturn {optimizerCandidates,optimizerComplete,optimizePrompt,undoOptimize,setTarget:t=>optTarget=t};')(...Object.values(injected));
  assert(api.optimizerCandidates().map(x=>x.p).join(',')==='pollinations','Default route must not consume Puter credits');
  ls('ai_key_openrouter','test-key');
  assert(api.optimizerCandidates()[0].model==='openrouter/free','Automatic OpenRouter route must be free');
  ls('ai_opt_provider','groq');ls('ai_key_groq','test-key');ls('ai_opt_model_groq','my-model');
  assert(api.optimizerCandidates()[0].model==='my-model','Saved optimizer model used');
  assert(await api.optimizerComplete('test')==='improved','Quota failure falls back');
  assert(calls.map(x=>x.p).join(',')==='groq,openrouter','Try chosen provider then free route');
  calls.length=0;ls('ai_opt_fallback','0');
  let failed=false;try{await api.optimizerComplete('test');}catch{failed=true;}
  assert(failed&&calls.length===1,'Disabled fallback must stop after selected provider');
  allowed=false;calls.length=0;failed=false;try{await api.optimizerComplete('test');}catch{failed=true;}
  assert(failed&&calls.length===0,'Private mode must block every disallowed request');
  allowed=true;fail=false;empty=true;failed=false;try{await api.optimizerComplete('test');}catch{failed=true;}
  assert(failed,'Empty result is a failure');
  empty=false;api.setTarget('code');node('codeTask').value='original code';node('userInput').value='chat draft';
  await api.optimizePrompt('code');
  assert(node('codeTask').value==='improved'&&node('userInput').value==='chat draft','Code optimization must preserve chat draft');
  api.undoOptimize();assert(node('codeTask').value==='original code','Undo restores Code draft');
  draftChange=true;await api.optimizePrompt('code');
  assert(node('codeTask').value==='new draft','Do not overwrite a draft edited during request');
  return '9 optimizer checks passed';
}

testOptimizer(html).then(console.log).catch(err=>{console.error(err);process.exitCode=1;});
