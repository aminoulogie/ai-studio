const assert=require('node:assert/strict');
const fs=require('node:fs');
const html=fs.readFileSync(require('node:path').join(__dirname,'..','index.html'),'utf8');
assert.match(html,/id="sharedMemory"/,'shared memory field missing');
assert.match(html,/ls\('studio_memory'/,'memory must be stored under studio_memory');
assert.match(html,/sharedMemory'\)\.value=ls\('studio_memory'\)/,'memory must load on startup');
const callApi=html.slice(html.indexOf('async function callAPI('),html.indexOf('function httpErr('));
assert.match(callApi,/sharedMemoryPrompt\(\)/,'callAPI must add shared memory to the system prompt');
for(const adapter of ['callAnthropic','callGemini','callOpenAICompat','callResponses','callPuter']){
  assert.ok(callApi.includes(adapter+'(')&&/sys,/.test(callApi),adapter+' must receive the system prompt');
}
assert.doesNotMatch(html,/fetch\([^)]*studio_memory/,'memory must never be sent anywhere except inside the system prompt');
assert.doesNotMatch(html,/ai_global_memory/,'there must be only one memory store');
assert.match(html,/op:'memoryGet'/,'memory must be read from the device file');
assert.match(html,/op:'memorySet'/,'memory must be written to the device file');
assert.match(html,/syncMemoryFromNative\(\);/,'memory must sync on startup');
assert.match(html,/const mem=globalMemoryBlock\(\)/,'the Code assistant must receive the shared memory');
const swift=fs.readFileSync(require('node:path').join(__dirname,'..','ios','AIStudio','App.swift'),'utf8');
assert.match(swift,/case "memoryGet"/,'native bridge must answer memoryGet');
assert.match(swift,/case "memorySet"/,'native bridge must answer memorySet');
const tabs=fs.readFileSync(require('node:path').join(__dirname,'..','ios','AIStudio','StudioTabController.swift'),'utf8');
assert.match(tabs,/studio\.memoryStore = store/,'the Studio web view must share the Claude memory store');
console.log('Shared memory checks passed: one device-local store feeds every provider.');
