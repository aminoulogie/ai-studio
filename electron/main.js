'use strict';
// Windows desktop shell for AI Studio. It loads the same index.html used by the web and iOS builds.
// Native-only features (Claude browser containers, Keychain, iOS sign-in) are unavailable here,
// exactly as in a normal browser, so the app shows its existing "iOS only" messages.
const { app, BrowserWindow, shell } = require('electron');
const path = require('node:path');

const indexFile = path.join(__dirname, '..', 'index.html');

function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 850,
    minWidth: 420,
    minHeight: 600,
    title: 'AI Studio',
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false
    }
  });

  win.loadFile(indexFile);

  // Keep the app window on the local file; open any other link in the user's default browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file://')) {
      event.preventDefault();
      if (/^https:\/\//.test(url)) shell.openExternal(url);
    }
  });
}

// Only one instance at a time.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const [win] = BrowserWindow.getAllWindows();
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });
  app.whenReady().then(() => {
    createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });
  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
