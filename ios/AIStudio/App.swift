import UIKit
import WebKit
import AuthenticationServices
import CryptoKit

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

class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply, ASWebAuthenticationPresentationContextProviding {
    private var webView: WKWebView!
    private let studioRequests = StudioRequests()
    private let studioArtwork = StudioArtwork()
    private var launchView: StudioLaunchView?
    private var requestedStudioTab = "chat"
    private var studioLoaded = false
    private let updater = StudioUpdater.shared
    private var probeToken = 0
    private var probingVersion: Int?
    /// The same memory file the Claude accounts use. Set by StudioTabController.
    var memoryStore: ClaudeProfileStore?
    func selectStudioTab(_ mode: String) {
        requestedStudioTab = mode
        if studioLoaded { applyStudioTab() }
    }
    private func applyStudioTab() {
        let script = "window.STUDIO_REQUEST_TAB = '\(requestedStudioTab)'; if(window.studioInitialized) { " + (requestedStudioTab == "settings" ? "openStudioSettings()" : "switchTab('\(requestedStudioTab)')") + "; window.syncMemoryFromNative && window.syncMemoryFromNative(); }"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Live Claude container updates for the Code tab.
    func emitClaude(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.onClaudeStream&&window.onClaudeStream(" + json + ")", completionHandler: nil)
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(studioArtwork, forURLScheme: "studio-art")
        config.userContentController.addUserScript(WKUserScript(source: "window.STUDIO_NATIVE_TABS = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = .default() // keeps your key + chats between launches
        config.allowsInlineMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // window.webkit.messageHandlers.native — sign-in helpers only (fixed endpoints)
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

    // Sign-in popups (Puter etc.) open in a sheet so they can talk back to the app
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

    // MARK: sign-in bridge
    private var authSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "aistudio.app",
              let msg = message.body as? [String: Any], let op = msg["op"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        switch op {
        case "selectStudioTab":
            guard let tab = msg["tab"] as? String, ["chat", "code", "github", "settings"].contains(tab) else {
                replyHandler(nil, "Unsupported tab"); return
            }
            (tabBarController as? StudioTabController)?.selectStudioMode(tab)
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
        case "claudeSend":
            guard let id = msg["id"] as? String, !id.isEmpty, id.utf8.count <= 64,
                  let text = msg["text"] as? String, !text.isEmpty, text.utf8.count <= 40_000,
                  let tabs = tabBarController as? StudioTabController else {
                replyHandler(nil, "Nothing to send"); return
            }
            tabs.startClaudeJob(id: id, text: text, reply: replyHandler); return
        case "claudeStop":
            (tabBarController as? StudioTabController)?.stopClaudeJob(); replyHandler(true, nil); return
        case "sendToClaude":
            guard let text = msg["text"] as? String, !text.isEmpty, text.utf8.count <= 40_000,
                  let tabs = tabBarController as? StudioTabController else {
                replyHandler(nil, "Nothing to send"); return
            }
            tabs.sendToClaude(text, reply: replyHandler); return
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
        case "aiRequest":
            studioRequests.send(msg, reply: replyHandler); return
        case "cancelRequest":
            studioRequests.cancel(msg["id"] as? String ?? ""); replyHandler(true, nil); return
        case "share":
            shareText(name: msg["name"] as? String ?? "backup.txt", text: msg["text"] as? String ?? "", replyHandler); return
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
        case "google":
            googleSignIn(clientId: clientId, replyHandler)
        case "googleRefresh":
            postForm("https://oauth2.googleapis.com/token",
                     ["client_id": clientId, "refresh_token": msg["refreshToken"] as? String ?? "",
                      "grant_type": "refresh_token"], replyHandler)
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

    // Google sign-in with PKCE in the system sheet (iOS client IDs need no secret); Drive read-only
    private func googleSignIn(clientId: String, _ reply: @escaping (Any?, String?) -> Void) {
        let prefix = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let scheme = "com.googleusercontent.apps." + prefix
        let redirect = scheme + ":/oauth2redirect"
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let b64url = { (d: Data) in d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = b64url(Data(bytes))
        let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientId), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.readonly"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        authSession = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { [weak self] callback, err in
            guard let callback = callback,
                  let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                reply(nil, err?.localizedDescription ?? "Sign-in cancelled"); return
            }
            self?.postForm("https://oauth2.googleapis.com/token",
                           ["client_id": clientId, "code": code, "code_verifier": verifier,
                            "redirect_uri": redirect, "grant_type": "authorization_code"], reply)
        }
        authSession?.presentationContextProvider = self
        authSession?.start()
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
