import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        do {
            // GitHub storage must not prevent the independent Claude browser from opening.
            // An unsigned simulator can lack Keychain access; credential operations retry preparation.
            try? StudioCredentials.prepareInstallation()
            window?.rootViewController = StudioTabController(store: try ClaudeProfileStore())
        } catch {
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            let label = UILabel(frame: UIScreen.main.bounds.insetBy(dx: 24, dy: 80))
            label.numberOfLines = 0; label.textAlignment = .center
            label.text = "Could not load Claude profiles. Your stored containers have not been reset.\n\n" + error.localizedDescription
            controller.view.addSubview(label); window?.rootViewController = controller
        }
        window?.makeKeyAndVisible()
        return true
    }
}

class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private var webView: WKWebView!
    private var launchView: StudioLaunchView?
    private var requestedStudioTab = "code"
    private var studioLoaded = false
    private let updater = StudioUpdater.shared
    private var probeToken = 0
    private var probingVersion: Int?
    private let dictation = StudioDictation()
    /// The same memory file the Claude accounts use. Set by StudioTabController.
    var memoryStore: ClaudeProfileStore?
    func selectStudioTab(_ mode: String) {
        requestedStudioTab = mode
        if studioLoaded { applyStudioTab() }
    }
    private func applyStudioTab() {
        let open = requestedStudioTab == "settings" ? "window.openSettings && openSettings()" : ""
        let script = "window.STUDIO_REQUEST_TAB = '\(requestedStudioTab)'; if(window.studioInitialized) { " + open + "; window.syncMemoryFromNative && window.syncMemoryFromNative(); }"
        webView.evaluateJavaScript(script, completionHandler: nil)
        requestedStudioTab = "code"
    }

    /// Live Claude container updates for the Code tab.
    func emitClaude(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.onClaudeStream&&window.onClaudeStream(" + json + ")", completionHandler: nil)
    }
    /// Voice typing: the words so far, and whether listening has ended.
    func emitDictation(_ text: String, _ final: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text, "final": final]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.onDictation&&window.onDictation(" + json + ")", completionHandler: nil)
    }
    /// Container list changed (status, limit, manager, busy). The page asks for the new list.
    func emitProfilesChanged() {
        guard studioLoaded else { return }
        webView.evaluateJavaScript("window.onClaudeProfiles&&window.onClaudeProfiles()", completionHandler: nil)
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.STUDIO_NATIVE_TABS = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = .default() // keeps sessions and settings between launches
        config.allowsInlineMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // window.webkit.messageHandlers.native — the page's only way to reach native features
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let splash = StudioLaunchView(frame: view.bounds)
        splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(splash); launchView = splash
        updater.recoverFromInterruptedLaunch()
        loadStudio()
    }

    /// Loads the newest verified web bundle, or the one built into the app.
    /// A real https origin (not file://) keeps Puter sign-in and CORS working.
    private func loadStudio() {
        guard let content = updater.launchContent() else { return }
        probeToken += 1
        probingVersion = content.isUpdate ? content.version : nil
        webView.loadHTMLString(content.html, baseURL: URL(string: "https://aistudio.app/"))
    }

    private func reloadStudio() {
        studioLoaded = false
        loadStudio()
    }

    /// A downloaded bundle must prove itself: Studio sets window.studioInitialized when it starts.
    /// If that does not happen within about 10 seconds the update is dropped and the built-in page loads.
    private func probe(version: Int, token: Int, remaining: Int) {
        guard token == probeToken else { return }
        webView.evaluateJavaScript("window.studioInitialized === true") { [weak self] result, _ in
            guard let self = self, token == self.probeToken else { return }
            if (result as? Bool) == true {
                self.updater.confirmHealthy()
                self.probingVersion = nil
                return
            }
            if remaining <= 0 { self.abandonUpdate(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.probe(version: version, token: token, remaining: remaining - 1)
            }
        }
    }

    private func abandonUpdate() {
        updater.rollBack()
        probingVersion = nil
        reloadStudio()
    }

    private func githubToken() -> String? {
        try? StudioCredentials.prepareInstallation()
        guard let token = try? StudioCredentials.get("github"), !token.isEmpty else { return nil }
        return token
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        studioLoaded = true; applyStudioTab()
        if let version = probingVersion { probe(version: version, token: probeToken, remaining: 20) }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, animations: {
            self.launchView?.alpha = 0
        }, completion: { _ in self.launchView?.removeFromSuperview(); self.launchView = nil })
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, probingVersion != nil else { return }
        abandonUpdate()
    }

    // Open external links (e.g. "Get key ↗") in Safari instead of inside the app
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === self.webView, let url = action.request.url, url.scheme == "http" || url.scheme == "https",
           action.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Sign-in popups open in a sheet so they can talk back to the app
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        let vc = UIViewController()
        vc.view = popup
        (presentedViewController ?? self).present(vc, animated: true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView !== self.webView { dismiss(animated: true) }
    }

    // Backup file → iOS share sheet (Save to Files, AirDrop…)
    private func shareText(name: String, text: String, _ reply: @escaping (Any?, String?) -> Void) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { reply(nil, error.localizedDescription); return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.completionWithItemsHandler = { _, done, _, _ in try? FileManager.default.removeItem(at: url); reply(done, nil) }
        present(vc, animated: true)
    }

    // MARK: native bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "aistudio.app",
              let msg = message.body as? [String: Any], let op = msg["op"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let tabs = tabBarController as? StudioTabController
        switch op {
        case "selectStudioTab":
            guard let tab = msg["tab"] as? String, ["code", "settings"].contains(tab) else {
                replyHandler(nil, "Unsupported tab"); return
            }
            tabs?.selectStudioMode(tab)
            replyHandler(true, nil); return
        case "credentialGet", "credentialSet":
            guard msg["name"] as? String == "github" else { replyHandler(nil, "Unsupported credential"); return }
            do {
                try StudioCredentials.prepareInstallation()
                if op == "credentialGet" { replyHandler(try StudioCredentials.get("github"), nil) }
                else {
                    guard let value = msg["value"] as? String, value.utf8.count <= 32_000 else {
                        replyHandler(nil, "Invalid credential"); return
                    }
                    try StudioCredentials.set("github", value: value); replyHandler(true, nil)
                }
            } catch { replyHandler(nil, error.localizedDescription) }
            return
        case "memoryGet":
            replyHandler(memoryStore?.masterMemory ?? "", nil); return
        case "memorySet":
            guard let store = memoryStore, let text = msg["text"] as? String, text.utf8.count <= 40_000 else {
                replyHandler(nil, "Memory unavailable"); return
            }
            do { try store.setMasterMemory(text); replyHandler(store.masterMemory, nil) }
            catch { replyHandler(nil, error.localizedDescription) }
            return
        case "claudeProfiles":
            replyHandler(tabs?.claudeProfiles() ?? [], nil); return
        case "claudeSend":
            // A task with its files can be large; Claude's own message limit still applies.
            guard let text = msg["text"] as? String, !text.isEmpty, text.utf8.count <= 400_000, let host = tabs else {
                replyHandler(nil, "Nothing to send, or the message is too large"); return
            }
            host.startClaudeJob(msg, reply: replyHandler); return
        case "claudeStop":
            tabs?.stopClaudeJob(msg["id"] as? String); replyHandler(true, nil); return
        case "claudeSetManager":
            let raw = msg["profile"] as? String ?? ""
            guard raw.isEmpty || UUID(uuidString: raw) != nil, let host = tabs else { replyHandler(nil, "Unknown container"); return }
            do { try host.setClaudeManager(raw.isEmpty ? nil : UUID(uuidString: raw)); replyHandler(true, nil) }
            catch { replyHandler(nil, error.localizedDescription) }
            return
        case "claudeSetEnabled":
            guard let raw = msg["profile"] as? String, let id = UUID(uuidString: raw), let enabled = msg["enabled"] as? Bool, let host = tabs else {
                replyHandler(nil, "Unknown container"); return
            }
            do { try host.setClaudeEnabled(id, enabled); replyHandler(true, nil) } catch { replyHandler(nil, error.localizedDescription) }
            return
        case "dictateStart":
            dictation.onText = { [weak self] text, final in self?.emitDictation(text, final) }
            dictation.start(locale: msg["locale"] as? String) { error in
                if let error = error { replyHandler(nil, error) } else { replyHandler(true, nil) }
            }
            return
        case "dictateStop":
            dictation.stop(); replyHandler(true, nil); return
        case "openClaude":
            tabs?.openClaude(profile: msg["profile"] as? String, path: msg["path"] as? String); replyHandler(true, nil); return
        case "claudeUsage":
            guard let host = tabs else { replyHandler(nil, "Unavailable"); return }
            host.claudeUsage(msg["profile"] as? String, reply: replyHandler); return
        case "studioUpdateStatus":
            replyHandler(updater.status(), nil); return
        case "studioUpdateCheck":
            updater.check(token: githubToken()) { result in
                switch result {
                case .success(let info): replyHandler(info, nil)
                case .failure(let error): replyHandler(nil, error.localizedDescription)
                }
            }
            return
        case "studioUpdateInstall":
            updater.install(token: githubToken()) { result in
                switch result {
                case .success(let info): replyHandler(info, nil)
                case .failure(let error): replyHandler(nil, error.localizedDescription)
                }
            }
            return
        case "studioUpdateReload":
            replyHandler(true, nil)
            DispatchQueue.main.async { [weak self] in self?.reloadStudio() }
            return
        case "studioUpdateReset":
            updater.reset()
            replyHandler(true, nil)
            DispatchQueue.main.async { [weak self] in self?.reloadStudio() }
            return
        case "share":
            shareText(name: msg["name"] as? String ?? "export.txt", text: msg["text"] as? String ?? "", replyHandler); return
        default: break
        }
        guard let clientId = msg["clientId"] as? String, !clientId.isEmpty else { replyHandler(nil, "missing client id"); return }
        switch op {
        case "githubDeviceCode":
            postForm("https://github.com/login/device/code", ["client_id": clientId, "scope": "repo"], replyHandler)
        case "githubToken":
            postForm("https://github.com/login/oauth/access_token",
                     ["client_id": clientId, "device_code": msg["deviceCode"] as? String ?? "",
                      "grant_type": "urn:ietf:params:oauth:grant-type:device_code"], replyHandler)
        default:
            replyHandler(nil, "unknown op")
        }
    }

    // GitHub's sign-in endpoints don't allow browser (CORS) calls, so these two go through native code
    private func postForm(_ url: String, _ fields: [String: String], _ reply: @escaping (Any?, String?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let err = err { reply(nil, err.localizedDescription); return }
                reply(String(data: data ?? Data(), encoding: .utf8) ?? "", nil)
            }
        }.resume()
    }

    // JS alert / confirm / prompt support
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}
