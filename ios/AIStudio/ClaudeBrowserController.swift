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
    private let surface = UIView()
    private let empty = UILabel()
    private var accountsButton: UIBarButtonItem!
    private var actionsButton: UIBarButtonItem!
    private var currentBrowser: WKWebView? { currentID.flatMap { browsers[$0] } }

    init(store: ClaudeProfileStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.setToolbarHidden(false, animated: false)
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

    private func show(_ id: UUID, automatic: Bool = false) {
        guard let profile = store.state.profiles.first(where: { $0.id == id }) else { return }
        do { try store.select(id) } catch { report(error); return }
        currentBrowser?.removeFromSuperview()
        if !automatic { rotationVisited.removeAll() }
        currentID = id
        let web: WKWebView
        if let existing = browsers[id] { web = existing }
        else { web = makeBrowser(profile); browsers[id] = web }
        web.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: surface.leadingAnchor), web.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            web.topAnchor.constraint(equalTo: surface.topAnchor), web.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        empty.isHidden = true
        if automatic { web.load(URLRequest(url: URL(string: "https://claude.ai/new")!)) }
        else { web.evaluateJavaScript("globalThis.claudeCheckLimits?.()", in: nil, in: observerWorld, completionHandler: nil) }
        refreshMenus()
    }

    private func refreshMenus() {
        let selected = store.state.profiles.first { $0.id == currentID }
        title = selected?.name ?? "Claude"
        navigationItem.prompt = currentBrowser?.url?.host ?? "Official claude.ai browser"
        accountsButton.menu = UIMenu(title: "Isolated Claude accounts", children:
            store.state.profiles.map { profile in
                UIAction(title: profile.name,
                         subtitle: store.status(profile).rawValue + (profile.enabled ? "" : " · Paused"),
                         image: UIImage(systemName: "person.crop.circle"),
                         state: profile.id == currentID ? .on : .off) { [weak self] _ in self?.show(profile.id) }
            } + [UIAction(title: "Add account", image: UIImage(systemName: "plus"),
                          attributes: store.state.profiles.count >= ClaudeProfileStore.maxProfiles ? .disabled : []) { [weak self] _ in self?.addAccount() }])
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
            UIAction(title: "Edit shared memory", image: UIImage(systemName: "brain")) { [weak self] _ in self?.editMemory() },
            UIAction(title: "Insert shared memory in chat", image: UIImage(systemName: "text.insert")) { [weak self] _ in self?.insertMemory() },
            UIAction(title: "Check chat for memory update", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in self?.checkMemoryUpdate() },
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
        guard let id = currentID, let p = store.state.profiles.first(where: { $0.id == id }) else { addAccount(); return }
        let sheet = UIAlertController(title: p.name, message: store.status(p).rawValue + "\nLimit reset defaults to five hours from detection; use Reset limit when Claude allows messages again.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Mark signed in / Reset limit", style: .default) { [weak self] _ in
            self?.change(id) { $0.status = .active; $0.limitedUntil = nil }
        })
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
            web.configuration.userContentController.removeScriptMessageHandler(forName: "claudeObserver", contentWorld: observerWorld)
            web.navigationDelegate = nil; web.uiDelegate = nil
        }
        popupBrowsers.forEach { $0.stopLoading(); $0.removeFromSuperview(); $0.uiDelegate = nil }
        popupBrowsers.removeAll()
        let dataStore = WKWebsiteDataStore(forIdentifier: id)
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            do {
                if remove { try self.store.remove(id) }
                else { try self.store.update(id) { $0.status = .loggedOut; $0.limitedUntil = nil; $0.lastURL = nil } }
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
        guard !store.masterMemory.isEmpty else {
            notice("No shared memory yet", "Use Edit shared memory first."); return
        }
        let text = store.memoryPrompt
        web.evaluateJavaScript("globalThis.claudeInsertText?.(" + jsLiteral(text) + ")", in: nil, in: observerWorld) { [weak self] result in
            switch result {
            case .success(let value):
                if (value as? Bool) == true {
                    self?.notice("Memory added", "Read the text in the message box, then send it yourself.")
                } else {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                    self?.notice("Could not find the message box", "Claude may have changed its page. The memory was copied: paste it into the chat and send it.")
                }
            case .failure(let error): self?.report(error)
            }
        }
    }
    /// Types text into the open Claude chat; the person presses send. Falls back to the clipboard.
    /// Calls back with true when the text is in the message box, false when it was copied instead.
    func insertIntoChat(_ text: String, attempts: Int = 3, copyOnFail: Bool = true, completion: @escaping (Bool) -> Void) {
        if let web = currentBrowser, safeClaudeURL(web.url) != nil {
            web.evaluateJavaScript("globalThis.claudeInsertText?.(" + jsLiteral(text) + ")", in: nil, in: observerWorld) { [weak self] result in
                if case .success(let value) = result, (value as? Bool) == true { completion(true); return }
                self?.retryInsert(text, attempts: attempts, copyOnFail: copyOnFail, completion: completion)
            }
        } else {
            retryInsert(text, attempts: attempts, copyOnFail: copyOnFail, completion: completion)
        }
    }
    private func retryInsert(_ text: String, attempts: Int, copyOnFail: Bool, completion: @escaping (Bool) -> Void) {
        if attempts > 1 {
            // The page may still be loading right after switching to this tab or account.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.insertIntoChat(text, attempts: attempts - 1, copyOnFail: copyOnFail, completion: completion)
            }
        } else {
            if copyOnFail {
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
            }
            completion(false)
        }
    }
    /// Reads the AI's last reply for a proposed memory update. Nothing changes until the person accepts it.
    private func checkMemoryUpdate() {
        guard let web = currentBrowser, safeClaudeURL(web.url) != nil else {
            notice("Open a Claude chat", "Open a conversation on claude.ai first."); return
        }
        web.evaluateJavaScript("globalThis.claudeMemoryProposal?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                guard let raw = value as? String, !raw.isEmpty else {
                    self.notice("No memory update found", "The last reply has no memory block. Ask Claude to end its reply with the updated memory.")
                    return
                }
                let proposal = String(raw.prefix(ClaudeProfileStore.memoryLimit))
                let alert = UIAlertController(title: "Update shared memory?", message: String(proposal.prefix(1200)), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Replace memory", style: .destructive) { [weak self] _ in
                    do { try self?.store.setMasterMemory(proposal) } catch { self?.report(error) }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                self.present(alert, animated: true)
            case .failure(let error): self.report(error)
            }
        }
    }
    // MARK: Code tab -> Claude container (auto-send, live reply, resume on the next container after a limit)
    /// Called with {id, state, text, note, account}. States: sending, streaming, switching, done, stopped, failed.
    var onStream: (([String: Any]) -> Void)?
    private struct ClaudeJob {
        let id: String
        let text: String
        var baseline = 0
        var lastText = ""
        var stableTicks = 0
        var startedAt = Date()
        var sent = false
    }
    private var job: ClaudeJob?
    private var pollTimer: Timer?
    private var polling = false
    private var awaitingJobLoad = false

    private func emit(_ state: String, text: String = "", note: String = "") {
        guard let current = job else { return }
        let name = store.state.profiles.first(where: { $0.id == currentID })?.name ?? ""
        onStream?(["id": current.id, "state": state, "text": text, "note": note, "account": name])
    }
    private func endJob(_ state: String, text: String = "", note: String = "") {
        emit(state, text: text, note: note)
        pollTimer?.invalidate(); pollTimer = nil; polling = false; awaitingJobLoad = false; job = nil
    }
    func startJob(id: String, text: String, reply: @escaping (Any?, String?) -> Void) {
        loadViewIfNeeded()
        guard job == nil else { reply(nil, "Claude is still answering the last message."); return }
        guard currentBrowser != nil else { reply(nil, "No Claude account is open. Add one in the Claude tab and sign in."); return }
        job = ClaudeJob(id: id, text: text)
        reply("started", nil)
        deliverJob(prefix: "")
    }
    func stopJob() {
        guard job != nil else { return }
        currentBrowser?.evaluateJavaScript("globalThis.claudeStop?.()", in: nil, in: observerWorld, completionHandler: nil)
        endJob("stopped", note: "Stopped.")
    }
    /// Types the message (with a prefix of memory and context after a switch) and presses send.
    private func deliverJob(prefix: String) {
        guard let web = currentBrowser, let current = job else { return }
        web.evaluateJavaScript("globalThis.claudeStatus?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self, self.job?.id == current.id else { return }
            var users = 0, assistants = 0
            if case .success(let value) = result, let status = value as? [String: Any] {
                users = status["users"] as? Int ?? 0
                assistants = status["assistants"] as? Int ?? 0
                if (status["loggedOut"] as? Bool) == true {
                    self.endJob("failed", note: "This Claude account is signed out. Sign in from the Claude tab, then send again."); return
                }
            }
            var prompt = prefix + current.text
            // A brand-new chat gets the shared memory first.
            if prefix.isEmpty && users == 0 && !self.store.masterMemory.isEmpty {
                prompt = self.store.memoryPrompt + "\n\n---\n\n" + current.text
            }
            self.job?.baseline = assistants
            self.insertIntoChat(prompt, attempts: 8, copyOnFail: false) { [weak self] ok in
                guard let self = self, self.job?.id == current.id else { return }
                guard ok else {
                    self.endJob("failed", note: "Could not find Claude's message box. Open the Claude tab and check the page."); return
                }
                self.submitJob(current.id, attempts: 6)
            }
        }
    }
    private func submitJob(_ id: String, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.job?.id == id, let web = self.currentBrowser else { return }
            web.evaluateJavaScript("globalThis.claudeSubmit?.()", in: nil, in: self.observerWorld) { [weak self] result in
                guard let self = self, self.job?.id == id else { return }
                if case .success(let value) = result, (value as? Bool) == true {
                    self.job?.sent = true; self.job?.startedAt = Date()
                    self.emit("sending"); self.startPolling(); return
                }
                if attempts > 1 { self.submitJob(id, attempts: attempts - 1) }
                else { self.endJob("failed", note: "Your message is in Claude's box but I could not press send. Open the Claude tab and press send.") }
            }
        }
    }
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.pollJob() }
    }
    private func pollJob() {
        guard let current = job, current.sent, !polling, let web = currentBrowser else { return }
        if Date().timeIntervalSince(current.startedAt) > 600 { endJob("failed", note: "Claude took too long to answer."); return }
        polling = true
        web.evaluateJavaScript("globalThis.claudeStatus?.()", in: nil, in: observerWorld) { [weak self] result in
            guard let self = self else { return }
            self.polling = false
            guard self.job?.id == current.id, self.pollTimer != nil,
                  case .success(let value) = result, let status = value as? [String: Any] else { return }
            let assistants = status["assistants"] as? Int ?? 0
            let streaming = (status["streaming"] as? Bool) == true
            let last = status["last"] as? String ?? ""
            if assistants <= (self.job?.baseline ?? 0) {
                if Date().timeIntervalSince(current.startedAt) > 120 && !streaming {
                    self.endJob("failed", note: "No reply from Claude. If this account hit its limit the app switches by itself; otherwise check the Claude tab.")
                }
                return
            }
            if last != self.job?.lastText {
                self.job?.lastText = last; self.job?.stableTicks = 0
                self.emit("streaming", text: last)
            } else if !streaming {
                self.job?.stableTicks += 1
                if (self.job?.stableTicks ?? 0) >= 2 { self.endJob("done", text: last) }
            }
        }
    }
    /// After a limit: the next account's fresh chat is loading. Continue there once it has loaded.
    private func prepareJobResume(to name: String) {
        pollTimer?.invalidate(); pollTimer = nil; polling = false
        job?.sent = false; job?.lastText = ""; job?.stableTicks = 0
        awaitingJobLoad = true
        emit("switching", note: "Limit reached. Switched to " + name + ". Loading memory and context…")
    }
    private func resumePrefix() -> String {
        var parts: [String] = []
        if !store.masterMemory.isEmpty { parts.append(store.memoryPrompt) }
        if let context = store.latestContext, !context.messages.isEmpty || !context.notes.isEmpty {
            parts.append("Context from my previous Claude conversation (partial). Continue from it:\n" + String(context.handoverText.suffix(12000)))
        }
        parts.append("My message now:\n")
        return parts.joined(separator: "\n\n---\n\n")
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
            try store.update(id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(delay) }
            rotationVisited.insert(id); refreshMenus()
            guard manual || store.state.autoSwitch else {
                if job != nil { endJob("failed", note: "Claude's limit was reached and auto-switch is off. Turn it on in Actions, or pick another account.") }
                notice("Claude usage limit", "Context was saved. Select another account from Accounts or wait for Claude's reset."); return
            }
            guard let next = store.next(after: id, excluding: rotationVisited) else {
                if job != nil { endJob("failed", note: "Every Claude account has hit its limit. Your context is saved. Try again after the reset.") }
                notice("No active account remains", "Your context was saved. Wait for Claude's reset, or sign in to another account. Use Reset limit if Claude already allows messages again."); return
            }
            show(next.id, automatic: true)
            if job != nil { prepareJobResume(to: next.name); return }
            let message = handover.messages.isEmpty ?
                "Switched to " + next.name + ". No conversation text was detected. Use continuation notes or copy the conversation from the previous account." :
                "Switched to " + next.name + ". Context is saved. Tap Copy context, then paste it into a Claude chat and send it. Reattach any files."
            let alert = UIAlertController(title: "Account switched", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Copy context", style: .default) { [weak self] _ in self?.copyHandover() })
            if !store.masterMemory.isEmpty {
                alert.addAction(UIAlertAction(title: "Insert shared memory", style: .default) { [weak self] _ in self?.insertMemory() })
            }
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
