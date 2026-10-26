import Foundation
import CryptoKit

/// One build of Studio's web layer: the single processed index.html the app shows.
/// CI publishes it next to the IPA as studio-web.html + studio-web.json (this manifest).
struct StudioWebManifest: Codable, Equatable {
    let version: Int
    let sha256: String
    let size: Int
    let minNative: Int
    /// Optional: the Claude-tab helper script (claude-observer.js) that ships with this web version.
    var observerSha256: String? = nil
    var observerSize: Int? = nil
    enum CodingKeys: String, CodingKey {
        case version, sha256, size, minNative = "min_native"
        case observerSha256 = "observer_sha256", observerSize = "observer_size"
    }
}

extension Notification.Name {
    /// Posted when the verified Claude helper script changes (downloaded, reset or rolled back).
    static let studioObserverUpdated = Notification.Name("StudioObserverUpdated")
}

struct StudioLaunchContent {
    let html: String
    let version: Int
    let isUpdate: Bool
}

struct StudioRelease {
    let version: Int
    let manifestURL: URL
    let htmlURL: URL
    var observerURL: URL? = nil
}

enum StudioUpdateError: LocalizedError {
    case network(String)
    case noRelease
    case needsNewApp(required: Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .noRelease: return "No web update has been published yet."
        case .needsNewApp: return "This update needs a newer app build. Install the latest IPA once, then web updates work again."
        case .invalid(let message): return message
        }
    }
}

/// Updates the Studio web layer without a new signed IPA. Native code is never replaced.
/// A downloaded page is only used when its size and SHA-256 match the manifest, it is compatible
/// with this build's native level, and it proves it started (window.studioInitialized) after launch.
final class StudioUpdater {
    /// Bump together with `min_native` in .github/workflows/ios.yml whenever App.swift gains or
    /// changes a native op. tests/ota-update.cjs fails until both are updated.
    static let nativeLevel = 3
    static let repo = "aminoulogie/ai-studio"
    static let maxBytes = 24_000_000
    static let manifestName = "studio-web.json"
    static let htmlName = "studio-web.html"
    static let observerName = "studio-observer.js"
    static let maxObserverBytes = 400_000
    /// One updater for the whole app, so the Claude browser reads the same verified files as the Studio page.
    static let shared = StudioUpdater()

    private enum Keys {
        static let pending = "studio.web.pending"
        static let bad = "studio.web.bad"
    }

    private let directory: URL
    private let defaults: UserDefaults
    private let builtIn: () -> StudioWebManifest?
    private let bundledHTML: () -> String?
    private let network = StudioUpdateNetwork()
    private var candidate: (manifest: StudioWebManifest, htmlURL: URL, observerURL: URL?)?
    private(set) var runningVersion = 0

