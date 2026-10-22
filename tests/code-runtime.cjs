const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.join(__dirname,'..');
const context=vm.createContext({console,TextDecoder,TextEncoder,AbortController,DOMException,Response,ReadableStream,setTimeout,clearTimeout,URL,window:{},document:{getElementById:()=>null},CODE_TOOLS:[],codeInterview:false,chatURL:()=> 'https://test.example/chat/completions'});
vm.runInContext(fs.readFileSync(path.join(root,'assets/code-runtime.js'),'utf8')+'\nglobalThis.api={readToolStream,codeMessagesForRequest,codeResponsesInput,codeModelStep,codeRetryable};',context);
const {api}=context;
function stream(text,chunk=7){
  const bytes=new TextEncoder().encode(text);let offset=0;
  return new Response(new ReadableStream({pull(c){if(offset>=bytes.length){c.close();return;}c.enqueue(bytes.slice(offset,offset+chunk));offset+=chunk;}}));
}
(async()=>{
  const event=o=>'data: '+JSON.stringify(o)+'\n\n';
  const tool={index:0,id:'call_1',function:{name:'edit_file',arguments:JSON.stringify({path:'app.js',old_text:'old',new_text:'new'})}};
  const res=await api.readToolStream(stream(event({choices:[{delta:{content:'Hello 🌌',tool_calls:[tool]}}]})+event({choices:[{delta:{},finish_reason:'tool_calls'}]})+'data: [DONE]'),{});
  assert.equal(res.choices[0].message.content,'Hello 🌌');
  assert.equal(JSON.parse(res.choices[0].message.tool_calls[0].function.arguments).new_text,'new');
  await assert.rejects(()=>api.readToolStream(stream(event({choices:[{delta:{content:'partial'}}]})),{}),/Incomplete stream/);
  await assert.rejects(()=>api.readToolStream(stream('data: {"error":{"message":"quota"}}\n\n'),{}),/quota/);
  await assert.rejects(()=>api.readToolStream(stream(event({choices:[{delta:{tool_calls:[{index:0,id:'x',function:{name:'edit_file',arguments:'{"path":'}}]},finish_reason:'tool_calls'}]})),{}),/unfinished edit/);
  const messages=[{role:'system',content:'system'},{role:'user',content:'original goal'}];
  for(let i=0;i<20;i++)messages.push({role:'assistant',content:'',tool_calls:[{id:'c'+i,function:{name:'read_file',arguments:'{}'}}]},{role:'tool',tool_call_id:'c'+i,content:'x'.repeat(12000)});
  const compact=api.codeMessagesForRequest(messages);
  assert.ok(JSON.stringify(compact).length<70000);
  assert.equal(compact[1].content,'original goal');
  for(const m of compact.filter(m=>m.role==='tool'))assert.ok(compact.some(a=>a.tool_calls?.some(t=>t.id===m.tool_call_id)));
  const input=api.codeResponsesInput(compact);assert.ok(input.some(m=>m.type==='function_call_output'));
  let requests=0;
  context.fetch=async()=>{requests++;return requests===1?new Response('{"error":{"message":"busy"}}',{status:503}):Response.json({choices:[{message:{content:'recovered'},finish_reason:'stop'}]});};
  const answer=await api.codeModelStep('openrouter','test-key','test-model',messages.slice(0,2),new AbortController().signal);
  assert.equal(answer.content,'recovered');assert.equal(requests,2);
  requests=0;context.fetch=async()=>{requests++;return new Response('{"error":{"message":"invalid key"}}',{status:401});};
  await assert.rejects(()=>api.codeModelStep('openrouter','test','model',messages.slice(0,2),new AbortController().signal),/invalid key/);
  assert.equal(requests,1);
  const abort=new AbortController();abort.abort();
  await assert.rejects(()=>api.codeModelStep('openrouter','test','model',messages.slice(0,2),abort.signal),e=>e.name==='AbortError');
  assert.equal(requests,1);
  const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
  for(const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g))new vm.Script(m[1]);
  console.log('Code runtime tests passed: stream boundaries, truncated edits, errors, history, retry and Stop.');
})().catch(e=>{console.error(e);process.exitCode=1;});
