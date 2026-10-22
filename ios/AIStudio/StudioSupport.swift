import Foundation
import WebKit
import UIKit

/// Only the app's main web view may invoke this bridge. No credentials are persisted here.
final class StudioRequests: NSObject, URLSessionTaskDelegate {
    private var tasks: [String: URLSessionDataTask] = [:]
    private let hosts: Set<String> = [
        "api.openai.com", "apikey.vnaipro.app", "openrouter.ai", "api.groq.com",
        "api.cerebras.ai", "router.huggingface.co", "api.sambanova.ai",
        "models.github.ai", "api.cohere.ai", "api.mistral.ai",
        "ai-gateway.vercel.sh", "text.pollinations.ai"
    ]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func send(_ message: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let id = message["id"] as? String, tasks[id] == nil, tasks.count < 4,
              let raw = message["url"] as? String, let url = URL(string: raw),
              url.scheme == "https", let host = url.host, hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasSuffix("/chat/completions") || url.path == "/v1/responses" || (host == "text.pollinations.ai" && url.path == "/openai"),
              let body = message["body"] as? String, let data = body.data(using: .utf8),
              data.count <= 2_000_000 else {
            reply(nil, "Unsupported AI request. Use a supported provider or the browser connection.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = message["key"] as? String, !key.isEmpty {
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            self?.tasks.removeValue(forKey: id)
            if let error = error {
                reply(["status": 0, "error": error.localizedDescription], nil)
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data,
                  data.count <= 8_000_000, let text = String(data: data, encoding: .utf8) else {
                reply(nil, "The provider response was too large or unreadable.")
                return
            }
            reply(["status": http.statusCode, "body": text], nil)
        }
        tasks[id] = task
        task.resume()
    }
    // Never forward a user's API key through a cross-origin redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https",
              request.url?.host == task.originalRequest?.url?.host else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

/// Whitelisted bundle images only; no filesystem or network access from URL parameters.
final class StudioArtwork: NSObject, WKURLSchemeHandler {
    private let names: Set<String> = ["aurora", "lagoon", "ember", "midnight"]
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requested = task.request.url, requested.host == "bundle",
              names.contains(requested.deletingPathExtension().lastPathComponent),
              ["png", "svg"].contains(requested.pathExtension),
              requested.pathComponents.count == 2 else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let ext = requested.pathExtension
        let directory = ext == "png" ? "www/artwork" : "www/assets/artwork"
        guard let url = Bundle.main.url(forResource: requested.deletingPathExtension().lastPathComponent,
                                       withExtension: ext, subdirectory: directory),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = URLResponse(url: requested, mimeType: ext == "png" ? "image/png" : "image/svg+xml",
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class StudioLaunchView: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor(red: 0.08, green: 0.09, blue: 0.19, alpha: 1).cgColor,
                           UIColor(red: 0.35, green: 0.29, blue: 0.66, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)
        let mark = UIImageView(image: UIImage(systemName: "sparkles"))
        mark.tintColor = .white; mark.contentMode = .scaleAspectFit
        mark.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let title = UILabel(); title.text = "AI Studio"
        title.font = .systemFont(ofSize: 30, weight: .semibold); title.textColor = .white
        title.textAlignment = .center
        let subtitle = UILabel(); subtitle.text = "A space for your next idea."
        subtitle.font = .systemFont(ofSize: 14); subtitle.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitle.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [mark, title, subtitle])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.8)])
        isAccessibilityElement = true; accessibilityLabel = "AI Studio is loading"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}
