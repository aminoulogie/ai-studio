const assert=require('node:assert/strict');
const {repoPrivatePath,assertRepoPublishable}=require('../assets/repo-privacy.js');
for(const path of ['memory/user.md','conversations/chat.json','profiles/account.json','.env','exports/context.json','backup.aistudio','models.json','ai_models_openai.json','tokens.json','Library/WebKit/cookies.db']){
  assert.equal(repoPrivatePath(path),true,path);
  assert.throws(()=>assertRepoPublishable({[path]:'private'}),/Private state/);
}
assert.equal(repoPrivatePath('ios/AIStudio/ClaudeProfileStore.swift'),false);
assert.doesNotThrow(()=>assertRepoPublishable({'src/app.js':'export const n=1;'}));
assert.throws(()=>assertRepoPublishable({'src/app.js':'const key="privatecredential123";'},{secrets:['privatecredential123']}),/credential/);
const message='This is a private conversation goal that must never be published in the repository.';
assert.throws(()=>assertRepoPublishable({'README.md':message},{messages:[{role:'user',content:message}]}),/Conversation text/);
console.log('Privacy checks passed: device state, credentials and conversation dumps are blocked from repository commits.');