    init(directory: URL? = nil,
         defaults: UserDefaults = .standard,
         builtIn: @escaping () -> StudioWebManifest? = StudioUpdater.readBundledManifest,
         bundledHTML: @escaping () -> String? = StudioUpdater.readBundledHTML) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("StudioWeb", isDirectory: true)
        self.defaults = defaults
        self.builtIn = builtIn
        self.bundledHTML = bundledHTML
    }

    private var htmlFile: URL { directory.appendingPathComponent("index.html") }
    private var observerFile: URL { directory.appendingPathComponent("observer.js") }
    private var manifestFile: URL { directory.appendingPathComponent("manifest.json") }

    // MARK: bundled copy

    static func readBundledManifest() -> StudioWebManifest? {
        guard let url = Bundle.main.url(forResource: "studio-web", withExtension: "json", subdirectory: "www"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StudioWebManifest.self, from: data)
    }

    static func readBundledHTML() -> String? {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: pure helpers (unit tested)

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Release tags look like v1.0.97; the last number is the CI run number and the web version.
    static func version(fromTag tag: String) -> Int? {
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = trimmed.split(separator: ".")
        guard parts.count == 3, parts[0] == "1", parts[1] == "0", let number = Int(parts[2]), number > 0 else { return nil }
        return number
    }

    /// Newest non-draft release that carries both web assets, with asset links on api.github.com only.
    static func pickRelease(from data: Data) -> StudioRelease? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var best: StudioRelease?
        for item in list {
            if (item["draft"] as? Bool) == true { continue }
            guard let tag = item["tag_name"] as? String, let number = version(fromTag: tag),
                  let assets = item["assets"] as? [[String: Any]] else { continue }
            func link(_ name: String) -> URL? {
                guard let asset = assets.first(where: { ($0["name"] as? String) == name }),
                      let raw = asset["url"] as? String, let url = URL(string: raw),
                      url.scheme == "https", url.host == "api.github.com" else { return nil }
                return url
            }
            guard let manifestURL = link(manifestName), let htmlURL = link(htmlName) else { continue }
            if best == nil || number > (best?.version ?? 0) {
                best = StudioRelease(version: number, manifestURL: manifestURL, htmlURL: htmlURL, observerURL: link(observerName))
            }
        }
        return best
    }

    static func canInstall(_ remote: StudioWebManifest, current: Int, bad: Set<Int>) -> Bool {
        remote.version > current && !bad.contains(remote.version) && remote.minNative <= nativeLevel
    }

    static func validate(_ manifest: StudioWebManifest, data: Data) throws {
        guard manifest.minNative <= nativeLevel else { throw StudioUpdateError.needsNewApp(required: manifest.minNative) }
        guard !data.isEmpty, data.count <= maxBytes, data.count == manifest.size else {
            throw StudioUpdateError.invalid("The downloaded update has the wrong size.")
        }
        guard sha256Hex(data) == manifest.sha256.lowercased() else {
            throw StudioUpdateError.invalid("The downloaded update failed its integrity check.")
        }
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<html", options: .caseInsensitive) != nil,
              text.contains("studioInitialized") else {
            throw StudioUpdateError.invalid("The downloaded file is not a Studio page.")
        }
    }

    /// The Claude-tab helper script must match the manifest's size and SHA-256 and look like our script.
    static func validateObserver(_ manifest: StudioWebManifest, data: Data) throws {
        guard let expected = manifest.observerSha256, let size = manifest.observerSize else {
            throw StudioUpdateError.invalid("This update has no Claude helper script.")
        }
        guard !data.isEmpty, data.count <= maxObserverBytes, data.count == size else {
            throw StudioUpdateError.invalid("The Claude helper script has the wrong size.")
        }
        guard sha256Hex(data) == expected.lowercased() else {
            throw StudioUpdateError.invalid("The Claude helper script failed its integrity check.")
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("claudeObserver"), text.contains("claudeSubmit") else {
            throw StudioUpdateError.invalid("The downloaded file is not the Claude helper script.")
        }
    }

    // MARK: installed update

    func badVersions() -> Set<Int> {
        Set((defaults.array(forKey: Keys.bad) as? [Int]) ?? [])
    }

    private func markBad(_ version: Int) {
        var all = badVersions()
        all.insert(version)
        defaults.set(Array(all).sorted(), forKey: Keys.bad)
    }

    /// The stored update, only if both files are intact and compatible with this build.
    func installed() -> (manifest: StudioWebManifest, html: String)? {
        guard let manifestData = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(StudioWebManifest.self, from: manifestData),
              manifest.minNative <= Self.nativeLevel,
              let data = try? Data(contentsOf: htmlFile),
              data.count == manifest.size,
              Self.sha256Hex(data) == manifest.sha256.lowercased(),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return (manifest, html)
    }

    func store(_ manifest: StudioWebManifest, data: Data, observer: Data? = nil) throws {
        try Self.validate(manifest, data: data)
        if manifest.observerSha256 != nil {
            guard let observer = observer else {
                throw StudioUpdateError.invalid("The update is missing its Claude helper script.")
            }
            try Self.validateObserver(manifest, data: observer)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Remove the old manifest first so a half-written set is never trusted.
        try? fm.removeItem(at: manifestFile)
        try? fm.removeItem(at: observerFile)
        if manifest.observerSha256 != nil, let observer = observer {
            try observer.write(to: observerFile, options: .atomic)
        }
        try data.write(to: htmlFile, options: .atomic)
        try JSONEncoder().encode(manifest).write(to: manifestFile, options: .atomic)
        if manifest.observerSha256 != nil {
            NotificationCenter.default.post(name: .studioObserverUpdated, object: nil)
        }
    }

    /// The verified Claude-tab helper script that came with the stored update, if it is newer than the built-in one.
    func observerSource() -> String? {
        guard let stored = installed(),
              !badVersions().contains(stored.manifest.version),
              stored.manifest.version > (builtIn()?.version ?? 0),
              let data = try? Data(contentsOf: observerFile),
              (try? Self.validateObserver(stored.manifest, data: data)) != nil,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func removeInstalled() {
        try? FileManager.default.removeItem(at: manifestFile)
        try? FileManager.default.removeItem(at: htmlFile)
        try? FileManager.default.removeItem(at: observerFile)
        NotificationCenter.default.post(name: .studioObserverUpdated, object: nil)
    }

    private func currentVersion() -> Int {
        let base = builtIn()?.version ?? 0
        guard let stored = installed(), !badVersions().contains(stored.manifest.version) else { return base }
        return max(base, stored.manifest.version)
    }

    // MARK: launch and rollback

    /// Call once at app start. If the last launch loaded a downloaded page and never confirmed it
    /// (crash, hang, kill), that version is marked bad and the built-in page is used.
    func recoverFromInterruptedLaunch() {
        if defaults.object(forKey: Keys.pending) != nil { rollBack() }
    }

    func launchContent() -> StudioLaunchContent? {
        let base = builtIn()?.version ?? 0
        if let stored = installed(), stored.manifest.version > base, !badVersions().contains(stored.manifest.version) {
            defaults.set(stored.manifest.version, forKey: Keys.pending)
            runningVersion = stored.manifest.version
            return StudioLaunchContent(html: stored.html, version: stored.manifest.version, isUpdate: true)
        }
        guard let html = bundledHTML() else { return nil }
        defaults.removeObject(forKey: Keys.pending)
        runningVersion = base
        return StudioLaunchContent(html: html, version: base, isUpdate: false)
    }

    func confirmHealthy() {
        defaults.removeObject(forKey: Keys.pending)
    }

    func rollBack() {
        if let pending = defaults.object(forKey: Keys.pending) as? Int { markBad(pending) }
        removeInstalled()
        defaults.removeObject(forKey: Keys.pending)
    }

    func reset() {
        removeInstalled()
        defaults.removeObject(forKey: Keys.pending)
    }

    // MARK: status and network

    func status() -> [String: Any] {
        var out: [String: Any] = [
            "builtIn": builtIn()?.version ?? 0,
            "running": runningVersion,
            "nativeLevel": Self.nativeLevel,
            "bad": badVersions().sorted()
        ]
        if let stored = installed(), !badVersions().contains(stored.manifest.version) {
            out["installed"] = stored.manifest.version
        }
        return out
    }

    private func report(for remote: StudioWebManifest) -> [String: Any] {
        var out = status()
        let current = currentVersion()
        out["available"] = remote.version
        out["needsNewApp"] = remote.minNative > Self.nativeLevel
        out["upToDate"] = remote.version <= current
        out["canInstall"] = Self.canInstall(remote, current: current, bad: badVersions())
        return out
    }

    func check(token: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let listURL = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=30") else {
            completion(.failure(StudioUpdateError.invalid("Bad update address."))); return
        }
        network.get(listURL, token: token, accept: "application/vnd.github+json", maxBytes: 4_000_000) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                guard let release = Self.pickRelease(from: data) else {
                    completion(.failure(StudioUpdateError.noRelease)); return
                }
                self.network.get(release.manifestURL, token: token, accept: "application/octet-stream", maxBytes: 20_000) { [weak self] manifestResult in
                    guard let self = self else { return }
                    switch manifestResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let body):
                        guard let remote = try? JSONDecoder().decode(StudioWebManifest.self, from: body),
                              remote.version == release.version else {
                            completion(.failure(StudioUpdateError.invalid("The update manifest is unreadable."))); return
                        }
                        self.candidate = (remote, release.htmlURL, release.observerURL)
                        completion(.success(self.report(for: remote)))
                    }
                }
            }
        }
    }

    func install(token: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if candidate != nil { download(token: token, completion: completion); return }
        check(token: token) { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: self?.download(token: token, completion: completion)
            }
        }
    }

    private func download(token: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let chosen = candidate else { completion(.failure(StudioUpdateError.noRelease)); return }
        guard Self.canInstall(chosen.manifest, current: currentVersion(), bad: badVersions()) else {
            if chosen.manifest.minNative > Self.nativeLevel {
                completion(.failure(StudioUpdateError.needsNewApp(required: chosen.manifest.minNative)))
            } else {
                completion(.failure(StudioUpdateError.invalid("You already have the latest web version.")))
            }
            return
        }
        network.get(chosen.htmlURL, token: token, accept: "application/octet-stream", maxBytes: Self.maxBytes) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                self.fetchObserver(for: chosen.manifest, from: chosen.observerURL, token: token) { observerResult in
                    switch observerResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let script):
                        do {
                            try self.store(chosen.manifest, data: data, observer: script)
                            completion(.success(self.status()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    /// The helper script is optional: older releases do not carry one.
    private func fetchObserver(for manifest: StudioWebManifest, from url: URL?, token: String?,
                               completion: @escaping (Result<Data?, Error>) -> Void) {
        guard manifest.observerSha256 != nil else { completion(.success(nil)); return }
        guard let url = url else {
            completion(.failure(StudioUpdateError.invalid("The update is missing its Claude helper script."))); return
        }
        network.get(url, token: token, accept: "application/octet-stream", maxBytes: Self.maxObserverBytes) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let body): completion(.success(body))
            }
        }
    }
}

