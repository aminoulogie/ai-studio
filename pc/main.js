// AI Studio Companion: pairs with the iPhone app over your Wi-Fi, sends screenshots of the main screen when the
// phone asks, and draws the terracotta ghost cursor where Claude points. It never clicks or types for you.
'use strict';
const {app,BrowserWindow,screen,desktopCapturer,ipcMain}=require('electron');
const os=require('node:os');
const path=require('node:path');
const {WebSocketServer}=require('ws');
const P=require('./protocol');

const PORT=Number(process.env.AISTUDIO_PORT)||8765;
let control=null,overlay=null,wss=null,client=null,peer='';
let gate=P.makeGate(P.newCode());
let target=null,watch=null,near=0,reachedSent=false,serverError='';

if(!app.requestSingleInstanceLock())app.quit();
app.on('second-instance',()=>{if(control){control.show();control.focus();}});

const prefs={preload:path.join(__dirname,'preload.js'),contextIsolation:true,sandbox:true,nodeIntegration:false};
const mainDisplay=()=>screen.getPrimaryDisplay();
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const send=(ws,m)=>{try{if(ws&&ws.readyState===1)ws.send(JSON.stringify(m));}catch{}};

function state(){
  return {addresses:P.lanAddresses(os.networkInterfaces()),port:PORT,code:gate.code,connected:!!client,peer,error:serverError};
}
function pushState(){control?.webContents.send('state',state());}

function createControl(){
  control=new BrowserWindow({width:400,height:560,resizable:false,maximizable:false,title:'AI Studio Companion',
    backgroundColor:'#262624',autoHideMenuBar:true,webPreferences:prefs});
  control.loadFile('control.html');
  control.webContents.on('did-finish-load',pushState);
  control.on('closed',()=>app.quit());
}

function createOverlay(){
  const d=mainDisplay();
  overlay=new BrowserWindow({x:d.bounds.x,y:d.bounds.y,width:d.bounds.width,height:d.bounds.height,
    transparent:true,frame:false,resizable:false,movable:false,focusable:false,skipTaskbar:true,hasShadow:false,
    alwaysOnTop:true,show:false,webPreferences:prefs});
  overlay.setAlwaysOnTop(true,'screen-saver');
  overlay.setIgnoreMouseEvents(true);
  overlay.loadFile('overlay.html');
  overlay.once('ready-to-show',()=>overlay.showInactive());
}

/** The main screen, scaled to at most 1280 px, without the ghost cursor in it. */
async function capture(){
  const d=mainDisplay(),{w,h}=P.fitSize(d.size.width,d.size.height);
  overlay?.setOpacity(0);
  await delay(80);
  try{
    const sources=await desktopCapturer.getSources({types:['screen'],thumbnailSize:{width:w,height:h}});
    const src=sources.find(s=>s.display_id===String(d.id))||sources[0];
    if(!src)throw new Error('No screen to capture.');
    const size=src.thumbnail.getSize();
    return {w:size.width,h:size.height,data:src.thumbnail.toJPEG(72).toString('base64')};
  }finally{overlay?.setOpacity(1);}
}

function clearTarget(){
  target=null;near=0;
  if(watch){clearInterval(watch);watch=null;}
  overlay?.webContents.send('clear');
}

/** Tells the phone once the real mouse is resting on the spot Claude pointed at. */
function startWatch(){
  if(watch)clearInterval(watch);
  near=0;reachedSent=false;
  watch=setInterval(()=>{
    if(!target||reachedSent)return;
    near=P.reached(screen.getCursorScreenPoint(),target)?near+1:0;
    if(near>=2){reachedSent=true;overlay?.webContents.send('reached');send(client,{t:'reached'});}
  },120);
}

function showPoint(m){
  const d=mainDisplay();
  target=P.mapPoint(m,{w:m.w,h:m.h},d.bounds);
  overlay?.webContents.send('point',{x:target.x-d.bounds.x,y:target.y-d.bounds.y,label:m.label,say:m.say});
  startWatch();
}

async function handle(ws,m){
  switch(m.t){
    case 'shot':
      try{send(ws,{t:'shot',id:m.id,...await capture()});}
      catch(e){send(ws,{t:'error',id:m.id,message:'Could not capture the screen: '+e.message});}
      break;
    case 'point':showPoint(m);break;
    case 'say':overlay?.webContents.send('say',m.text);break;
    case 'clear':clearTarget();break;
    case 'ping':send(ws,{t:'pong'});break;
  }
}

function startServer(){
  wss=new WebSocketServer({port:PORT,host:'0.0.0.0',maxPayload:64*1024});
  wss.on('error',e=>{serverError=e.code==='EADDRINUSE'?'Port '+PORT+' is already in use. Close the other copy of the companion.':e.message;pushState();});
  wss.on('connection',(ws,req)=>{
    let paired=false;
    const timer=setTimeout(()=>{if(!paired)ws.close(4001,'Pair first');},15000);
    ws.on('message',data=>{
      const m=P.readMessage(data.toString());
      if(!m)return;
      if(!paired){
        if(m.t!=='hello'){ws.close(4002,'Pair first');return;}
        const r=gate.check(m.code);
        if(!r.ok){send(ws,{t:'error',message:r.reason});ws.close(4003,'Wrong code');return;}
        paired=true;clearTimeout(timer);
        if(client&&client!==ws)client.close(4004,'Another phone connected');
        client=ws;peer=String(req.socket.remoteAddress||'').replace(/^::ffff:/,'');
        const d=mainDisplay();
        send(ws,{t:'ready',name:os.hostname(),screen:{w:d.size.width,h:d.size.height}});
        pushState();return;
      }
      if(ws===client)handle(ws,m);
    });
    ws.on('close',()=>{clearTimeout(timer);if(ws===client){client=null;peer='';clearTarget();pushState();}});
    ws.on('error',()=>{});
  });
}

ipcMain.on('new-code',()=>{gate=P.makeGate(P.newCode());client?.close(4005,'New code');pushState();});
ipcMain.on('test',()=>{
  const d=mainDisplay(),c={x:Math.round(d.size.width/2),y:Math.round(d.size.height/2)};
  target={x:d.bounds.x+c.x,y:d.bounds.y+c.y};
  overlay?.webContents.send('point',{x:c.x,y:c.y,label:'Test: move your mouse here',say:''});
  startWatch();
});

app.whenReady().then(()=>{
  createOverlay();createControl();startServer();
  screen.on('display-metrics-changed',()=>{const d=mainDisplay();overlay?.setBounds(d.bounds);});
});
app.on('window-all-closed',()=>app.quit());
