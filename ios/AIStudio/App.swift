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
        window?.rootViewController = WebViewController()
        window?.makeKeyAndVisible()
        return true
    }
}

class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply, ASWebAuthenticationPresentationContextProviding {
    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
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
        // Load with a real https origin (not file://) so Puter sign-in and CORS work
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        webView.loadHTMLString(html, baseURL: URL(string: "https://aistudio.app/"))
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

    // MARK: sign-in bridge
    private var authSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              let msg = message.body as? [String: Any], let op = msg["op"] as? String,
              let clientId = msg["clientId"] as? String, !clientId.isEmpty else {
            replyHandler(nil, "bad message"); return
        }
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
