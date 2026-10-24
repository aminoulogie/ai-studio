import UIKit

/// Reuse the existing Studio document across Chat/Code/Projects/Settings; Claude has its own native tab.
final class StudioTabController: UITabBarController, UITabBarControllerDelegate {
    private let claudeBrowser: ClaudeBrowserController
    init(store: ClaudeProfileStore) {
        claudeBrowser = ClaudeBrowserController(store: store)
        super.init(nibName: nil, bundle: nil)
        let studio = WebViewController()
        let chat = StudioTabHost(studio: studio, mode: "chat")
        chat.tabBarItem = UITabBarItem(title: "Chat", image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0)
        let code = StudioTabHost(studio: studio, mode: "code")
        code.tabBarItem = UITabBarItem(title: "Code", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), tag: 1)
        let claude = UINavigationController(rootViewController: claudeBrowser)
        claudeBrowser.onCodeEvent = { [weak studio] event in studio?.sendClaudeCodeEvent(event) }
        claude.tabBarItem = UITabBarItem(title: "Claude", image: UIImage(systemName: "globe"), tag: 2)
        let projects = StudioTabHost(studio: studio, mode: "github")
        projects.tabBarItem = UITabBarItem(title: "Projects", image: UIImage(systemName: "folder"), tag: 3)
        let settings = StudioTabHost(studio: studio, mode: "settings")
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "slider.horizontal.3"), tag: 4)
        viewControllers = [chat, code, claude, projects, settings]
        selectedIndex = 0
        delegate = self
    }
    func claudeProfiles() -> [[String: Any]] { claudeBrowser.codeProfiles() }
    func runClaudeCode(_ message: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        claudeBrowser.startCodeRequest(message, reply: reply)
    }
    func confirmClaudeCode(_ id: String) { claudeBrowser.confirmCodeReply(id) }
    func cancelClaudeCode(_ id: String) { claudeBrowser.cancelCodeRequest(id) }
    func openClaudeTab() { selectedIndex = 2 }
    func selectStudioMode(_ mode: String) {
        let indexes = ["chat": 0, "code": 1, "github": 3, "settings": 4]
        guard let index = indexes[mode], selectedIndex != index else { return }
        selectedIndex = index
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        (viewController as? StudioTabHost)?.activate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class StudioTabHost: UIViewController {
    private let studio: WebViewController
    private let mode: String
    init(studio: WebViewController, mode: String) { self.studio = studio; self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func activate() { studio.selectStudioTab(mode) }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if studio.parent !== self {
            studio.willMove(toParent: nil)
            studio.view.removeFromSuperview()
            studio.removeFromParent()
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
        activate()
    }
}
