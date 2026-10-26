# PC mode and Cursor mode: design

Status: design only, nothing built yet. Questions to settle are at the end.

## What it is

A small desktop companion for Windows (Mac later) that pairs with the AI Studio iPhone app.

- **PC mode (Claude drives).** Claude and its sub-agents see your screen, move the mouse, click and type to finish a task for you, like "export these Revit sheets to PDF". You watch, and you can stop it at any moment.
- **Cursor mode (you drive, Claude guides).** You stay in control. A second, terracotta "ghost" cursor shows you where to go. You talk with Claude on your phone like a call: "Click here… now open Modify… type 2400." The ghost cursor moves to each spot as Claude speaks, and you follow it with your own mouse.

## Pieces

| Piece | Where | Job |
| --- | --- | --- |
| **Companion app** | PC (Tauri: small, Rust + a web view) | Screenshots, the ghost-cursor overlay, mouse and keyboard control (PC mode only), the Claude containers on the PC |
| **Ghost cursor overlay** | PC | A transparent, click-through, always-on-top window covering every screen. It draws the terracotta pointer, a short label ("Modify tab") and a pulse where to click. It never takes your clicks. |
| **Voice call** | iPhone app | Push-to-talk or hands-free. Your speech becomes text (the native dictation already in the app); Claude's answer is spoken back (iOS speech synthesis). Free, nothing extra to install. |
| **Link phone ↔ PC** | Local Wi-Fi | The PC shows a QR code; the phone scans it. They talk over an encrypted WebSocket on your home network. No server in between. |
| **Claude** | The PC's own containers (claude.ai in the companion's web view, same as the phone), or the phone's containers | Looks at the screenshot and answers in a strict format the companion can act on |

## How one step works (Cursor mode)

1. You say: "I'm stuck, how do I add a dimension in Revit?"
2. The companion takes a screenshot (only of the screen you picked) and scales it down to save usage.
3. Claude gets the screenshot plus your words and answers in two parts: what to say, and where to point.

   ```json
   {"say": "Click the Annotate tab at the top.", "point": {"x": 412, "y": 38, "label": "Annotate"}, "next": "wait_for_click"}
   ```

4. The phone speaks "Click the Annotate tab at the top." The ghost cursor glides to (412, 38) and pulses.
5. When you click there, the companion notices (it watches clicks, not keystrokes) and takes a new screenshot, and the loop continues.

**Accuracy.** Claude is told the screenshot size and must answer in those pixels. The companion maps them back to the real screen, including scaling on high-resolution screens. If Claude is unsure, it says so ("I can't see the Annotate tab, is Revit full screen?") and doesn't point.

## PC mode (Claude acts)

The same loop, but the companion performs the step itself: move, click, type, scroll, shortcut.

Safety rules built in:

- A big **Stop** button on the phone and on screen. **Esc** pressed twice also stops.
- **Ask first** before anything that sends, buys, deletes, installs or closes without saving; you approve on the phone.
- It works only in apps you allow (for example Revit and File Explorer), never in password fields or banking sites.
- Every step is logged with its screenshot, so you can see what it did.

## Which Claude does it (lowest usage)

- **Cursor mode:** one free Sonnet sub-agent per conversation. Screenshots are the expensive part, so they go out at about 1280 px wide, and only when the screen changed. The manager (Opus) is used only if you ask for it.
- **PC mode:** the manager plans the steps once, and a sub-agent carries them out with screenshots. When a sub-agent hits its limit, the conversation is compressed and handed to the next one, as the app already does.
- The usage meters from the app apply here too.

## Build order

1. Companion skeleton: tray icon, pairing by QR code, screenshots, the ghost-cursor overlay with a test pattern.
2. Cursor mode with typed questions (no voice yet), then voice on the phone.
3. PC mode with the allow-list, Ask first and Stop.
4. Polish: several monitors, Mac version.

## Decisions (Oct 26)

- **Windows first**; Mac later.
- **Claude runs through the phone's containers**: one set of accounts and usage meters. The phone must be on the same Wi-Fi as the PC.
- **Voice on the phone, like a call**: phone mic and speaker. The PC only shows the ghost cursor (and, in PC mode, acts).
- **First apps (allow-list and test cases):** Revit, AutoCAD, ETABS, Robot Structural Analysis, Excel and Word, Windows and the browser, and the command prompt (cmd). In PC mode, commands typed into cmd always need your OK first.
