import UIKit
import WebKit
import UniformTypeIdentifiers

/// A profile owns a persistent WebKit data store, not a shared system-browser cookie jar.
final class ClaudeBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, UIDocumentPickerDelegate {
    private let store: ClaudeProfileStore
    private let observerWorld = WKContentWorld.world(name: "ClaudeVisiblePageObserver")
    private var browsers: [UUID: WKWebView] = [:]
    private var popupBrowsers: [WKWebView] = []
    private var currentID: UUID?
    private var rotationVisited: Set<UUID> = []
    private var switching = false
    /// Several containers can each run one Code task at the same time (lead + sub-agents).
    private var codePendings: [String: ClaudeCodePending] = [:]
    private var codeTimer: Timer?
    var onCodeEvent: (([String: Any]) -> Void)?
    private let surface = UIView()
    /// Web views with a running task live here, attached to the window behind the app UI, so iOS keeps them active.
    private let parking = UIView()
    private let empty = UILabel()
    private var accountsButton: UIBarButtonItem!
    private var actionsButton: UIBarButtonItem!
    private var currentBrowser: WKWebView? { currentID.flatMap { browsers[$0] } }

    init(store: ClaudeProfileStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.setToolbarHidden(false, animated: false)
        if let id = currentID, let web = browsers[id], web.superview !== surface { attachToSurface(web) }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let id = currentID, hasPending(id), let web = browsers[id] { park(web) }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        empty.text = "Claude accounts\n\nAdd an account from the Accounts menu, then sign in on claude.ai.\n\nEach account has its own cookies and storage. Models and usage limits are set by Claude."
        empty.numberOfLines = 0; empty.textAlignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: surface.widthAnchor, multiplier: 0.82)
        ])
        accountsButton = UIBarButtonItem(title: "Accounts", image: UIImage(systemName: "person.crop.circle"), primaryAction: nil, menu: nil)
        actionsButton = UIBarButtonItem(title: "Actions", image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: nil)
        navigationItem.leftBarButtonItem = accountsButton
        navigationItem.rightBarButtonItem = actionsButton
        toolbarItems = [
            UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(back)),
            UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: self, action: #selector(forward)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(reloadPage)),
            .flexibleSpace(),
            UIBarButtonItem(title: "Limit → Next", style: .plain, target: self, action: #selector(manualLimit)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(newChat))
        ]
        toolbarItems?[0].accessibilityLabel = "Back"
        toolbarItems?[1].accessibilityLabel = "Forward"
        toolbarItems?[3].accessibilityLabel = "Reload"
        toolbarItems?.last?.accessibilityLabel = "New Claude chat"
        navigationController?.setToolbarHidden(false, animated: false)
        refreshMenus()
        if let selected = store.state.selected, store.state.profiles.contains(where: { $0.id == selected }) {
            show(selected)
        }
    }

    private func makeBrowser(_ profile: ClaudeProfile) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.id)
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(self, contentWorld: observerWorld, name: "claudeObserver")
        if let url = Bundle.main.url(forResource: "claude-observer", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: observerWorld))
        }
        if let url = Bundle.main.url(forResource: "claude-code-dom", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: observerWorld))
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.accessibilityLabel = "Claude browser for " + profile.name
        web.load(URLRequest(url: safeClaudeURL(profile.lastURL) ?? URL(string: "https://claude.ai/")!))
        return web
    }

    private func safeClaudeURL(_ url: URL?) -> URL? {
        guard let url = url, url.scheme == "https", url.host == "claude.ai",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    // MARK: web view placement
    private func hasPending(_ id: UUID) -> Bool { codePendings.values.contains { $0.profileID == id } }

    private func attachToSurface(_ web: WKWebView) {
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: surface.leadingAnchor), web.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            web.topAnchor.constraint(equalTo: surface.topAnchor), web.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
    }
    private func parkingHost() -> UIView {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }
        if let window = window {
            if parking.superview !== window {
                parking.removeFromSuperview()
                parking.frame = window.bounds; parking.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                parking.isUserInteractionEnabled = false; parking.alpha = 0.02
                window.insertSubview(parking, at: 0)
            }
        } else if parking.superview == nil {
            parking.frame = view.bounds; parking.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parking.isUserInteractionEnabled = false; parking.alpha = 0.02
            view.insertSubview(parking, at: 0)
        }
        return parking
    }
    private func park(_ web: WKWebView) {
        let host = parkingHost()
        if web.superview === host { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor), web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor), web.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
    private func releaseFromSurface(_ id: UUID) {
        guard let web = browsers[id] else { return }
        if hasPending(id) { park(web) } else { web.removeFromSuperview() }
    }
    private func releaseIfIdle(_ id: UUID) {
        guard id != currentID, !hasPending(id), let web = browsers[id] else { return }
        web.removeFromSuperview()
    }
    /// Make sure a container's web view exists and stays live without changing which account the Claude tab shows.
    private func ensureBrowser(_ id: UUID) -> WKWebView? {
        guard let profile = store.state.profiles.first(where: { $0.id == id }) else { return nil }
        let web: WKWebView
        if let existing = browsers[id] { web = existing } else { web = makeBrowser(profile); browsers[id] = web }
        let visibleHere = id == currentID && viewIfLoaded?.window != nil
        if !visibleHere { park(web) }
        return web
    }

    private func show(_ id: UUID, automatic: Bool = false) {
        guard let profile = store.state.profiles.first(where: { $0.id == id }) else { return }
        do { try store.select(id) } catch { report(error); return }
        if let previous = currentID { releaseFromSurface(previous) }
        if !automatic { rotationVisited.removeAll() }
        currentID = id
        let web: WKWebView
        if let existing = browsers[id] { web = existing }
        else { web = makeBrowser(profile); browsers[id] = web }
        attachToSurface(web)
        empty.isHidden = true
        if automatic { web.load(URLRequest(url: URL(string: "https://claude.ai/new")!)) }
        else { web.evaluateJavaScript("globalThis.claudeCheckLimits?.()", in: nil, in: observerWorld, completionHandler: nil) }
        refreshMenus()
    }

    // MARK: usage
    private func usageText(_ profile: ClaudeProfile) -> String {
        let usage = store.usage(profile)
        let filled = max(0, min(10, usage.percent / 10))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 10 - filled) + " \(usage.percent)%"
    }
    private func usageDetail(_ profile: ClaudeProfile) -> String {
        let usage = store.usage(profile)
        var text = "\(usage.used) of \(usage.source == "manual" ? "" : "~")\(usage.limit) messages sent from this app in the 5-hour window"
        if let seconds = usage.resetsIn, seconds > 0 {
            let minutes = Int(seconds / 60)
            text += " · resets in " + (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m")
        }
        return text
    }

    private func refreshMenus() {
        let selected = store.state.profiles.first { $0.id == currentID }
        title = selected?.name ?? "Claude"
        navigationItem.prompt = currentBrowser?.url?.host ?? "Official claude.ai browser"
        accountsButton.menu = UIMenu(title: "Isolated Claude accounts", children:
            store.state.profiles.map { profile in
                UIAction(title: profile.name,
                         subtitle: store.status(profile).rawValue + (profile.enabled ? "" : " · Paused") + " · " + usageText(profile),
                         image: UIImage(systemName: "person.crop.circle"),
                         state: profile.id == currentID ? .on : .off) { [weak self] _ in self?.show(profile.id) }
            } + [UIAction(title: "Add account", image: UIImage(systemName: "plus")) { [weak self] _ in self?.addAccount() }])
        actionsButton.menu = UIMenu(children: [
            UIAction(title: "Account settings", image: UIImage(systemName: "person.crop.circle.badge.gearshape")) { [weak self] _ in self?.accountSettings() },
            UIAction(title: "Auto-switch on detected limit", state: store.state.autoSwitch ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                do { try self.store.setAutoSwitch(!self.store.state.autoSwitch); self.refreshMenus() } catch { self.report(error) }
            },
            UIAction(title: "Export visible chat · JSON", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportContext(markdown: false) },
            UIAction(title: "Export visible chat · Markdown") { [weak self] _ in self?.exportContext(markdown: true) },
            UIAction(title: "Copy latest handover", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyHandover() },
            UIAction(title: "Edit continuation notes") { [weak self] _ in self?.editNotes() },
            UIAction(title: "Import context JSON", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.importContext() },
            UIAction(title: "About context handover", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.notice("Conversation handover", "Exports contain the text currently rendered by Claude. Scroll to load earlier messages before exporting. Attachments, hidden reasoning, projects and server-side context are not included. Copy or upload the export into the next account and send it yourself. Models and free-tier limits are controlled by Claude.")
            }
        ])
    }

    @objc private func back() { currentBrowser?.goBack() }
    @objc private func forward() { currentBrowser?.goForward() }
    @objc private func reloadPage() { rotationVisited.removeAll(); currentBrowser?.reload() }
    @objc private func newChat() { rotationVisited.removeAll(); currentBrowser?.load(URLRequest(url: URL(string: "https://claude.ai/new")!)) }
    @objc private func manualLimit() {
        guard let id = currentID else { return }
        captureVisible { [weak self] context in self?.handleLimit(id: id, context: context, manual: true) }
    }

    private func addAccount() {
        let alert = UIAlertController(title: "Add Claude account", message: "Use a label you recognize. Sign in on the official site; the app never asks for your Claude password.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Account name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            do { let profile = try self.store.add(name: alert?.textFields?.first?.text ?? ""); self.show(profile.id) }
            catch { self.report(error) }
        })
        present(alert, animated: true)
    }

    private func accountSettings() {
        if !codePendings.isEmpty { notice("Code task is running", "Stop it in the Code tab before changing account settings."); return }
        guard let id = currentID, let p = store.state.profiles.first(where: { $0.id == id }) else { addAccount(); return }
        let sheet = UIAlertController(title: p.name, message: store.status(p).rawValue + "\n" + usageText(p) + "\n" + usageDetail(p) + "\nLimit reset defaults to five hours from detection; use Reset limit when Claude allows messages again.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Mark signed in / Reset limit", style: .default) { [weak self] _ in
            self?.change(id) { $0.status = .active; $0.limitedUntil = nil; $0.windowStart = nil; $0.windowCount = nil }
        })
        sheet.addAction(UIAlertAction(title: "Set limit estimate…", style: .default) { [weak self] _ in self?.editLimitEstimate(id) })
        sheet.addAction(UIAlertAction(title: p.enabled ? "Pause rotation" : "Enable rotation", style: .default) { [weak self] _ in self?.change(id) { $0.enabled.toggle() } })
        sheet.addAction(UIAlertAction(title: "Move earlier in rotation", style: .default) { [weak self] _ in
            do { try self?.store.move(id, by: -1); self?.refreshMenus() } catch { self?.report(error) }
        })
        sheet.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in self?.rename(id, name: p.name) })
        sheet.addAction(UIAlertAction(title: "Log out / Clear this container", style: .destructive) { [weak self] _ in self?.confirmClear(id, remove: false) })
        sheet.addAction(UIAlertAction(title: "Remove account", style: .destructive) { [weak self] _ in self?.confirmClear(id, remove: true) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = actionsButton
        present(sheet, animated: true)
    }
    private func editLimitEstimate(_ id: UUID) {
        let alert = UIAlertController(title: "Messages per 5 hours",
                                      message: "Claude does not publish exact limits. Enter your own estimate, or leave it empty to learn it from when this account gets limited.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "Automatic" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            do {
                try self?.store.setLimitEstimate(id, Int(alert?.textFields?.first?.text ?? ""))
                self?.refreshMenus()
            } catch { self?.report(error) }
        })
        present(alert, animated: true)
    }
    private func rename(_ id: UUID, name: String) {
        let alert = UIAlertController(title: "Account name", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let label = String((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if !label.isEmpty { self?.change(id) { $0.name = label } }
        })
        present(alert, animated: true)
    }
    private func change(_ id: UUID, _ body: (inout ClaudeProfile) -> Void) {
        do { try store.update(id, body); refreshMenus() } catch { report(error) }
    }
    private func confirmClear(_ id: UUID, remove: Bool) {
        let alert = UIAlertController(title: remove ? "Remove account?" : "Log out this account?",
                                      message: "This clears cookies, login state, storage and cache for this container only.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear container", style: .destructive) { [weak self] _ in self?.clearContainer(id, remove: remove) })
        present(alert, animated: true)
    }
    private func clearContainer(_ id: UUID, remove: Bool) {
        // Drop every web view using this container before clearing its data.
        if currentID == id { currentBrowser?.removeFromSuperview() }
        if let web = browsers.removeValue(forKey: id) {
            web.stopLoading()
            web.removeFromSuperview()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "claudeObserver", contentWorld: observerWorld)
            web.navigationDelegate = nil; web.uiDelegate = nil
        }
        popupBrowsers.forEach { $0.stopLoading(); $0.removeFromSuperview(); $0.uiDelegate = nil }
        popupBrowsers.removeAll()
        let dataStore = WKWebsiteDataStore(forIdentifier: id)
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            do {
                try self.store.clearCodeThreads(id)
                if remove { try self.store.remove(id) }
                else { try self.store.update(id) { $0.status = .loggedOut; $0.limitedUntil = nil; $0.lastURL = nil; $0.windowStart = nil; $0.windowCount = nil } }
                if self.currentID == id {
                    self.currentID = nil
                    if let selected = self.store.state.selected { self.show(selected) }
                    else { self.empty.isHidden = false }
                }
                self.refreshMenus()
            } catch { self.report(error) }
        }
    }

    private func captureVisible(_ completion: @escaping (ClaudeContext) -> Void) {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude conversation", "Only visible conversation text on claude.ai can be exported."); return
        }
        web.evaluateJavaScript("globalThis.claudeVisibleSnapshot?.()", in: nil, in: observerWorld) { [weak self] result in
            switch result {
            case .success(let value):
                let context = self?.context(from: value as? [String: Any], url: web.url) ?? ClaudeContext()
                completion(context)
            case .failure(let error): self?.report(error)
            }
        }
    }
    private func context(from raw: [String: Any]?, url: URL?) -> ClaudeContext {
        let messages = (raw?["messages"] as? [[String: Any]] ?? []).prefix(10000).compactMap { item -> ClaudeContext.Message? in
            guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                  let text = item["content"] as? String, !text.isEmpty else { return nil }
            return ClaudeContext.Message(role: role, content: text)
        }
        return ClaudeContext(sourceURL: safeClaudeURL(url), messages: messages, notes: store.latestContext?.notes ?? "")
    }
    private func exportContext(markdown: Bool) {
        captureVisible { [weak self] context in
            guard let self = self else { return }
            guard !context.messages.isEmpty else {
                self.notice("No conversation text found", "Open a conversation and scroll to load its messages. Claude may have changed its page layout. You can also copy the conversation into continuation notes."); return
            }
            do {
                try self.store.capture(context)
                let data: Data
                if markdown { data = Data(("# Claude conversation\n\nPartial visible-text export. Attachments and server-side state are not included.\n\n" + context.handoverText).utf8) }
                else { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(context) }
                self.share(data, fileExtension: markdown ? "md" : "json")
            } catch { self.report(error) }
        }
    }
    private func share(_ data: Data, fileExtension ext: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-context-" + UUID().uuidString + "." + ext)
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
        catch { report(error); return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = actionsButton
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
        present(share, animated: true)
    }
    private func copyHandover() {
        guard let context = store.latestContext, !context.messages.isEmpty || !context.notes.isEmpty else {
            notice("No saved context", "Export a conversation or add continuation notes first."); return
        }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: context.handoverText]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        notice("Context copied", "Paste it into the new account's Claude chat, attach any missing files, and send it. Claude's actual context window still applies.")
    }
    private func editNotes() {
        let editor = ClaudeNotesController(text: store.latestContext?.notes ?? "") { [weak self] notes in
            guard let self = self else { return }
            var context = self.store.latestContext ?? ClaudeContext()
            context.notes = notes
            do { try self.store.capture(context) } catch { self.report(error) }
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }
    private func importContext() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw store.problem("Context file is too large.") }
            try store.importContext(Data(contentsOf: url))
            notice("Context loaded", "Use Copy latest handover, then paste or upload it into Claude.")
        } catch { report(error) }
    }

    private func handleLimit(id: UUID, context: ClaudeContext, manual: Bool, retryAfter: TimeInterval? = nil) {
        guard id == currentID, !switching else { return }
        if presentedViewController != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.handleLimit(id: id, context: context, manual: manual, retryAfter: retryAfter)
            }
            return
        }
        switching = true
        defer { switching = false }
        do {
            // Save before moving away, including when no accounts remain.
            let handover = context.messages.isEmpty ? (store.latestContext ?? context) : context
            try store.capture(handover)
            let delay = retryAfter.flatMap { $0 > 0 && $0 <= 86400 ? $0 : nil } ?? 5 * 3600
            try store.recordLimitHit(id)
            try store.update(id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(delay) }
            rotationVisited.insert(id); refreshMenus()
            guard manual || store.state.autoSwitch else {
                notice("Claude usage limit", "Context was saved. Select another account from Accounts or wait for Claude's reset."); return
            }
            guard let next = store.next(after: id, excluding: rotationVisited) else {
                notice("No active account remains", "Your context was saved. Wait for Claude's reset, or sign in to another account. Use Reset limit if Claude already allows messages again."); return
            }
            show(next.id, automatic: true)
            let message = handover.messages.isEmpty ?
                "Switched to " + next.name + ". No conversation text was detected. Use continuation notes or copy the conversation from the previous account." :
                "Switched to " + next.name + ". Context is saved. Tap Copy context, then paste it into a Claude chat and send it. Reattach any files."
            let alert = UIAlertController(title: "Account switched", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Copy context", style: .default) { [weak self] _ in self?.copyHandover() })
            alert.addAction(UIAlertAction(title: "Continue", style: .cancel))
            present(alert, animated: true)
        } catch { report(error) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "claude.ai", let web = message.webView,
              let id = browsers.first(where: { $0.value === web })?.key,
              let payload = message.body as? [String: Any], let event = payload["event"] as? String else { return }
        if event == "signedIn" {
            if let profile = store.state.profiles.first(where: { $0.id == id }), store.status(profile) == .loggedOut {
                change(id) { $0.status = .active }
            }
        } else if event == "limit", let request = codePendings.values.first(where: { $0.profileID == id }) {
            rotateCodeRequest(request, context: context(from: payload["snapshot"] as? [String: Any], url: web.url),
                              retryAfter: payload["retryAfterSeconds"] as? TimeInterval)
        } else if event == "limit", id == currentID {
            handleLimit(id: id, context: context(from: payload["snapshot"] as? [String: Any], url: web.url), manual: false, retryAfter: payload["retryAfterSeconds"] as? TimeInterval)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = browsers.first(where: { $0.value === webView })?.key else { return }
        if let url = safeClaudeURL(webView.url) {
            change(id) { profile in
                profile.lastURL = url
                if url.path.hasPrefix("/login") { profile.status = .loggedOut }
            }
        }
        refreshMenus()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            notice("Page could not load", error.localizedDescription + "\nTry Reload. If Claude blocks embedded sign-in, this app cannot override that restriction.")
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if ["https", "about", "blob"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else { decisionHandler(.cancel); UIApplication.shared.open(url) }
    }
    // OAuth popups inherit the initiating profile's data store; never substitute .default().
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self; popup.navigationDelegate = self; popupBrowsers.append(popup)
        let controller = UIViewController(); controller.view = popup
        let nav = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(closePopup))
        present(nav, animated: true); return popup
    }
    @objc private func closePopup() {
        popupBrowsers.forEach { $0.stopLoading(); $0.removeFromSuperview(); $0.uiDelegate = nil; $0.navigationDelegate = nil }
        popupBrowsers.removeAll(); dismiss(animated: true)
    }
    func webViewDidClose(_ webView: WKWebView) { if popupBrowsers.contains(where: { $0 === webView }) { closePopup() } }
    private func notice(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func report(_ error: Error) { notice("Could not complete action", error.localizedDescription) }
    deinit {
        for web in browsers.values {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "claudeObserver", contentWorld: observerWorld)
        }
    }
}

