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
function initStudio(){
  setStudioArt(ls('studio_art')||'aurora');
  if(ls('studio_theme'))setStudioTheme(ls('studio_theme'),false);
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
    '</div><label>Appearance <select onchange="setStudioTheme(this.value)">'+['system','light','dark'].map(v=>'<option value="'+v+'" '+(v===theme?'selected':'')+'>'+v[0].toUpperCase()+v.slice(1)+'</option>').join('')+'</select></label><div class="modal-btns"><button class="gh-btn primary" onclick="closeSheet()">Done</button></div>');
}
