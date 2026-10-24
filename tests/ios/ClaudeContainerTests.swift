import XCTest
import WebKit
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
        let profiles = try (1...6).map { try store.add(name: "Account \($0)") }
        XCTAssertThrowsError(try store.add(name: "Seventh"))
        XCTAssertEqual(Set(profiles.map(\.id)).count, 6)
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
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = StudioTabController(store: store)
        XCTAssertEqual(tabs.selectedIndex, 0)
        XCTAssertEqual(tabs.viewControllers?.map { $0.tabBarItem.title }, ["Chat", "Code", "Claude", "Projects", "Settings"])
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