final class ClaudeNotesController: UIViewController {
    private let editor = UITextView()
    private let initial: String
    private let save: (String) -> Void
    init(text: String, save: @escaping (String) -> Void) { initial = text; self.save = save; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Continuation notes"; view.backgroundColor = .systemBackground
        editor.text = initial; editor.font = .preferredFont(forTextStyle: .body)
        editor.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            editor.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(done))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    }
    @objc private func done() { save(editor.text); dismiss(animated: true) }
    @objc private func cancel() { dismiss(animated: true) }
}

private final class ClaudeCodePending {
    let id: String
    let repo: String
    let branch: String
    let prompt: String
    let reply: (Any?, String?) -> Void
    var profileID: UUID
    var attempted: Set<UUID> = []
    var deadline = Date().addingTimeInterval(600)
    var started = false
    var counted = false
    var evaluating = false
    var lastPhase = ""
    var lastText = ""
    init(id: String, repo: String, branch: String, prompt: String, profileID: UUID,
         reply: @escaping (Any?, String?) -> Void) {
        self.id = id; self.repo = repo; self.branch = branch; self.prompt = prompt
        self.profileID = profileID; self.reply = reply
    }
}

extension ClaudeBrowserController {
    func codeProfiles() -> [[String: Any]] {
        store.state.profiles.enumerated().map { index, p -> [String: Any] in
            let usage = store.usage(p)
            return ["id": p.id.uuidString, "number": index + 1, "name": p.name,
                    "status": store.status(p).rawValue, "enabled": p.enabled,
                    "selected": p.id == store.state.selected,
                    "busy": codePendings.values.contains { $0.profileID == p.id },
                    "used": usage.used, "limit": usage.limit, "percent": usage.percent,
                    "limitSource": usage.source, "limited": usage.limited,
                    "resetsIn": usage.resetsIn.map { Int($0) } ?? -1]
        }
    }
    func startCodeRequest(_ message: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard codePendings.count < 4 else { reply(nil, "Too many Claude browser tasks are running at once."); return }
        guard let id = message["id"] as? String, !id.isEmpty, id.count <= 80, codePendings[id] == nil,
              let rawProfile = message["profileID"] as? String, let profileID = UUID(uuidString: rawProfile),
              let profile = store.state.profiles.first(where: { $0.id == profileID }), profile.enabled,
              let prompt = message["prompt"] as? String, !prompt.isEmpty, prompt.utf8.count <= 600_000,
              let repo = message["repo"] as? String, !repo.isEmpty, repo.count <= 250,
              let branch = message["branch"] as? String, !branch.isEmpty, branch.count <= 250 else {
            reply(nil, "Choose a valid Claude container and repository first."); return
        }
        let busy = Set(codePendings.values.map(\.profileID))
        var chosen = profileID
        if store.status(profile) == .rateLimited {
            guard store.state.autoSwitch, let next = store.next(after: profileID, excluding: busy) else {
                reply(nil, "This Claude container is rate-limited. Choose another account or wait for reset."); return
            }
            chosen = next.id
        }
        guard !busy.contains(chosen) else {
            reply(nil, "This Claude container is already running a Code task. Choose another container or wait for it to finish."); return
        }
        loadViewIfNeeded()
        let request = ClaudeCodePending(id: id, repo: repo, branch: branch, prompt: prompt, profileID: chosen, reply: reply)
        codePendings[id] = request
        if codeTimer == nil {
            codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollAllCodeRequests() }
        }
        openCodeProfilePreservingDraft(request)
    }
    func confirmCodeReply(_ id: String) {
        guard let request = codePendings[id] else { return }
        browsers[request.profileID]?.callAsyncJavaScript("return globalThis.claudeConfirmCodeReply?.(id);",
            arguments: ["id": id], in: nil, in: observerWorld, completionHandler: nil)
    }
    func cancelCodeRequest(_ id: String) {
        guard let request = codePendings[id] else { return }
        finishCodeRequest(request, error: "Claude task stopped. No browser response was applied to repository files.")
    }

    private func pollAllCodeRequests() {
        for request in Array(codePendings.values) { pollCodeRequest(request) }
    }
    private func openCodeProfilePreservingDraft(_ request: ClaudeCodePending) {
        // Never navigate away from an existing user draft or active browser response.
        if let web = browsers[request.profileID], safeClaudeURL(web.url) != nil {
            let checkingProfile = request.profileID
            request.evaluating = true
            web.callAsyncJavaScript("return globalThis.claudeComposerBusyState?.() || {busy:true,hasDraft:true};",
                arguments: [:], in: nil, in: observerWorld) { [weak self, weak request] result in
                    guard let self = self, let request = request, self.codePendings[request.id] === request, request.profileID == checkingProfile else { return }
                    request.evaluating = false
                    guard case .success(let raw) = result, let state = raw as? [String: Any],
                          state["busy"] as? Bool == false, state["hasDraft"] as? Bool == false else {
                        self.show(request.profileID)
                        self.finishCodeRequest(request, error: "This Claude container has a draft, is generating, or needs a page reload. Finish or clear it in the Claude tab, then send the Code task again."); return
                    }
                    self.prepareCodeProfile(request); self.pollCodeRequest(request)
                }
        } else { prepareCodeProfile(request); pollCodeRequest(request) }
    }
    private func prepareCodeProfile(_ request: ClaudeCodePending) {
        guard let web = ensureBrowser(request.profileID) else {
            finishCodeRequest(request, error: "Could not open the selected Claude container."); return
        }
        let thread = safeClaudeURL(store.codeThread(profile: request.profileID, repo: request.repo, branch: request.branch))
        web.load(URLRequest(url: thread ?? URL(string: "https://claude.ai/new")!))
        request.started = false; request.counted = false; request.evaluating = false; request.lastText = ""; request.lastPhase = ""
        emitCode(request, phase: "opening", detail: "Opening the coding conversation in Claude.")
    }
    private func emitCode(_ request: ClaudeCodePending, phase: String, detail: String = "", text: String = "", model: String = "Claude web") {
        guard let profile = store.state.profiles.first(where: { $0.id == request.profileID }) else { return }
        let number = (store.state.profiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1
        onCodeEvent?(["id": request.id, "phase": phase, "detail": detail, "text": text,
                      "profileID": profile.id.uuidString, "containerNumber": number,
                      "containerName": profile.name, "model": model])
    }
    private func pollCodeRequest(_ request: ClaudeCodePending) {
        guard codePendings[request.id] === request else { return }
        if Date() > request.deadline {
            finishCodeRequest(request, error: "Claude did not finish within ten minutes. Its browser conversation is kept; no partial output was applied.")
            return
        }
        guard !request.evaluating, let web = browsers[request.profileID], !web.isLoading else { return }
        guard safeClaudeURL(web.url) != nil else {
            emitCode(request, phase: "needsLogin", detail: "Open Claude and finish signing in to this container."); return
        }
        request.evaluating = true
        let payload: [String: Any] = ["id": request.id, "prompt": request.prompt]
        let script = request.started ?
            "return globalThis.claudeCodeRequestStatus ? globalThis.claudeCodeRequestStatus(request.id) : {phase:'notStarted'};" :
            "return globalThis.claudeBeginCodeRequest ? globalThis.claudeBeginCodeRequest(request) : {phase:'needsLogin'};"
        let expectedProfile = request.profileID
        web.callAsyncJavaScript(script, arguments: ["request": payload], in: nil, in: observerWorld) { [weak self, weak request] result in
            guard let self = self, let request = request, self.codePendings[request.id] === request, request.profileID == expectedProfile else { return }
            request.evaluating = false
            switch result {
            case .failure:
                // Sign-in redirects or page navigation can temporarily replace the content world.
                self.emitCode(request, phase: "needsLogin", detail: "Open Claude to finish sign-in or reload its page.")
            case .success(let value):
                guard let state = value as? [String: Any], let phase = state["phase"] as? String else { return }
                let text = state["text"] as? String ?? ""
                guard text.utf8.count <= 2_000_000 else { self.finishCodeRequest(request, error: "Claude's response is too large to apply safely."); return }
                if ["prepared", "submitted", "responding", "complete"].contains(phase) { request.started = true }
                // Count a message toward this container's usage bar once Claude has actually received it.
                if !request.counted, ["submitted", "responding", "complete"].contains(phase) {
                    request.counted = true
                    try? self.store.recordMessage(request.profileID)
                    self.refreshMenus()
                }
                if phase == "notStarted", request.started {
                    // Never resubmit automatically after losing a document: it could duplicate a sent message.
                    self.finishCodeRequest(request, error: "The Claude page changed during the request. Check its browser conversation before retrying."); return
                }
                if let raw = state["url"] as? String, let url = self.safeClaudeURL(URL(string: raw)), url.path.hasPrefix("/chat/") {
                    try? self.store.saveCodeThread(profile: request.profileID, repo: request.repo, branch: request.branch, url: url)
                }
                let model = state["model"] as? String ?? "Claude web"
                if phase != request.lastPhase || text != request.lastText {
                    let detail = state["detail"] as? String ?? (phase == "prepared" ?
                        "Your prompt is in Claude. Open its tab and tap Send if the site did not submit automatically." : "")
                    self.emitCode(request, phase: phase, detail: detail, text: text, model: model)
                    request.lastPhase = phase; request.lastText = text
                }
                if phase == "complete", !text.isEmpty {
                    let profile = self.store.state.profiles.first { $0.id == request.profileID }
                    self.finishCodeRequest(request, result: ["text": text, "profileID": request.profileID.uuidString,
                        "containerName": profile?.name ?? "Claude", "model": model])
                } else if phase == "stopped" {
                    self.finishCodeRequest(request, error: "Claude's response was stopped in the browser. No partial output was applied.")
                }
            }
        }
    }
    private func rotateCodeRequest(_ request: ClaudeCodePending, context: ClaudeContext, retryAfter: TimeInterval?) {
        guard codePendings[request.id] === request else { return }
        let id = request.profileID
        do {
            try store.capture(context)
            let delay = retryAfter.flatMap { $0 > 0 && $0 <= 86400 ? $0 : nil } ?? 5 * 3600
            try store.recordLimitHit(id)
            try store.update(id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(delay) }
            request.attempted.insert(id)
            refreshMenus()
            // Sub-agents must not land on a container another task is already using.
            let busy = Set(codePendings.values.filter { $0 !== request }.map(\.profileID))
            guard store.state.autoSwitch, let next = store.next(after: id, excluding: request.attempted.union(busy)) else {
                finishCodeRequest(request, error: "Claude reached its limit and no eligible container remains. The browser context is saved; no partial answer was applied."); return
            }
            clearCodeDOM(request, profile: id)
            request.profileID = next.id
            releaseIfIdle(id)
            emitCode(request, phase: "switching", detail: "Claude reached its limit. Resending the task and repository context to the next container.")
            openCodeProfilePreservingDraft(request)
        } catch { finishCodeRequest(request, error: error.localizedDescription) }
    }
    private func clearCodeDOM(_ request: ClaudeCodePending, profile: UUID) {
        browsers[profile]?.callAsyncJavaScript("globalThis.claudeCancelCodeRequest?.(id);",
            arguments: ["id": request.id], in: nil, in: observerWorld, completionHandler: nil)
    }
    private func finishCodeRequest(_ request: ClaudeCodePending, result: [String: Any]? = nil, error: String? = nil) {
        guard codePendings[request.id] === request else { return }
        clearCodeDOM(request, profile: request.profileID)
        codePendings[request.id] = nil
        if codePendings.isEmpty { codeTimer?.invalidate(); codeTimer = nil }
        releaseIfIdle(request.profileID)
        refreshMenus()
        emitCode(request, phase: error == nil ? "complete" : "error", detail: error ?? "", text: result?["text"] as? String ?? "",
                 model: result?["model"] as? String ?? "Claude web")
        request.reply(result, error)
    }
}
