import XCTest
import WebKit
import UIKit
@testable import AIStudio

@MainActor
final class ClaudeContainerTests: XCTestCase {
    func makeStore() throws -> (ClaudeProfileStore, UserDefaults, URL) {
        let defaults = UserDefaults(suiteName: "ClaudeTests." + UUID().uuidString)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try ClaudeProfileStore(defaults: defaults, directory: directory), defaults, directory)
    }
    func testProfileCapPersistenceCooldownAndRotation() throws {
        let (store, defaults, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // No cap on containers.
        let profiles = try (1...20).map { try store.add(name: "Account \($0)") }
        XCTAssertEqual(Set(profiles.map(\.id)).count, 20)
        for p in profiles { try store.update(p.id) { $0.status = .active } }
        try store.update(profiles[1].id) { $0.enabled = false }
        try store.update(profiles[2].id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(3600) }
        XCTAssertEqual(store.next(after: profiles[0].id)?.id, profiles[3].id)
        try store.update(profiles[2].id) { $0.limitedUntil = .distantPast }
        XCTAssertEqual(store.next(after: profiles[0].id)?.id, profiles[2].id)
        try store.select(profiles[4].id)
        let restored = try ClaudeProfileStore(defaults: defaults, directory: directory)
        XCTAssertEqual(restored.state.selected, profiles[4].id)
        XCTAssertEqual(restored.state.profiles.map(\.id), profiles.map(\.id))
        XCTAssertNil(store.next(after: profiles[0].id, excluding: Set(profiles.map(\.id))))
    }
    func testManagerIsNeverASubAgentAndWorkersRotate() throws {
        let (store, defaults, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = try (1...4).map { try store.add(name: "Account \($0)") }
        for x in p { try store.update(x.id) { $0.status = .active } }
        try store.setManager(p[0].id)
        XCTAssertEqual(store.managerProfile?.id, p[0].id)
        XCTAssertEqual(store.nextWorker(after: nil, excluding: [])?.id, p[1].id)
        XCTAssertEqual(store.nextWorker(after: p[1].id, excluding: [])?.id, p[2].id)
        XCTAssertEqual(store.nextWorker(after: p[3].id, excluding: [])?.id, p[1].id, "rotation wraps and skips the manager")
        XCTAssertNil(store.nextWorker(after: nil, excluding: [p[1].id, p[2].id, p[3].id]), "the manager is never used as a sub-agent")
        try store.update(p[2].id) { $0.status = .rateLimited; $0.limitedUntil = Date().addingTimeInterval(600) }
        XCTAssertEqual(store.nextWorker(after: p[1].id, excluding: [])?.id, p[3].id, "limited accounts are skipped")
        try store.setManager(p[1].id)
        XCTAssertEqual(store.state.profiles.filter(\.manager).map(\.id), [p[1].id], "only one manager")
        let restored = try ClaudeProfileStore(defaults: defaults, directory: directory)
        XCTAssertEqual(restored.managerProfile?.id, p[1].id)
    }
    func testProfilesSavedBeforeTheManagerRoleStillLoad() throws {
        let defaults = UserDefaults(suiteName: "ClaudeTests." + UUID().uuidString)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let old = #"{"profiles":[{"id":"\#(id.uuidString)","name":"Old","status":"Active","enabled":true}],"selected":"\#(id.uuidString)","autoSwitch":true}"#
        defaults.set(Data(old.utf8), forKey: "studio.claude.profiles.v1")
        let store = try ClaudeProfileStore(defaults: defaults, directory: directory)
        XCTAssertEqual(store.state.profiles.first?.name, "Old")
        XCTAssertEqual(store.state.profiles.first?.manager, false)
    }
    func testContextRoundTripAndValidation() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = ClaudeContext(messages: [.init(role: "user", content: "Keep the exact goal 🌍")], notes: "Resume here")
        try store.capture(context)
        let data = try Data(contentsOf: directory.appendingPathComponent("latest.json"))
        try store.importContext(data)
        XCTAssertEqual(store.latestContext?.messages.first?.content, "Keep the exact goal 🌍")
        XCTAssertTrue(store.latestContext?.partial == true)
        XCTAssertTrue(store.latestContext?.handoverText.contains("Resume here") == true)
        var invalid = context; invalid.messages = [.init(role: "system", content: "invalid")]
        XCTAssertThrowsError(try store.importContext(JSONEncoder().encode(invalid)))
    }
    func testPersistentWebKitStoresKeepCookiesIsolated() async throws {
        let idA = UUID(), idB = UUID()
        let a = WKWebsiteDataStore(forIdentifier: idA), b = WKWebsiteDataStore(forIdentifier: idB)
        XCTAssertTrue(a.isPersistent); XCTAssertTrue(b.isPersistent)
        XCTAssertNotEqual(a.identifier, b.identifier)
        let cookie = HTTPCookie(properties: [.domain: "claude.ai", .path: "/", .name: "test-session", .value: "account-A", .secure: "TRUE"])!
        await withCheckedContinuation { continuation in a.httpCookieStore.setCookie(cookie) { continuation.resume() } }
        let own = await cookies(a)
        let other = await cookies(b)
        XCTAssertTrue(own.contains { $0.name == "test-session" && $0.value == "account-A" })
        XCTAssertFalse(other.contains { $0.name == "test-session" })
        let reopened = WKWebsiteDataStore(forIdentifier: idA)
        let persisted = await cookies(reopened)
        XCTAssertTrue(persisted.contains { $0.name == "test-session" })
        await clear(a); await clear(b)
    }
    func testClaudeIsSeparateFromMainStudioTabs() throws {
        let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
        XCTAssertTrue(root is StudioTabController, "Unexpected root: \(String(describing: root)); \(root?.view.subviews.compactMap { ($0 as? UILabel)?.text }.joined(separator: "; ") ?? "")")
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = StudioTabController(store: store)
        XCTAssertEqual(tabs.selectedIndex, 0)
        XCTAssertEqual(tabs.viewControllers?.map { $0.tabBarItem.title }, ["Code", "Claude"])
        XCTAssertNotNil(Bundle.main.url(forResource: "claude-observer", withExtension: "js"))
    }
    private func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
    private func clear(_ store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
    }
}
