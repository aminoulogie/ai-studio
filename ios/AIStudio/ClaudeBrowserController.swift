import UIKit
import WebKit
import UniformTypeIdentifiers

/// One persistent WebKit data store per Claude account (container). Containers can work in parallel:
/// the one on screen sits in this tab, the others keep running in a parking view behind the app.
final class ClaudeBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let store: ClaudeProfileStore
    private let observerWorld = WKContentWorld.world(name: "ClaudeVisiblePageObserver")
    private var browsers: [UUID: WKWebView] = [:]
    private var lastUsed: [UUID: Date] = [:]
    private var popupBrowsers: [WKWebView] = []
    private var currentID: UUID?
    private let surface = UIView()
    private let empty = UILabel()
    /// Web views that are working but not on screen live here, inside the window, so WebKit keeps them running.
    private let parking = UIView()
    private var accountsButton: UIBarButtonItem!
    private var actionsButton: UIBarButtonItem!
    private var currentBrowser: WKWebView? { currentID.flatMap { browsers[$0] } }
    private var injectedObserver = ""
    private let titleButton = UIButton(type: .system)
    private var modelText = ""
    private var modelTimer: Timer?
    private var onScreen = false
    /// Each loaded container is a separate WebKit process; idle ones beyond this are unloaded to save memory.
    static let maxLiveBrowsers = 5

    /// Code tab events: {id, state, text, note, account, profile}.
    /// States: queued, sending, awaiting (you press Send), streaming, switching, done, stopped, failed.
    var onStream: (([String: Any]) -> Void)?
    var onProfilesChanged: (() -> Void)?
    /// Show the Claude tab (true) or go back to the Code tab (false).
    var onFocus: ((Bool) -> Void)?

    init(store: ClaudeProfileStore) {
        self.store = store; super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(observerChanged),
                                               name: .studioObserverUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The verified helper script from an app update, or the one built into the app.
    private func currentObserverScript() -> String? {
        if let updated = StudioUpdater.shared.observerSource() { return updated }
        guard let url = Bundle.main.url(forResource: "claude-observer", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    @objc private func observerChanged() {
        guard let script = currentObserverScript(), script != injectedObserver else { return }
        injectedObserver = script
        for (id, web) in browsers {
            let content = web.configuration.userContentController
            content.removeAllUserScripts()
            content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: observerWorld))
            // Never interrupt a message that is being sent or answered.
            if !busy(id) { web.reload() }
        }
    }

    // MARK: view

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
        empty.text = "Claude containers\n\nTap Accounts → Add account, then sign in on claude.ai.\n\nMake your Opus account the manager. Every other account is a sub-agent that works in parallel."
        empty.numberOfLines = 0; empty.textAlignment = .center; empty.textColor = .secondaryLabel
        empty.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: surface.widthAnchor, multiplier: 0.82)
        ])
        accountsButton = UIBarButtonItem(title: "Accounts", image: UIImage(systemName: "person.2.circle"), primaryAction: nil, menu: nil)
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
        refreshMenus()
        if let selected = store.state.selected, store.state.profiles.contains(where: { $0.id == selected }) {
            show(selected)
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onScreen = true
        navigationController?.setToolbarHidden(false, animated: false)
        if let web = currentBrowser { place(web, visible: true) }
        modelTimer?.invalidate()
        modelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollModel() }
        pollModel(); refreshMenus()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onScreen = false
        modelTimer?.invalidate(); modelTimer = nil
        // Out of the window WebKit pauses a page; park it so a running task keeps going.
        if let web = currentBrowser { place(web, visible: false) }
    }

    private func appWindow() -> UIWindow? {
        view.window ?? (UIApplication.shared.delegate as? AppDelegate)?.window
    }
    /// Behind the app's root view: in the window (so pages run) but never seen or touched.
    private func attachParking() {
        guard parking.superview == nil, let window = appWindow() else { return }
        parking.frame = window.bounds
        parking.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parking.isUserInteractionEnabled = false
        parking.accessibilityElementsHidden = true
        window.insertSubview(parking, at: 0)
    }
    private func place(_ web: WKWebView, visible: Bool) {
        if visible {
            guard web.superview !== surface else { return }
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: surface.leadingAnchor), web.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                web.topAnchor.constraint(equalTo: surface.topAnchor), web.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
        } else {
            attachParking()
            guard web.superview !== parking else { return }
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = true
            web.frame = parking.bounds.isEmpty ? UIScreen.main.bounds : parking.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parking.addSubview(web)
        }
    }

    private func makeBrowser(_ profile: ClaudeProfile) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.id)
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(self, contentWorld: observerWorld, name: "claudeObserver")
        if let script = currentObserverScript() {
            injectedObserver = script
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: observerWorld))
        }
        let web = WKWebView(frame: UIScreen.main.bounds, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.accessibilityLabel = "Claude browser for " + profile.name
        web.load(URLRequest(url: safeClaudeURL(profile.lastURL) ?? URL(string: "https://claude.ai/")!))
        return web
    }
    /// The container's web view, loaded on first use.
    private func browser(for id: UUID) -> WKWebView? {
        lastUsed[id] = Date()
        if let web = browsers[id] { return web }
        guard let profile = store.state.profiles.first(where: { $0.id == id }) else { return nil }
        let web = makeBrowser(profile); browsers[id] = web
        if id != currentID || !onScreen { place(web, visible: false) }
        trimBrowsers()
        return web
    }
    /// Unloads idle, off-screen containers (oldest first). Their sign-in stays in the data store.
    private func trimBrowsers() {
        guard browsers.count > Self.maxLiveBrowsers else { return }
        let idle = browsers.keys.filter { $0 != currentID && !busy($0) }
            .sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }
        for id in idle.prefix(browsers.count - Self.maxLiveBrowsers) { unload(id) }
    }
    private func unload(_ id: UUID) {
        guard let web = browsers.removeValue(forKey: id) else { return }
        web.stopLoading(); web.removeFromSuperview()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "claudeObserver", contentWorld: observerWorld)
        web.navigationDelegate = nil; web.uiDelegate = nil
    }
    private func safeClaudeURL(_ url: URL?) -> URL? {
        guard let url = url, url.scheme == "https", url.host == "claude.ai",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    /// Puts a container on screen in this tab. A container working on a task is not reloaded.
    func show(_ id: UUID) {
        guard store.state.profiles.contains(where: { $0.id == id }) else { return }
        do { try store.select(id) } catch { report(error); return }
        if let old = currentBrowser, currentID != id { place(old, visible: false) }
        currentID = id
        guard let web = browser(for: id) else { return }
        if onScreen || isViewLoaded { place(web, visible: onScreen) }
        empty.isHidden = true
        modelText = ""
        if !busy(id) { web.evaluateJavaScript("globalThis.claudeCheckLimits?.()", in: nil, in: observerWorld, completionHandler: nil) }
        refreshMenus()
    }

    // MARK: title, menus, account settings

    private func updateTitleButton() {
        let profile = store.state.profiles.first { $0.id == currentID }
        let name = (profile?.manager == true ? "★ " : "") + (profile?.name ?? "Claude")
        let label = modelText.isEmpty ? name : name + " · " + modelText
        titleButton.setTitle(label + " ▾", for: .normal)
        titleButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        titleButton.accessibilityLabel = "Container " + name + (modelText.isEmpty ? "" : ", " + modelText)
        titleButton.showsMenuAsPrimaryAction = true
        let containers = store.state.profiles.map { p in
            UIAction(title: p.name, subtitle: subtitle(p), image: UIImage(systemName: p.manager ? "star.circle" : "person.crop.circle"),
                     state: p.id == currentID ? .on : .off) { [weak self] _ in self?.show(p.id) }
        }
        let modelAction = UIAction(title: modelText.isEmpty ? "Model & effort" : "Model & effort · " + modelText,
                                   image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.openModelPicker() }
        titleButton.menu = UIMenu(children: [UIMenu(title: "Container", options: .displayInline, children: containers), modelAction])
        titleButton.sizeToFit()
        titleButton.frame.size.width = min(titleButton.frame.width, 260)
        navigationItem.titleView = titleButton
    }
    private func subtitle(_ p: ClaudeProfile) -> String {
        var parts = [p.manager ? "Manager" : "Sub-agent", store.status(p).rawValue]
        if !p.enabled { parts.append("Paused") }
        if busy(p.id) { parts.append("Working") }
        return parts.joined(separator: " · ")
    }
    private func pollModel() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else { return }
        web.evaluateJavaScript("globalThis.claudeModelInfo?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self, case .success(let value) = result else { return }
            let text = (value as? String) ?? ""
            if text != self.modelText { self.modelText = text; self.updateTitleButton() }
        }
    }
    private func openModelPicker() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude chat", "Open a conversation on claude.ai first."); return
        }
        web.evaluateJavaScript("globalThis.claudeOpenModelPicker?.()", in: nil, in: observerWorld) { [weak self] result in
            if case .success(let value) = result, (value as? Bool) == true { return }
            self?.notice("Could not open the model picker", "Open a Claude chat, then tap the model name next to the message box.")
        }
    }
    private func refreshMenus() {
        onProfilesChanged?()
        guard isViewLoaded else { return }
        updateTitleButton()
        accountsButton.menu = UIMenu(title: "Claude containers", children:
            store.state.profiles.map { p in
                UIAction(title: p.name, subtitle: subtitle(p), image: UIImage(systemName: p.manager ? "star.circle" : "person.crop.circle"),
                         state: p.id == currentID ? .on : .off) { [weak self] _ in self?.show(p.id) }
            } + [UIAction(title: "Add account", image: UIImage(systemName: "plus"),
                          attributes: store.state.profiles.count >= ClaudeProfileStore.maxProfiles ? .disabled : []) { [weak self] _ in self?.addAccount() }])
        actionsButton.menu = UIMenu(children: [
            UIAction(title: "Account settings", image: UIImage(systemName: "person.crop.circle.badge.gearshape")) { [weak self] _ in self?.accountSettings() },
            UIAction(title: "Export visible chat", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportContext() },
            UIAction(title: "Edit shared memory", image: UIImage(systemName: "brain")) { [weak self] _ in self?.editMemory() },
            UIAction(title: "Insert shared memory in chat", image: UIImage(systemName: "text.insert")) { [weak self] _ in self?.insertMemory() },
            UIAction(title: "Check chat for memory update", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in self?.checkMemoryUpdate() }
        ])
    }

    @objc private func back() { currentBrowser?.goBack() }
    @objc private func forward() { currentBrowser?.goForward() }
    @objc private func reloadPage() {
        guard let id = currentID else { return }
        if busy(id) { notice("Container is working", "Wait for its task to finish, or stop it from the Code tab."); return }
        currentBrowser?.reload()
    }
    @objc private func newChat() {
        guard let id = currentID else { return }
        if busy(id) { notice("Container is working", "Wait for its task to finish, or stop it from the Code tab."); return }
        currentBrowser?.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
    }
    /// Marks the open container as limited and opens the next ready one.
    @objc private func manualLimit() {
        guard let id = currentID else { return }
        markLimited(id, retryAfter: nil)
        let next = store.state.profiles.first(where: { $0.id == id })?.manager == true
            ? store.nextWorker(after: nil, excluding: [id])
            : (store.nextWorker(after: id, excluding: [id]) ?? store.managerProfile.flatMap { store.ready($0) ? $0 : nil })
        if let next = next { show(next.id) }
        else { notice("No ready container", "Every other container is limited, paused or signed out.") }
    }

    private func addAccount() {
        let alert = UIAlertController(title: "Add Claude account", message: "Use a label you recognize. You sign in on the official site; the app never sees your password.", preferredStyle: .alert)
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
        guard let id = currentID, let p = store.state.profiles.first(where: { $0.id == id }) else { addAccount(); return }
        let sheet = UIAlertController(title: p.name, message: subtitle(p) + "\nA limit resets after the time Claude shows, or five hours. Use Reset limit when Claude allows messages again.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: p.manager ? "Make it a sub-agent" : "Make it the manager (plans the work)", style: .default) { [weak self] _ in
            do { try self?.store.setManager(p.manager ? nil : id); self?.refreshMenus() } catch { self?.report(error) }
        })
        sheet.addAction(UIAlertAction(title: "Mark signed in / Reset limit", style: .default) { [weak self] _ in
            self?.change(id) { $0.status = .active; $0.limitedUntil = nil }
        })
        sheet.addAction(UIAlertAction(title: p.enabled ? "Pause (skip in tasks)" : "Resume", style: .default) { [weak self] _ in self?.change(id) { $0.enabled.toggle() } })
        sheet.addAction(UIAlertAction(title: "Move earlier", style: .default) { [weak self] _ in
            do { try self?.store.move(id, by: -1); self?.refreshMenus() } catch { self?.report(error) }
        })
        sheet.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in self?.rename(id, name: p.name) })
        sheet.addAction(UIAlertAction(title: "Log out / Clear this container", style: .destructive) { [weak self] _ in self?.confirmClear(id, remove: false) })
        sheet.addAction(UIAlertAction(title: "Remove account", style: .destructive) { [weak self] _ in self?.confirmClear(id, remove: true) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = actionsButton
        present(sheet, animated: true)
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
        for job in jobs.values where job.profileID == id { endJob(job.id, "failed", note: "That container was logged out.") }
        unload(id)
        popupBrowsers.forEach { $0.stopLoading(); $0.removeFromSuperview(); $0.uiDelegate = nil }
        popupBrowsers.removeAll()
        WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            do {
                if remove { try self.store.remove(id) }
                else { try self.store.update(id) { $0.status = .loggedOut; $0.limitedUntil = nil; $0.lastURL = nil } }
                if self.currentID == id {
                    self.currentID = nil
                    if let selected = self.store.state.selected, selected != id || !remove { self.show(selected) }
                    else { self.empty.isHidden = false }
                }
                self.refreshMenus()
            } catch { self.report(error) }
        }
    }

    // MARK: export and shared memory

    private func exportContext() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude conversation", "Only visible conversation text on claude.ai can be exported."); return
        }
        web.evaluateJavaScript("globalThis.claudeVisibleSnapshot?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let value) = result else { return }
            let raw = value as? [String: Any]
            let messages = (raw?["messages"] as? [[String: Any]] ?? []).prefix(10000).compactMap { item -> ClaudeContext.Message? in
                guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                      let text = item["content"] as? String, !text.isEmpty else { return nil }
                return ClaudeContext.Message(role: role, content: text)
            }
            guard !messages.isEmpty else { self.notice("No conversation text found", "Open a conversation and scroll to load its messages."); return }
            let context = ClaudeContext(sourceURL: self.safeClaudeURL(web.url), messages: messages, notes: "")
            do {
                try self.store.capture(context)
                let data = Data(("# Claude conversation\n\nPartial visible-text export.\n\n" + context.handoverText).utf8)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-chat-" + String(UUID().uuidString.prefix(8)) + ".md")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.barButtonItem = self.actionsButton
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
                self.present(share, animated: true)
            } catch { self.report(error) }
        }
    }
    private func editMemory() {
        let editor = ClaudeNotesController(text: store.masterMemory) { [weak self] text in
            do { try self?.store.setMasterMemory(text) } catch { self?.report(error) }
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }
    private func jsLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
    /// Types the memory into the message box. The person reads it and presses send.
    private func insertMemory() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude chat", "Open a conversation on claude.ai first."); return
        }
        guard !store.masterMemory.isEmpty else { notice("No shared memory yet", "Use Edit shared memory first."); return }
        let text = store.memoryPrompt
        web.evaluateJavaScript("globalThis.claudeInsertText?.(" + jsLiteral(text) + ")", in: nil, in: observerWorld) { [weak self] result in
            if case .success(let value) = result, (value as? Bool) == true {
                self?.notice("Memory added", "Read the text in the message box, then send it yourself.")
            } else {
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                self?.notice("Could not find the message box", "The memory was copied: paste it into the chat and send it.")
            }
        }
    }
    private func checkMemoryUpdate() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude chat", "Open a conversation on claude.ai first."); return
        }
        web.evaluateJavaScript("globalThis.claudeMemoryProposal?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self, case .success(let value) = result else { return }
            guard let raw = value as? String, !raw.isEmpty else {
                self.notice("No memory update found", "The last reply has no memory block."); return
            }
            let proposal = String(raw.prefix(ClaudeProfileStore.memoryLimit))
            let alert = UIAlertController(title: "Update shared memory?", message: String(proposal.prefix(1200)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Replace memory", style: .destructive) { [weak self] _ in
                do { try self?.store.setMasterMemory(proposal) } catch { self?.report(error) }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    // MARK: tasks from the Code tab (several at once, one per container)

    enum Role: String { case manager, worker }
    private struct ClaudeJob {
        let id: String
        let text: String
        let images: [[String: String]]
        var role: Role
        /// The manager is your own paid account: the app types the message, you press Send.
        var manual: Bool
        var fresh: Bool
        var profileID: UUID?
        var tried: Set<UUID> = []
        var baseline = 0
        var baselineUsers = 0
        var lastText = ""
        var stableTicks = 0
        var startedAt = Date()
        var queuedAt = Date()
        var sent = false
        var awaitingLoad = false
        var delivering = false
        var polling = false
        var note = ""
    }
    private var jobs: [String: ClaudeJob] = [:]
    private var timers: [String: Timer] = [:]
    private var queueTimer: Timer?
    /// Round-robin start point, so tasks spread over all sub-agents instead of draining the first one.
    private var lastWorker: UUID?
    private func busy(_ id: UUID) -> Bool { jobs.values.contains { $0.profileID == id } }
    private func name(_ id: UUID?) -> String { store.state.profiles.first { $0.id == id }?.name ?? "" }

    /// Containers for the Code tab.
    func profilesInfo() -> [[String: Any]] {
        store.state.profiles.map { p -> [String: Any] in
            ["id": p.id.uuidString, "name": p.name, "status": store.status(p).rawValue, "enabled": p.enabled,
             "manager": p.manager, "busy": busy(p.id), "ready": store.ready(p)]
        }
    }
    private func emit(_ id: String, _ state: String, text: String = "", note: String = "") {
        guard let job = jobs[id] else { return }
        onStream?(["id": id, "state": state, "text": text, "note": note, "account": name(job.profileID),
                   "profile": job.profileID?.uuidString ?? "", "role": job.role.rawValue])
    }
    private func endJob(_ id: String, _ state: String, text: String = "", note: String = "") {
        emit(id, state, text: text, note: note)
        timers.removeValue(forKey: id)?.invalidate()
        let profile = jobs[id]?.profileID
        jobs.removeValue(forKey: id)
        if let profile = profile { lastUsed[profile] = Date() }
        if jobs.isEmpty { endBackgroundTask(); queueTimer?.invalidate(); queueTimer = nil }
        refreshMenus()
    }

    /// Starts a task. role "manager" uses the manager account (you press Send there);
    /// role "worker" picks a free sub-agent and sends by itself. "profile" pins a container (follow-up in the same chat).
    func startJob(_ message: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        loadViewIfNeeded(); attachParking()
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 64, jobs[id] == nil,
              let text = message["text"] as? String, !text.isEmpty else { reply(nil, "Nothing to send"); return }
        guard !store.state.profiles.isEmpty else { reply(nil, "Add a Claude account in the Claude tab first."); return }
        var images: [[String: String]] = []
        for item in (message["images"] as? [[String: Any]] ?? []).prefix(4) {
            guard let data = item["data"] as? String, !data.isEmpty, data.utf8.count <= 3_000_000 else { continue }
            let mime = (item["mime"] as? String) ?? "image/jpeg"
            guard ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mime) else { continue }
            images.append(["data": data, "mime": mime, "name": String(((item["name"] as? String) ?? "photo.jpg").prefix(80))])
        }
        let role = Role(rawValue: message["role"] as? String ?? "") ?? .worker
        var job = ClaudeJob(id: id, text: text, images: images, role: role, manual: role == .manager,
                            fresh: (message["fresh"] as? Bool) ?? true)
        if let raw = message["profile"] as? String, let pinned = UUID(uuidString: raw) {
            guard let p = store.state.profiles.first(where: { $0.id == pinned }) else { reply(nil, "That container no longer exists."); return }
            guard !busy(pinned) else { reply(nil, p.name + " is busy with another task."); return }
            job.profileID = pinned; job.manual = p.manager; job.role = p.manager ? .manager : .worker
        } else if role == .manager {
            if let m = store.managerProfile, store.ready(m), !busy(m.id) { job.profileID = m.id }
            else {
                // No manager ready: plan on a sub-agent instead, sent by itself.
                job.role = .worker; job.manual = false
                job.note = store.managerProfile == nil ? "No manager account set, so a sub-agent plans this." : "The manager is limited or busy, so a sub-agent plans this."
            }
        }
        jobs[id] = job
        if UIApplication.shared.applicationState == .background { appDidEnterBackground() }
        if jobs[id]?.profileID == nil, !assignWorker(id) {
            if store.state.profiles.contains(where: { !$0.manager && store.ready($0) }) {
                emit(id, "queued", note: "Waiting for a free sub-agent…"); startQueue()
            } else {
                jobs.removeValue(forKey: id)
                reply(nil, "No sub-agent is ready. Every container is limited, paused or signed out."); return
            }
        }
        reply(["account": name(jobs[id]?.profileID), "profile": jobs[id]?.profileID?.uuidString ?? ""], nil)
        if !(jobs[id]?.note.isEmpty ?? true) { emit(id, "sending", note: jobs[id]?.note ?? "") }
        if jobs[id]?.profileID != nil { begin(id) }
    }
    private func assignWorker(_ id: String) -> Bool {
        guard let job = jobs[id] else { return false }
        let taken = Set(jobs.values.compactMap { $0.profileID })
        guard let next = store.nextWorker(after: lastWorker, excluding: job.tried.union(taken)) else { return false }
        jobs[id]?.profileID = next.id
        lastWorker = next.id
        return true
    }
    private func startQueue() {
        guard queueTimer == nil else { return }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.drainQueue() }
    }
    private func drainQueue() {
        let waiting = jobs.values.filter { $0.profileID == nil }.sorted { $0.queuedAt < $1.queuedAt }
        if waiting.isEmpty { queueTimer?.invalidate(); queueTimer = nil; return }
        for job in waiting {
            if assignWorker(job.id) { begin(job.id) }
            else if !store.state.profiles.contains(where: { !$0.manager && store.ready($0) && !job.tried.contains($0.id) }) {
                endJob(job.id, "failed", note: "Every sub-agent hit its limit or is signed out. Try again after the reset.")
            } else if Date().timeIntervalSince(job.queuedAt) > 1800 {
                endJob(job.id, "failed", note: "No sub-agent became free within 30 minutes.")
            }
        }
    }
    /// Opens a new chat in the job's container (or uses the open one), then delivers the message.
    private func begin(_ id: String) {
        guard let job = jobs[id], let pid = job.profileID, let web = browser(for: pid) else { return }
        jobs[id]?.sent = false; jobs[id]?.lastText = ""; jobs[id]?.stableTicks = 0
        if job.manual { show(pid); onFocus?(true) }
        emit(id, "sending", note: job.manual ? "Opening " + name(pid) + "…" : "")
        if job.fresh || safeClaudeURL(web.url) == nil {
            jobs[id]?.awaitingLoad = true
            web.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
        } else if web.isLoading {
            jobs[id]?.awaitingLoad = true
        } else { deliver(id) }
    }
    private func deliver(_ id: String) {
        guard let job = jobs[id], !job.delivering, let pid = job.profileID, let web = browsers[pid] else { return }
        jobs[id]?.delivering = true
        web.evaluateJavaScript("globalThis.claudeStatus?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self, self.jobs[id]?.profileID == pid else { return }
            if case .success(let value) = result, let status = value as? [String: Any] {
                if (status["loggedOut"] as? Bool) == true {
                    self.jobs[id]?.delivering = false
                    self.change(pid) { $0.status = .loggedOut }
                    self.moveJob(id, from: pid, loggedOut: true); return
                }
                self.jobs[id]?.baseline = status["assistants"] as? Int ?? 0
                self.jobs[id]?.baselineUsers = status["users"] as? Int ?? 0
            }
            self.insert(job.text, into: web, attempts: 10) { [weak self] ok in
                guard let self = self, self.jobs[id]?.profileID == pid else { return }
                self.jobs[id]?.delivering = false
                guard ok else { self.endJob(id, "failed", note: "Could not find the message box in " + self.name(pid) + ". Open the Claude tab and check the page."); return }
                self.attachImages(id, web: web) { [weak self] attached in
                    guard let self = self, self.jobs[id]?.profileID == pid else { return }
                    guard attached else { self.endJob(id, "failed", note: "Could not attach your photo, so nothing was sent."); return }
                    if job.manual {
                        self.emit(id, "awaiting", note: "Press Send in " + self.name(pid) + " (Claude tab). The app takes it from there.")
                        self.jobs[id]?.startedAt = Date()
                        self.startPolling(id)
                    } else {
                        // Give an upload time to finish; Claude keeps Send off until then.
                        let delay: Double = job.images.isEmpty ? 0 : 3.0 + 1.5 * Double(job.images.count)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.submit(id, pid: pid, attempts: delay == 0 ? 10 : 40)
                        }
                    }
                }
            }
        }
    }
    private func insert(_ text: String, into web: WKWebView, attempts: Int, completion: @escaping (Bool) -> Void) {
        web.evaluateJavaScript("globalThis.claudeInsertText?.(" + jsLiteral(text) + ")", in: nil, in: observerWorld) { [weak self] result in
            if case .success(let value) = result, (value as? Bool) == true { completion(true); return }
            guard attempts > 1 else { completion(false); return }
            // The page may still be rendering its message box.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.insert(text, into: web, attempts: attempts - 1, completion: completion) }
        }
    }
    private func attachImages(_ id: String, web: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let images = jobs[id]?.images, !images.isEmpty else { completion(true); return }
        guard let data = try? JSONSerialization.data(withJSONObject: images), let json = String(data: data, encoding: .utf8) else { completion(false); return }
        web.evaluateJavaScript("globalThis.claudeAttachImages?.(" + jsLiteral(json) + ")", in: nil, in: observerWorld) { result in
            if case .success(let value) = result, (value as? Int ?? 0) >= images.count { completion(true) } else { completion(false) }
        }
    }
    private func submit(_ id: String, pid: UUID, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.jobs[id]?.profileID == pid, let web = self.browsers[pid] else { return }
            web.evaluateJavaScript("globalThis.claudeSubmit?.()", in: nil, in: self.observerWorld) { [weak self] result in
                guard let self = self, self.jobs[id]?.profileID == pid else { return }
                if case .success(let value) = result, (value as? Bool) == true { self.markSent(id); return }
                if attempts > 1 { self.submit(id, pid: pid, attempts: attempts - 1) } else { self.submitByKey(id, pid: pid) }
            }
        }
    }
    /// Last resort when no Send button could be found: press Enter, then check the message really went.
    private func submitByKey(_ id: String, pid: UUID) {
        guard let web = browsers[pid] else { return }
        web.evaluateJavaScript("globalThis.claudeSubmitKey?.()", in: nil, in: observerWorld) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.jobs[id]?.profileID == pid else { return }
                web.evaluateJavaScript("globalThis.claudeStatus?.()", in: nil, in: self.observerWorld) { [weak self] result in
                    guard let self = self, self.jobs[id]?.profileID == pid else { return }
                    if case .success(let value) = result, let status = value as? [String: Any],
                       (status["users"] as? Int ?? 0) > (self.jobs[id]?.baselineUsers ?? 0) || (status["streaming"] as? Bool) == true {
                        self.markSent(id); return
                    }
                    web.evaluateJavaScript("globalThis.claudeSubmitDiag?.()", in: nil, in: self.observerWorld) { [weak self] diag in
                        var seen = ""
                        if case .success(let value) = diag, let text = value as? String, !text.isEmpty { seen = " Buttons I could see: " + String(text.prefix(200)) + "." }
                        self?.endJob(id, "failed", note: "The message is in Claude's box but Send could not be pressed. Open the Claude tab and press Send." + seen)
                    }
                }
            }
        }
    }
    private func markSent(_ id: String) {
        jobs[id]?.sent = true; jobs[id]?.startedAt = Date()
        emit(id, "streaming", note: "")
        startPolling(id)
    }
    private func startPolling(_ id: String) {
        timers[id]?.invalidate()
        timers[id] = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll(id) }
    }
    private func poll(_ id: String) {
        guard let job = jobs[id], !job.polling, let pid = job.profileID, let web = browsers[pid] else { return }
        let waited = Date().timeIntervalSince(job.startedAt)
        if job.manual && !job.sent && waited > 1800 { endJob(id, "failed", note: "Send was not pressed in " + name(pid) + " within 30 minutes."); return }
        if job.sent && waited > 900 { endJob(id, "failed", note: "Claude took more than 15 minutes to answer."); return }
        jobs[id]?.polling = true
        web.evaluateJavaScript("globalThis.claudeStatus?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self else { return }
            self.jobs[id]?.polling = false
            guard let job = self.jobs[id], job.profileID == pid, case .success(let value) = result, let status = value as? [String: Any] else { return }
            let assistants = status["assistants"] as? Int ?? 0
            let users = status["users"] as? Int ?? 0
            let streaming = (status["streaming"] as? Bool) == true
            let last = status["last"] as? String ?? ""
            if !job.sent {
                // Manager: you pressed Send. Bring the Code tab back while Claude answers.
                if users > job.baselineUsers || streaming {
                    self.jobs[id]?.sent = true; self.jobs[id]?.startedAt = Date()
                    self.emit(id, "streaming"); self.onFocus?(false)
                }
                return
            }
            if assistants <= job.baseline {
                if waited > 150 && !streaming {
                    web.evaluateJavaScript("globalThis.claudeCheckLimits?.()", in: nil, in: self.observerWorld, completionHandler: nil)
                    if waited > 180 { self.endJob(id, "failed", note: "No reply from " + self.name(pid) + ". Check that container in the Claude tab.") }
                }
                return
            }
            if last != job.lastText {
                self.jobs[id]?.lastText = last; self.jobs[id]?.stableTicks = 0
                self.emit(id, "streaming", text: last)
            } else if !streaming {
                self.jobs[id]?.stableTicks += 1
                if (self.jobs[id]?.stableTicks ?? 0) >= 3 { self.endJob(id, "done", text: last) }
            }
        }
    }
    /// A limit or sign-out in the middle of a task: the task restarts on the next free sub-agent.
    private func moveJob(_ id: String, from pid: UUID, loggedOut: Bool) {
        guard var job = jobs[id], job.profileID == pid else { return }
        timers.removeValue(forKey: id)?.invalidate()
        job.tried.insert(pid); job.profileID = nil; job.sent = false; job.manual = false; job.fresh = true
        job.role = .worker; job.awaitingLoad = false; job.delivering = false; job.queuedAt = Date()
        jobs[id] = job
        let why = name(pid) + (loggedOut ? " is signed out" : " reached its limit")
        if assignWorker(id) {
            emit(id, "switching", note: why + ". Continuing on " + name(jobs[id]?.profileID) + "…")
            begin(id)
        } else if store.state.profiles.contains(where: { !$0.manager && store.ready($0) && !job.tried.contains($0.id) }) {
            emit(id, "queued", note: why + ". Waiting for a free sub-agent…"); startQueue()
        } else {
            endJob(id, "failed", note: why + ", and no other sub-agent is ready. Try again after the reset.")
        }
    }
    func stopJob(_ id: String?) {
        let ids = id.map { [$0] } ?? Array(jobs.keys)
        for jid in ids {
            guard let job = jobs[jid] else { continue }
            if job.sent, let pid = job.profileID {
                browsers[pid]?.evaluateJavaScript("globalThis.claudeStop?.()", in: nil, in: observerWorld, completionHandler: nil)
            }
            endJob(jid, "stopped", note: "Stopped.")
        }
    }
    /// Opens a container in the Claude tab (for example the manager, to press Send).
    func focus(profile raw: String?) {
        loadViewIfNeeded()
        if let raw = raw, let id = UUID(uuidString: raw) { show(id) }
        onFocus?(true)
    }

    /// Chosen in the Code tab's Team sheet or in Account settings here.
    func setManager(_ id: UUID?) throws {
        if let id = id, !store.state.profiles.contains(where: { $0.id == id }) { throw store.problem("Account not found.") }
        try store.setManager(id); refreshMenus()
    }
    private func markLimited(_ id: UUID, retryAfter: TimeInterval?) {
        let delay = retryAfter.flatMap { $0 > 0 && $0 <= 86400 ? $0 : nil } ?? 5 * 3600
        try? store.update(id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(delay) }
        refreshMenus()
    }

    // MARK: leaving the app while Claude answers
    // Answers are written on Claude's servers, so nothing is lost. iOS gives a short grace period; catch up on return.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @objc private func appDidEnterBackground() {
        guard !jobs.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClaudeJobs") { [weak self] in self?.endBackgroundTask() }
    }
    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        for (id, job) in jobs where job.profileID != nil {
            jobs[id]?.startedAt = Date(); jobs[id]?.polling = false
            if job.sent || job.manual { startPolling(id) }
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: WebKit

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "claude.ai", let web = message.webView,
              let id = browsers.first(where: { $0.value === web })?.key,
              let payload = message.body as? [String: Any], let event = payload["event"] as? String else { return }
        if event == "signedIn" {
            if let profile = store.state.profiles.first(where: { $0.id == id }), store.status(profile) == .loggedOut {
                change(id) { $0.status = .active }
            }
        } else if event == "limit" {
            markLimited(id, retryAfter: payload["retryAfterSeconds"] as? TimeInterval)
            for job in jobs.values where job.profileID == id { moveJob(job.id, from: id, loggedOut: false) }
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
        for job in jobs.values where job.profileID == id && job.awaitingLoad {
            jobs[job.id]?.awaitingLoad = false
            deliver(job.id)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if let id = browsers.first(where: { $0.value === webView })?.key,
           let job = jobs.values.first(where: { $0.profileID == id }) {
            endJob(job.id, "failed", note: name(id) + " could not load claude.ai: " + error.localizedDescription); return
        }
        if webView === currentBrowser && onScreen {
            notice("Page could not load", error.localizedDescription + "\nTry Reload.")
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let id = browsers.first(where: { $0.value === webView })?.key {
            for job in jobs.values where job.profileID == id && !job.sent { jobs[job.id]?.awaitingLoad = true }
        }
        webView.reload()
    }
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
        guard isViewLoaded, view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func report(_ error: Error) { notice("Could not complete action", error.localizedDescription) }
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        super.viewDidLoad(); title = "Shared memory"; view.backgroundColor = .systemBackground
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
