# AI Studio for iOS

Studio remains the main interface. The iOS tab bar has **Chat, Code, Claude, Projects, Settings**. Claude is a separate official claude.ai browser; Studio model/API connections are independent.

## Private device data and empty installs

Fresh installs start with **no configured models, tokens, conversations, Claude profiles or memory**. Model IDs are added or fetched only on the user's device. An existing user's local data stays on their device when updating; it is not embedded in the IPA or shared by a PWA link.

Chat and Code recovery history live in localStorage / IndexedDB inside that app or browser installation. Claude login state lives only in each WebKit container and Claude's service. GitHub sign-in uses the iOS Keychain. The app has no backend that shares personal sessions among visitors.

GitHub commits publish source edits only. The commit path blocks known chat, memory, session, profile, export and credential files; checks staged text for this device's credentials and verbatim conversation dumps; and instructs the Code assistant to keep personal state out of the repository. Private runtime files are also excluded from local Git with .gitignore. A PWA on the same browser retains that browser's own data; another person's browser starts empty. An explicit encrypted backup remains an opt-in export to the destination the user chooses.

Use **Add model on this device** in Studio settings, or add a provider key and Reload models. The official Claude tab does not need Studio models or API keys. These local settings are not sent to GitHub.

## Claude browser accounts

Requires **iOS 17+** for persistent, named WebKit data stores.

1. Open the **Claude** tab, then **Accounts → Add account**.
2. Give the profile a label and sign in on the real Claude website. Repeat for up to six accounts. No API key is needed.
3. Switch profiles in **Accounts**. Each UUID has its own persistent `WKWebsiteDataStore`: cookies, local storage, IndexedDB and cache stay separate. OAuth popups inherit their initiating container.
4. The actions menu contains account settings: rename, pause rotation, reorder, reset limit, log out/clear one container, or remove an account.
5. A visible limit banner marks the account Rate-Limited and rotates to the next enabled Active account. The app saves context before switching and opens a new Claude chat. If no account is available, it stops. **Limit → Next** is the manual fallback.

Accounts start Logged Out. A Claude composer marks them Active, or use **Account settings → Mark signed in / Reset limit** after confirming sign-in. Paused accounts can be opened manually but are skipped in rotation. A visible relative reset notice (such as “try again in 25 minutes”) is used when recognized. Otherwise the fallback cooldown is **five hours after detection**, not Claude's authoritative reset time. Check Claude's displayed reset time and reset the app's status when appropriate.

Detection observes visible alert/status/limit notices with a debounce; it does not scan arbitrary chat text for “limit” and does not call private Claude endpoints. Claude's HTML, languages, authentication policies and limits can change. Embedded login must be tested with your real accounts. The app cannot bypass a sign-in restriction, grant a model, or guarantee a particular Sonnet version on the free tier.

## Context export and continuation

In the Claude actions menu:

- **Export visible chat · JSON / Markdown** opens the iOS share sheet (Save to Files, AirDrop, etc.).
- **Copy latest handover** copies the saved conversation and continuation notes. Paste it into the incoming account's chat, reattach necessary files, then send.
- **Edit continuation notes** records the goal, decisions, next steps, or manually copied history.
- **Import context JSON** loads a previous export for copying into another chat.

Automatic switching does not submit a message. Exports contain **rendered conversation text only** and are marked partial. Scroll to load older messages first. Attachments, hidden reasoning, project knowledge, browser credentials and Claude's private server-side context are not transferred. Model context limits still apply. The latest snapshot is stored locally with iOS file protection; exported files contain your conversation text, so choose their destination deliberately.

## Code edits and GitHub commits

The Code tab can stage model edits and commit them through the GitHub API; a local Git executable is not involved.

1. Connect GitHub in **Projects** or **Connectors**. On iOS the GitHub token is stored in Keychain; an existing browser token is migrated on launch. Desktop browser sign-ins retain the existing browser storage behavior.
2. Use a fine-grained token scoped to the repository with **Contents: read and write**, or a classic token with **repo** scope. Changes to GitHub Actions workflows may additionally require workflow write permission. Approve organization SSO if required.
3. Select the repository and an existing writable branch.
4. **Permissions → Automatically commit completed tasks** enables automatic commits for that repository. The app checks write access before enabling it. Disable it to review and commit manually. Stopped, failed, or step-limited tasks keep their edits without automatically committing.
5. Protected branches may require a feature branch and pull request. A setting cannot override GitHub branch protection or token permissions.

Code reads are pinned to a commit. Commits compare affected files with that base, preserve file modes, and update the branch without force. Remote conflicts and concurrent pushes keep pending edits and return an actionable error. After a conflict, copy/export the pending changes, refresh the branch, and merge the conflicting file before retrying. The app does not silently overwrite it.

## Fix local Git authentication and tracking

No developer-machine Git configuration is included in this repository, and the editing environment has no terminal access. Run this setup on your development Mac:

```bash
brew install gh
gh auth login --hostname github.com --git-protocol https --web
git clone https://github.com/aminoulogie/ai-studio.git
cd ai-studio
git switch codex/account-rotation-context-git
bash scripts/git-setup.sh
```

If you already have a checkout, run the script there. It checks the repository and write access, configures GitHub's credential helper, fills missing local author identity, fetches remote branches, sets upstream tracking when available, enables automatic upstream setup for new branches, and installs this repository's privacy pre-commit hook (requires Node 22+). It does not commit or push files.

Normal synchronization:

```bash
git status
git add path/to/changed-file
git commit -m "Describe the change"
git push --set-upstream origin HEAD
```

If a push is rejected because the remote moved, commit or stash local work, then `git fetch origin` and `git rebase @{upstream}`, resolve conflicts, and push again. Do not force-push to fix an ordinary synchronization failure. For an expired token, reconnect with `gh auth login`; for permission or protected-branch errors, use a writable branch/token. If local signing fails, repair the configured signing key or explicitly choose unsigned commits with `git -c commit.gpgsign=false commit ...`.

## Build and install the IPA

### GitHub Actions (no Mac needed)

1. Open **Actions → Build iOS IPA → Run workflow** and select the feature branch, or open its pull request.
2. The workflow runs JavaScript/browser checks and native profile, context and WebKit isolation tests.
3. After success, download the **AIStudio-ipa** artifact and extract `AIStudio.ipa`.
4. Sign and install using your existing Apple signing setup (for example AltStore or Sideloadly). The CI artifact is unsigned and requires an iOS 17+ device.

### Local macOS build

Install full Xcode 16+, select its command-line tools, and install XcodeGen, Python 3.12+ and Node 22. Then:

```bash
brew install xcodegen
node tests/optimizer.cjs
node tests/code-runtime.cjs
node tests/git-workflow.cjs
node tests/repo-privacy.cjs
node tests/claude-observer.cjs
bash ios/scripts/build-ipa.sh
```

The script bundles Studio, generates artwork and the Xcode project, builds without signing, and writes **ios/build/AIStudio.ipa**. For an Apple-signed build, open the generated `ios/AIStudio.xcodeproj`, select your signing team and bundle identifier, and use **Product → Archive → Distribute App**.

To run browser checks: `npm install --no-save playwright@1.56.1`, `npx playwright install webkit chromium`, then `node tests/browser.cjs`. Native tests run through the generated AIStudio scheme on an iPhone simulator.

Live verification still needed: real Claude sign-in (including any OAuth/verification flow), current localized limit banners, and your repository token/branch rules. Automated checks do not use your Claude credentials.

WebKit profile design: [Apple's profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).
