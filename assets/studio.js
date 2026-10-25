const STUDIO_THEMES=[
  {id:'aurora',name:'Aurora',note:'Soft violet light'},
  {id:'lagoon',name:'Lagoon',note:'A calmer kind of blue'},
  {id:'ember',name:'Ember',note:'A warm creative glow'},
  {id:'midnight',name:'Midnight',note:'Deep space, clear focus'}
];
function studioArt(id,full=false){
  if(!STUDIO_THEMES.some(t=>t.id===id))id='aurora';
  if(window.webkit?.messageHandlers?.native)return 'studio-art://bundle/'+id+(full?'.png':'.svg');
  return 'assets/artwork/'+id+'.svg';
}
function setStudioArt(id){
  if(!STUDIO_THEMES.some(t=>t.id===id))id='aurora';
  ls('studio_art',id);
  document.documentElement.style.setProperty('--studio-art','url("'+studioArt(id,true)+'")');
}
/* Drawn line icons instead of emoji in the app's own controls. Chat text and Claude's replies are never touched. */
const STUDIO_ICONS={
  '💰':'<circle cx="12" cy="12" r="9"/><path d="M14.5 9.3c-.4-.8-1.4-1.3-2.5-1.3-1.4 0-2.5.8-2.5 1.9 0 2.3 5 1.2 5 3.7 0 1.1-1.1 1.9-2.6 1.9-1.2 0-2.2-.5-2.6-1.4M12 6.5V8m0 8v1.5"/>',
  '✨':'<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 15l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z"/>',
  '✦':'<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/>',
  '🔒':'<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  '📲':'<rect x="7" y="3" width="10" height="18" rx="2"/><path d="M12 17h.01"/>',
  '🔍':'<circle cx="11" cy="11" r="6"/><path d="M20 20l-4.2-4.2"/>',
  '＋':'<path d="M12 5v14M5 12h14"/>',
  '↻':'<path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v4h-4"/>',
  '🔄':'<path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v4h-4"/>',
  '✕':'<path d="M6 6l12 12M18 6L6 18"/>',
  '⚠️':'<path d="M12 4l9 16H3z"/><path d="M12 10v4m0 3h.01"/>',
  '❓':'<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7m0 3h.01"/>',
  '✅':'<path d="M5 12.5l4.5 4.5L19 7.5"/>'
};
Object.assign(STUDIO_ICONS,{
  '⚠':'<path d="M12 4l9 16H3z"/><path d="M12 10v4m0 3h.01"/>',
  '📎':'<path d="M21 11.5l-8.5 8.5a5 5 0 0 1-7-7l9-9a3.3 3.3 0 0 1 4.7 4.7l-9 9a1.7 1.7 0 0 1-2.4-2.4l8.2-8.2"/>',
  '📁':'<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  '⌨':'<path d="M8 7l-5 5 5 5M16 7l5 5-5 5"/>',
  '⌘':'<path d="M8 7l-5 5 5 5M16 7l5 5-5 5"/>',
  '🔌':'<path d="M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4"/>',
  '♾':'<path d="M12 12c-2-2.5-3.5-4-5.5-4a4 4 0 0 0 0 8c2 0 3.5-1.5 5.5-4zm0 0c2 2.5 3.5 4 5.5 4a4 4 0 0 0 0-8c-2 0-3.5 1.5-5.5 4z"/>',
  '⚙':'<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>',
  '📌':'<path d="M9 4h6l-1 5 3 3v2H7v-2l3-3zM12 14v7"/>',
  '💾':'<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
  '✍':'<path d="M4 20l1-4L16.5 4.5a2 2 0 0 1 3 3L8 19z"/><path d="M14 7l3 3"/>',
  '🎯':'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/>',
  '⚡':'<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>',
  '💻':'<rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 20h20"/>',
  '↩':'<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
  '🔊':'<path d="M4 9v6h4l5 4V5L8 9zM16.5 8.5a5 5 0 0 1 0 7"/>'
});
/* Claude-style home screen: orange asterisk, serif greeting, five chips. */
function studioWelcome(){
  const ic=d=>'<svg class="ic" viewBox="0 0 24 24" aria-hidden="true">'+d+'</svg>';
  const chip=(d,label,act)=>'<button class="cl-chip" onclick="'+act+'">'+ic(d)+'<span>'+label+'</span></button>';
  return '<div class="welcome cl-welcome"><h1 class="cl-greet"><svg class="cl-star" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5v19M2.5 12h19M5.3 5.3l13.4 13.4M18.7 5.3L5.3 18.7"/></svg><span>Let\u2019s have a think</span></h1><div class="cl-chips">'+
    chip('<path d="M4 20l1-4L16.5 4.5a2 2 0 0 1 3 3L8 19z"/><path d="M14 7l3 3"/>','Write',"studioPrompt('Help me write something. Ask me what I need and who it is for.')")+
    chip('<path d="M2 9l10-5 10 5-10 5z"/><path d="M6 11.5V16c0 1.5 3 3 6 3s6-1.5 6-3v-4.5"/>','Learn',"studioPrompt('Teach me something new. Ask me what I want to learn first.')")+
    chip('<path d="M8 7l-5 5 5 5M16 7l5 5-5 5"/>','Code',"switchTab('code')")+
    chip('<path d="M4 9h12v5a5 5 0 0 1-5 5h-2a5 5 0 0 1-5-5z"/><path d="M16 10h2a2 2 0 0 1 0 4h-2M8 3v3m4-3v3"/>','Life stuff',"studioPrompt('Help me think through something in my life. Ask me what is on my mind.')")+
    chip('<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z"/>','Claude\u2019s choice',"studioPrompt('Surprise me with something interesting to think about.')")+
    '</div></div>';
}
function swapStudioIcons(root){
  const lead=new RegExp('^\\s*('+Object.keys(STUDIO_ICONS).join('|')+')\\uFE0F?\\s*','u');
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode:n=>{
    const p=n.parentElement;
    if(!p||/^(SCRIPT|STYLE|TEXTAREA|OPTION|CODE|PRE|TITLE)$/.test(p.tagName)||p.closest('.msg-bubble,.code-step,.code-log,.diff,pre,code,[contenteditable]'))return NodeFilter.FILTER_REJECT;
    return lead.test(n.nodeValue)?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;
  }});
  const hits=[];while(walker.nextNode())hits.push(walker.currentNode);
  for(const n of hits){
    const m=lead.exec(n.nodeValue);if(!m||!n.parentNode)continue;
    const t=document.createElement('template');
    t.innerHTML='<svg class="ic" viewBox="0 0 24 24" aria-hidden="true">'+STUDIO_ICONS[m[1]]+'</svg>';
    n.parentNode.insertBefore(t.content,n);
    n.nodeValue=n.nodeValue.slice(m[0].length);
  }
  root.querySelectorAll('input[placeholder]').forEach(i=>{const m=lead.exec(i.placeholder);if(m)i.placeholder=i.placeholder.slice(m[0].length);});
}
function startStudioIcons(){
  let timer=0;
  const opts={childList:true,subtree:true,characterData:true};
  const mo=new MutationObserver(()=>{
    clearTimeout(timer);
    timer=setTimeout(()=>{mo.disconnect();try{swapStudioIcons(document.body);}catch(e){}mo.observe(document.body,opts);},60);
  });
  try{swapStudioIcons(document.body);}catch(e){}
  mo.observe(document.body,opts);
}
function initStudio(){
  startStudioIcons();
  setStudioArt(ls('studio_art')||'aurora');
  setStudioTheme(ls('studio_theme')||'claude',false);
  const viewport=window.visualViewport;
  const update=()=>{
    if(!viewport)return;
    const focused=/INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName||'');
    document.body.classList.toggle('keyboard-open',focused&&window.innerHeight-viewport.height>120);
  };
  viewport?.addEventListener('resize',update);document.addEventListener('focusout',()=>setTimeout(update,100));
}
function studioPrompt(value){document.getElementById('userInput').value=value;autoResize(document.getElementById('userInput'));document.getElementById('userInput').focus();updateCtx();}
function setStudioTheme(value,save=true){
  if(save)ls('studio_theme',value);
  if(value==='system')document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme',value);
  isDark=value==='dark'||value==='claude';ls('cl_dark',isDark?'1':'0');
}
function openAppearance(){
  const current=ls('studio_art')||'aurora',theme=ls('studio_theme')||'system';
  openSheet('<h3>Make it your space.</h3><p>Four original wallpapers, bundled in high resolution on iPhone. Only your selected wallpaper is loaded.</p><div class="appearance-grid">'+
    STUDIO_THEMES.map(t=>'<button class="appearance-card" aria-pressed="'+(t.id===current)+'" onclick="setStudioArt(\''+t.id+'\');openAppearance()" title="'+t.note+'"><img src="'+studioArt(t.id)+'" alt="'+t.note+'"><span>'+t.name+'</span></button>').join('')+
    '</div><label>Appearance <select onchange="setStudioTheme(this.value)">'+['system','light','dark','claude'].map(v=>'<option value="'+v+'" '+(v===theme?'selected':'')+'>'+v[0].toUpperCase()+v.slice(1)+'</option>').join('')+'</select></label><div class="modal-btns"><button class="gh-btn primary" onclick="closeSheet()">Done</button></div>');
}