/// GitHub only. The optional token is never forwarded to another host.
final class StudioUpdateNetwork: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    static func allowed(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "api.github.com" || host == "github.com" || host.hasSuffix(".github.com")
            || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    static func describe(status: Int) -> String {
        switch status {
        case 401, 403: return "GitHub refused the request (rate limit or token permissions). Try again later or reconnect GitHub."
        case 404: return "GitHub could not find the releases. If the repository is private, connect GitHub first."
        default: return "GitHub answered with status \(status)."
        }
    }

    func get(_ url: URL, token: String?, accept: String, maxBytes: Int,
             completion: @escaping (Result<Data, Error>) -> Void) {
        guard url.scheme == "https", url.host == "api.github.com" else {
            completion(.failure(StudioUpdateError.invalid("Blocked an unexpected update address."))); return
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AIStudio-Updater", forHTTPHeaderField: "User-Agent")
        if let token = token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(StudioUpdateError.network(error.localizedDescription))); return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(StudioUpdateError.network("No response from GitHub."))); return
            }
            if http.statusCode == 401, let token = token, !token.isEmpty, let self = self {
                // A stale token must not block a public repository.
                self.get(url, token: nil, accept: accept, maxBytes: maxBytes, completion: completion); return
            }
            guard http.statusCode == 200, let data = data else {
                completion(.failure(StudioUpdateError.network(StudioUpdateNetwork.describe(status: http.statusCode)))); return
            }
            guard data.count <= maxBytes else {
                completion(.failure(StudioUpdateError.invalid("The download was larger than allowed."))); return
            }
            completion(.success(data))
        }.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", Self.allowed(host: url.host) else {
            completionHandler(nil); return
        }
        var next = request
        if url.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}
