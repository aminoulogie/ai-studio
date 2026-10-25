# Goals

## v1.0.96 — done
Code tab "Send to Claude" bridge (types into Claude's message box, user presses send). Build passed, release published.

## v1.0.98 — App updates from Settings (no new signed IPA)
Planned as v1.0.97; that run failed on a stale test, so it shipped as v1.0.98 (build passed, release published with studio-web.html and studio-web.json).

Settings → App updates updates the Studio web layer without re-signing or reinstalling the IPA.

Built
- CI writes `studio-web.json` (version, sha256, size, `min_native`) from the final processed page and publishes it with `studio-web.html` on every release.
- `StudioUpdater.swift`: checks the GitHub releases API (pre-releases included), downloads the newest bundle, verifies size and sha256, stores it in Application Support.
- Launch: loads the newest verified bundle if it is newer than the built-in one. The page must set `window.studioInitialized` within about 10 seconds; if it does not, or the app is killed before confirming, that version is marked bad and the built-in page loads.
- Gate: a bundle whose `min_native` is above the app's `nativeLevel` shows "needs a new IPA".
- Settings UI: running version, Check for updates, Download, Restart to apply, Reset to built-in.
- Tests: `tests/ota-update.cjs` (sheet states, safety checks, native ops snapshot, CI assets) and `tests/ios/StudioUpdaterTests.swift` (validation, release pick, rollback, reset).

Limits
- The first build with App updates must be installed once as a signed IPA. Web updates are free after that. That build is v1.0.100 (v1.0.98 and v1.0.99 do not have the Claude-tab fixes below).
- Swift code, Info.plist, icons and new native ops still need a new IPA. `claude-observer.js` now updates in-app (see v1.0.100).
- Does not remove the sideload tool's own certificate expiry.
- The bridge trusts any page at aistudio.app (including `credentialGet`), so the bundle is checked by size and hash only. Signing the bundle in CI with a public key embedded in the app is the next hardening step.
- Not verified on a device yet.

## v1.0.100 — Claude tab fixes
Build passed (run 40207609731).
- Send: `claude-observer.js` finds Send/Stop buttons in any language, falls back to Enter, and reports which buttons it saw if it fails. The Swift side retries the button 10 times and checks the message really went.
- In-app script update: the Claude-tab script ships as `studio-observer.js`, is checked by size and sha256 against `studio-web.json`, and is applied to open pages without a new IPA.
- Containers: a container opened by hand stays open even when it shows the usage limit (no auto-switch, no popup). Limit → Next and Code tab jobs still switch.
- Code tab send was confirmed working on a device (v1.0.98 build plus the observer update path). The container fix still needs a device check on the v1.0.100 IPA.
