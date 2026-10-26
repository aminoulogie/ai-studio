// The only things the companion's two windows can do: receive updates, ask for a new code, show the test cursor.
'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const IN=['state','point','say','clear','reached'];
contextBridge.exposeInMainWorld('companion',{
  on:(channel,fn)=>{if(IN.includes(channel))ipcRenderer.on(channel,(_e,data)=>fn(data));},
  newCode:()=>ipcRenderer.send('new-code'),
  test:()=>ipcRenderer.send('test')
});
