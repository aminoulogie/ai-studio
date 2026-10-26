# AI Studio Companion (Windows)

Pairs your PC with the AI Studio iPhone app for **Cursor call**: you talk on the phone, Claude looks at your
screen, and a terracotta ghost cursor on the PC shows where to click. The companion never clicks or types for you.

## Install

1. Download `AIStudio-Companion-…-win-x64.zip` from the latest `pc-v…` GitHub release.
2. Unzip it anywhere and run **AI Studio Companion.exe**. Windows may say it is from an unknown publisher:
   choose *More info → Run anyway* (the app is not code-signed).
3. When Windows Firewall asks, allow it on **Private networks**.

## Pair

On the iPhone: **+ → Cursor call**, then type the address and 6-digit code the companion shows. The phone and
the PC must be on the same Wi-Fi. **New code** disconnects the phone and makes a fresh code.

## What travels where

- The phone asks for a screenshot of the main screen at each step (scaled to 1280 px, the ghost cursor hidden).
- The phone sends it with your words to one of your free Claude containers and sends back where to point.
- Everything stays on your Wi-Fi between the phone and the PC; nothing goes through a server of ours.
  The link is not encrypted, so pair only on networks you trust (home or office, not public Wi-Fi).

## Build it yourself

```
cd pc
npm install
npm start            # run from source
npm run dist         # dist/AIStudio-Companion-1.0.0-win-x64.zip
```
