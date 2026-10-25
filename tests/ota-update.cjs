const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.join(__dirname,'..',...p.split('/')),'utf8');
const html=read('index.html'),app=read('ios/AIStudio/App.swift'),upd=read('ios/AIStudio/StudioUpdater.swift'),wf=read('.github/workflows/ios.yml');

// Settings entry and page code
assert.match(html,/onclick="openAppUpdates\(\)"/,'Settings needs an App updates entry');
const start=html.indexOf('/* ===================== APP UPDATES');
const end=html.indexOf('/* end app updates */');
assert.ok(start>0&&end>start,'app update block must exist');
const block=html.slice(start,end);
assert.doesNotMatch(block,/fetch\(|XMLHttpRequest|eval\(|new Function|importScripts|<script/,'the page must never download or run code itself');
const OPS=['studioUpdateStatus','studioUpdateCheck','studioUpdateInstall','studioUpdateReload','studioUpdateReset'];
for(const op of OPS){
  assert.ok(block.includes(`op:'${op}'`),`page must call ${op}`);
  assert.match(app,new RegExp(`case "${op}"`),`native bridge must answer ${op}`);
}
assert.doesNotMatch(block,/url\s*:|https?:\/\//,'the page must not choose the download address');

// Sheet behavior for each state
const fnStart=block.indexOf('function appUpdatesSheet('),fnEnd=block.indexOf('let _appUpd');
const sheet=new Function('esc',block.slice(fnStart,fnEnd)+';return appUpdatesSheet;')(s=>String(s));
const base={builtIn:96,running:96,nativeLevel:1};
const idle=sheet(base,'');
assert.match(idle,/Check for updates/);
assert.doesNotMatch(idle,/Restart to apply|Download v|Reset to built-in/);
const offer=sheet({...base,available:97,canInstall:true,upToDate:false},'');
assert.match(offer,/Download v97/);
const needsIpa=sheet({...base,available:98,needsNewApp:true,canInstall:false},'');
assert.match(needsIpa,/v98 needs a new IPA/);
assert.doesNotMatch(needsIpa,/Download v98/);
const downloaded=sheet({...base,installed:97},'');
assert.match(downloaded,/Restart to apply/);
assert.match(downloaded,/Reset to built-in/);
const applied=sheet({builtIn:96,running:97,installed:97,nativeLevel:1},'');
assert.doesNotMatch(applied,/Restart to apply/);
assert.match(applied,/Reset to built-in/);
assert.match(sheet({...base,available:96,upToDate:true},''),/Up to date/);

// Native safety: verified bundle, fixed source, health probe, rollback
assert.match(upd,/sha256Hex\(data\) == manifest\.sha256/,'a download must match its manifest hash');
assert.match(upd,/data\.count == manifest\.size/,'a download must match its manifest size');
assert.match(upd,/minNative <= nativeLevel/,'a bundle that needs newer native code must be refused');
assert.match(upd,/url\.host == "api\.github\.com"/,'downloads must start at the GitHub API only');
assert.match(upd,/setValue\(nil, forHTTPHeaderField: "Authorization"\)/,'the token must not follow a cross-host redirect');
assert.match(upd,/func recoverFromInterruptedLaunch/,'an unconfirmed launch must roll back');
assert.match(app,/window\.studioInitialized === true/,'a downloaded page must prove it started');
assert.match(app,/abandonUpdate\(\)/,'a page that does not start must be dropped');
assert.match(app,/updater\.recoverFromInterruptedLaunch\(\)/,'recovery must run before the first load');
const studioOps=[...app.matchAll(/^\s*case ((?:"[A-Za-z]+"(?:,\s*)?)+):/gm)].flatMap(m=>[...m[1].matchAll(/"([A-Za-z]+)"/g)].map(x=>x[1])).sort();

// Native level: a page published for level N must only use ops that level N has.
// If this list changes, bump nativeLevel in StudioUpdater.swift AND min_native in ios.yml, then list the ops under the new level.
const LEVEL_1=['aiRequest','cancelRequest','claudeSend','claudeStop','credentialGet','credentialSet','github'+'DeviceCode','githubToken','google','googleRefresh','memoryGet','memorySet','selectStudioTab','sendToClaude','share',...OPS].sort();
assert.deepEqual(studioOps,LEVEL_1,'native ops changed: bump nativeLevel (StudioUpdater.swift) and min_native (ios.yml), then update this list');
const level=Number(upd.match(/static let nativeLevel = (\d+)/)[1]);
const ciLevel=Number(wf.match(/'min_native':\s*(\d+)/)[1]);
assert.equal(level,1,'this list describes native level 1');
assert.equal(ciLevel,level,'CI min_native must equal the app nativeLevel');

// CI publishes the exact page the app bundles
assert.ok(wf.indexOf('inline_libs.py')<wf.indexOf('Write web update manifest'),'the manifest must be computed after the page is fully processed');
assert.ok(wf.indexOf('Write web update manifest')<wf.indexOf('Generate Xcode project'),'the manifest must exist before the app is built');
assert.match(wf,/hashlib\.sha256\(page\)/);
assert.match(wf,/ios\/studio-web\.html/);
assert.match(wf,/ios\/studio-web\.json/);
assert.match(wf,/files: \|[\s\S]*studio-web\.html[\s\S]*studio-web\.json/,'the release must carry both web assets');
// The Claude-tab helper script travels with the web update and is held to the same checks
const browser=read('ios/AIStudio/ClaudeBrowserController.swift');
assert.match(upd,/static func validateObserver/,'the observer script must be validated');
assert.match(upd,/sha256Hex\(data\) == expected/,'an observer download must match its manifest hash');
assert.match(upd,/data\.count == size/,'an observer download must match its manifest size');
assert.match(upd,/maxObserverBytes/,'an observer download must be size-limited');
assert.match(upd,/try Self\.validateObserver\(manifest, data: observer\)/,'store must validate the observer before writing it');
assert.match(upd,/missing its Claude helper script/,'a release that announces a script but lacks it must be refused');
assert.match(app,/StudioUpdater\.shared/,'the app must use the shared updater');
assert.doesNotMatch(app,/StudioUpdater\(\)/,'no second updater instance');
assert.match(browser,/StudioUpdater\.shared\.observerSource\(\)/,'the Claude tab must read the verified update');
assert.match(browser,/claude-observer/,'the Claude tab must still fall back to the built-in script');
assert.match(wf,/'observer_sha256':\s*hashlib\.sha256\(observer\)/,'CI must hash the observer script');
assert.match(wf,/'observer_size':\s*len\(observer\)/,'CI must record the observer size');
assert.match(wf,/ios\/AIStudio\/claude-observer\.js/,'CI must publish the observer from the app sources');
assert.match(wf,/files: \|[\s\S]*studio-observer\.js/,'the release must carry the observer script');
const observerSrc=read('ios/AIStudio/claude-observer.js');
assert.ok(observerSrc.length<Number(upd.match(/maxObserverBytes = ([\d_]+)/)[1].replace(/_/g,'')),'the observer must fit the download limit');
for(const marker of ['claudeObserver','claudeSubmit'])assert.ok(observerSrc.includes(marker),'the observer must contain '+marker+' (the updater requires it)');
console.log('App update checks passed: verified web bundle, native-level gate, rollback, release assets, Claude-tab script update.');
