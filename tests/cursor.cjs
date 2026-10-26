// Cursor call: the step prompt and answer on the phone, and the PC companion's pairing, mapping and messages.
const assert=require('node:assert/strict');
const C=require('../assets/cursor.js');
const P=require('../pc/protocol.js');

// The prompt carries the screenshot size, the recent call and the rules for a spoken answer and a point.
const shot={w:1280,h:720};
const prompt=C.callPrompt({words:'How do I add a dimension in Revit?',recap:C.recapLines([{who:'me',text:'Hi'},{who:'claude',text:'Hello.',point:{x:1,y:2,label:'Annotate'}}]),shot});
assert.match(prompt,/1280 x 720 pixels/);assert.match(prompt,/ME NOW: How do I add a dimension/);
assert.match(prompt,/YOU: Hello\. \[pointed at Annotate\]/);assert.match(prompt,/"next":"wait_for_click"/);

// Answers: fenced or bare JSON, points clamped to the image, anything else spoken as plain words.
let step=C.parseStep('```json\n{"say":"Click **Annotate**.","point":{"x":412,"y":38,"label":"Annotate tab"},"next":"wait_for_click",}\n```',shot);
assert.deepEqual(step,{say:'Click Annotate.',point:{x:412,y:38,label:'Annotate tab'},next:'wait_for_click'});
step=C.parseStep('{"say":"Scroll down.","point":{"x":5000,"y":10},"next":"wait_for_click"}',shot);
assert.equal(step.point,null,'a point outside the screenshot is never shown');assert.equal(step.next,'listen');
step=C.parseStep('Sure! Open the File menu first.',shot);
assert.deepEqual(step,{say:'Sure! Open the File menu first.',point:null,next:'listen'});
assert.equal(C.parseStep('{"say":"","next":"done"}',shot).say,'Done.');

// Pairing on the phone: private addresses and a 6-digit code only.
assert.deepEqual(C.parsePair('192.168.1.20','482 913'),{host:'192.168.1.20',port:8765,code:'482913'});
assert.equal(C.parsePair('10.0.0.5:9000','123456').port,9000);
assert.match(C.parsePair('8.8.8.8','123456').error,/own Wi-Fi/);
assert.match(C.parsePair('192.168.1.20','12').error,/6-digit/);

// Companion: screenshot size, mapping back to the screen, code checks with a lockout, message validation.
assert.deepEqual(P.fitSize(2560,1440),{w:1280,h:720});assert.deepEqual(P.fitSize(1024,768),{w:1024,h:768});
assert.deepEqual(P.mapPoint({x:640,y:360},{w:1280,h:720},{x:-1920,y:0,width:2560,height:1440}),{x:-640,y:720});
let t=0;const gate=P.makeGate('123456',{now:()=>t});
assert.equal(gate.check('123456').ok,true);
for(let i=0;i<5;i++)assert.equal(gate.check('000000').ok,false);
assert.match(gate.check('123456').reason,/Wait a minute/,'five wrong codes lock pairing');
t+=61e3;assert.equal(gate.check('123456').ok,true);
assert.match(P.newCode(),/^\d{6}$/);
assert.deepEqual(P.readMessage('{"t":"point","x":1,"y":2,"w":10,"h":10,"label":"OK"}'),{t:'point',x:1,y:2,w:10,h:10,label:'OK',say:''});
assert.equal(P.readMessage('{"t":"point","x":1,"y":2,"w":0,"h":10}'),null);
assert.equal(P.readMessage('{"t":"click","x":1,"y":2}'),null,'the companion never clicks');
assert.equal(P.readMessage('not json'),null);
assert.equal(P.reached({x:100,y:100},{x:110,y:110}),true);assert.equal(P.reached({x:0,y:0},{x:100,y:100}),false);
assert.deepEqual(P.lanAddresses({'vEthernet (WSL)':[{family:'IPv4',address:'172.20.0.1',internal:false}],'Wi-Fi':[{family:'IPv4',address:'192.168.1.20',internal:false}],lo:[{family:'IPv4',address:'127.0.0.1',internal:true}]}).map(a=>a.address),['192.168.1.20','172.20.0.1']);
console.log('Cursor call checks passed: step prompt and answers, pairing, screen mapping, lockout, companion messages.');
