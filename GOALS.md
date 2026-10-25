# Goals

## v1.0.96 — done
Code tab "Send to Claude" bridge (types into Claude's message box, user presses send). Build passed, release published.

## v1.0.97 — App updates from Settings (no new signed IPA)

Add **Settings → App updates** so the Studio web layer can update without re-signing or reinstalling the IPA.

- CI: each build also publishes `studio-web.zip` and `studio-web.json` (version, sha256, `min_native` build) as release assets.
- Native ops in `App.swift`: `studioUpdateCheck` and `studioUpdateInstall`. Fetch from the GitHub releases API over HTTPS (releases are pre-releases, so `/releases/latest` is not usable), verify sha256, store the bundle in Application Support, keep the previous one.
- Launch: load the newest verified bundle if newer than the built-in one. If it does not initialize in a few seconds, roll back to the built-in bundle and mark that version bad.
- Gating: refuse a bundle whose `min_native` is higher than the installed build and show "needs a new IPA".
- Settings UI: current version, Check for updates, Update now (reloads), Reset to built-in.
- Tests: `tests/ota-update.cjs` (manifest, hash, version logic) plus a Swift test for rollback.
- If `claude-observer.js` and `claude-code-dom.js` are loaded from the bundle, ship them in the same update.

Limits
- v1.0.97 itself must be installed once as a signed IPA. Web updates are free after that.
- Swift code, Info.plist, icons and new native ops still need a new IPA.
- Does not remove the sideload tool's own certificate expiry.
- The native bridge trusts any page at aistudio.app (including `credentialGet`), so a downloaded bundle must be verified before it loads. Hash checking only covers corruption; CI signing with an embedded public key is a follow-up.
