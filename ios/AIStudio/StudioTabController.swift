import UIKit

/// Two tabs: Code (the Studio web workspace, settings inside it) and Claude (the containers on claude.ai).
final class StudioTabController: UITabBarController, UITabBarControllerDelegate {
    private let claudeBrowser: ClaudeBrowserController
    private let studio = WebViewController()
    init(store: ClaudeProfileStore) {
        claudeBrowser = ClaudeBrowserController(store: store)
        super.init(nibName: nil, bundle: nil)
        let studio = self.studio
        studio.memoryStore = store
        let code = StudioTabHost(studio: studio)
        code.tabBarItem = UITabBarItem(title: "Code", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), tag: 0)
        claudeBrowser.onStream = { [weak studio] payload in studio?.emitClaude(payload) }
        claudeBrowser.onProfilesChanged = { [weak studio] in studio?.emitProfilesChanged() }
        claudeBrowser.onFocus = { [weak self] claude in self?.selectedIndex = claude ? 1 : 0 }
        let claude = UINavigationController(rootViewController: claudeBrowser)
        claude.tabBarItem = UITabBarItem(title: "Claude", image: UIImage(systemName: "sparkles"), tag: 1)
        viewControllers = [code, claude]
        selectedIndex = 0
        delegate = self
        let tint = UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        tabBar.tintColor = tint
        // The Claude tab's bars use the same terracotta as claude.ai instead of iOS blue.
        UINavigationBar.appearance(whenContainedInInstancesOf: [UINavigationController.self]).tintColor = tint
        UIToolbar.appearance(whenContainedInInstancesOf: [UINavigationController.self]).tintColor = tint
    }
    func claudeProfiles() -> [[String: Any]] { claudeBrowser.profilesInfo() }
    func startClaudeJob(_ message: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        claudeBrowser.startJob(message, reply: reply)
    }
    func stopClaudeJob(_ id: String?) { claudeBrowser.stopJob(id) }
    func openClaude(profile: String?) { claudeBrowser.focus(profile: profile) }
    func setClaudeManager(_ id: UUID?) throws { try claudeBrowser.setManager(id) }
    func setClaudeEnabled(_ id: UUID, _ enabled: Bool) throws { try claudeBrowser.setEnabled(id, enabled) }
    func selectStudioMode(_ mode: String) {
        selectedIndex = 0
        studio.selectStudioTab(mode)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class StudioTabHost: UIViewController {
    private let studio: WebViewController
    init(studio: WebViewController) { self.studio = studio; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(studio)
        studio.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(studio.view)
        NSLayoutConstraint.activate([
            studio.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            studio.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            studio.view.topAnchor.constraint(equalTo: view.topAnchor),
            studio.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        studio.didMove(toParent: self)
    }
}
