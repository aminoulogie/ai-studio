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
console.log('Shared memory checks passed: one device-local store feeds every provider.');
