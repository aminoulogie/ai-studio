# AI Studio for iOS

A Claude Code-style workspace on your iPhone, run by your own claude.ai accounts. It looks like claude.ai: warm paper, ink text, the terracotta spark, a serif greeting.

Two tabs:

- **Code**: sessions on a GitHub repository. Describe a task; the Claude team does it; you review the diff and commit.
- **Claude**: your Claude accounts on the real claude.ai, each in its own container (separate cookies and storage). This is where you sign in, and where the manager's message waits for you to press Send.

## How the team works

1. **Manager** (your paid Opus account): gets your request and the file list and writes a short JSON plan of up to a few tasks that touch different files. It only plans, so it uses little of your limit. The app types the message; **you press Send** in the Claude tab, then the app jumps back to Code by itself.
2. **Sub-agents** (your free Sonnet accounts): each task goes to a free container in a new chat with its files and an exact edit format. They work in parallel (1–4 at once, Settings → Claude team) and send by themselves.
3. **The app applies the edits** character for character. An edit whose old text does not match goes back to a sub-agent once, with the current file. Nothing is committed until you tap **Commit**, or until a task finishes cleanly with **Commit finished tasks automatically** on.

Short questions ("What does this app do?") skip the manager and go straight to one sub-agent. With no manager set, or Mode → Single, one sub-agent does the whole task.

**Solo conversations remember.** In Solo mode your follow-ups stay in the same container's chat, so Claude keeps the context. When that container hits its limit, a free Sonnet sub-agent **compresses the conversation** (goal, decisions, files changed, next step, at most 250 words) and the next container gets that summary plus your last messages word for word, then continues. The handover shows in the conversation so you can read what was passed on.

**Shared memory.** One memory goes into every message, from the Code tab and from every container, so you never repeat yourself. When Claude learns something lasting (a preference, a decision), it adds a line by itself; a "Memory updated" note appears with **Undo**. Edit it any time in Settings. It stays on the phone and is never committed.

**Message box tools.** **?** question mode (Claude asks a few multiple-choice questions first; tap the answers and Continue), **wand** prompt fixer (a free sub-agent rewrites your draft: Clearer, For coding, Detailed or Shorter, with Undo), **mic** voice typing (native iOS speech recognition, since web views cannot listen). The dot in the footer shows whether containers are ready; tap it to see them, switch each one on or off, and pick the manager.

**Limits.** When a container shows Claude's usage-limit notice, it is marked limited (for the time Claude shows, otherwise five hours) and its task restarts on the next free sub-agent automatically. When every sub-agent is limited the task stops and says so. **Limit → Next** in the Claude tab does the same by hand. **Mark signed in / Reset limit** clears it early.

Containers keep running while you are in the Code tab: idle containers beyond five are unloaded to save memory and reload when needed. If you leave the app, iOS gives it a short grace period; tasks catch up when you come back, because Claude keeps writing on its servers.

## Set up

1. **Claude tab → Accounts → Add account** for each Claude account (as many as you like) and sign in on claude.ai.
2. Make your Opus account the manager: **Actions → Account settings → Make it the manager**, or **Code → Claude team → Manager account**.
3. **Code → Settings → GitHub**: paste a fine-grained token with **Contents: read and write** for your repository (or a classic token with `repo`). It is stored in the iOS Keychain.
4. Pick a repository and branch from the chip under the message box, and describe what you want.

The app types into Claude's message box and presses its Send button the way you would, reads the visible reply, and never touches cookies, tokens or private Claude endpoints. Claude's page can change; if Send or the reply can't be found, the task stops with what it saw. Automating several accounts may conflict with Claude's terms of use; that risk is yours.

## Privacy

Fresh installs start empty. Sessions, staged edits and shared memory stay on the device (IndexedDB and a protected file); the GitHub token is in the Keychain. Commits are checked before they go out: private paths (memory, sessions, credentials, exports) are refused, and so is any file containing your token or your own messages verbatim. Nothing is sent anywhere except claude.ai (in each container) and api.github.com.

## Commits

Each session pins the commit it started from. A commit re-checks every changed file against GitHub and stops, keeping your edits, if someone changed it meanwhile. File modes are kept; nothing is ever force-pushed. Protected branches and token permissions still apply.

## Update the workspace without a new IPA

**Settings → App updates** downloads the newest published web page and Claude helper script from this repository's releases, checks size and SHA-256, and loads it after a restart. A page that does not start within about ten seconds is dropped and the built-in one loads. A page that needs newer native features (`min_native` above the app's native level, now 3) asks for a new IPA instead.

## Build and install the IPA

**GitHub Actions** (Actions → Build iOS IPA). Built to use few paid minutes:

- Tests, the bundled page, the app icon and the web update release run on **Linux**. A screens-only change (index.html, assets) never touches macOS: the app installs it from **Settings → App updates**.
- The **macOS** job only compiles the app, and only when native code changed (`ios/AIStudio`, `ios/project.yml`, `tests/ios`) or when you run the workflow by hand with **Build the IPA** on. It skips the simulator tests unless you tick **Also run the iOS simulator tests**.
- A new push cancels the older run of the same branch.

Download the IPA from the release (or the **AIStudio-v1.0.N** artifact) and sign/install it with Sideloadly, AltStore, ESign or Feather (iOS 17+). The CI build is unsigned.

**On a Mac** (Xcode 16+, XcodeGen, Python 3.12, Node 22):

```bash
brew install xcodegen
node tests/agents.cjs && node tests/git-workflow.cjs && node tests/repo-privacy.cjs
node tests/claude-observer.cjs && node tests/ota-update.cjs
bash ios/scripts/build-ipa.sh
```

Browser checks: `npm install --no-save playwright@1.56.1 && npx playwright install webkit chromium && node tests/browser.cjs`. They run a full team task against a fake iOS bridge and a fake GitHub on an iPhone and a desktop viewport.

Still needs a check on a real device with your accounts: claude.ai sign-in inside the app, today's limit notices, and Send on the current claude.ai page.

## Local Git setup

```bash
gh auth login --hostname github.com --git-protocol https --web
git clone https://github.com/aminoulogie/ai-studio.git && cd ai-studio
bash scripts/git-setup.sh
```

The script sets up credentials, upstream tracking and this repository's privacy pre-commit hook. It does not commit or push.
