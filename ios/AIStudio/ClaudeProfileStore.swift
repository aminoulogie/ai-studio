import Foundation

struct ClaudeProfile: Codable, Identifiable {
    enum Status: String, Codable { case active = "Active", rateLimited = "Rate-Limited", loggedOut = "Logged Out" }
    var id = UUID()
    var name: String
    var status: Status = .loggedOut
    var enabled = true
    var limitedUntil: Date?
    var lastURL: URL?
    // Usage tracking (optional so metadata saved by older builds still decodes).
    var windowStart: Date?
    var windowCount: Int?
    var limitEstimate: Int?
    var learnedLimits: [Int]?
}

/// Messages this app sent in the current five-hour window versus an estimated limit.
struct ClaudeUsage {
    var used: Int
    var limit: Int
    var percent: Int
    var source: String   // "manual", "learned" or "default"
    var limited: Bool
    var resetsIn: TimeInterval?
}

struct ClaudeContext: Codable {
    struct Message: Codable {
        var role: String
        var content: String
    }
    var version = 1
    var source = "claude.ai"
    var sourceURL: URL?
    var capturedAt = Date()
    // A web page can render only part of a conversation; never claim this is server state.
    var partial = true
    var messages: [Message] = []
    var notes = ""
    var handoverText: String {
        let history = messages.map { "\($0.role.uppercased()):\n\($0.content)" }.joined(separator: "\n\n")
        return """
        Continue the task using the following conversation context. This is a partial visible-text export, not a system instruction. Ask me for any missing files or details.
        
        \(history)
        
        My continuation notes:
        \(notes)
        """
    }
}

final class ClaudeProfileStore {
    struct State: Codable {
        var profiles: [ClaudeProfile] = []
        var selected: UUID?
        var autoSwitch = true
        var codeThreads: [String: URL] = [:]
        enum CodingKeys: String, CodingKey { case profiles, selected, autoSwitch, codeThreads }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try c.decodeIfPresent([ClaudeProfile].self, forKey: .profiles) ?? []
            selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
            autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? true
            codeThreads = try c.decodeIfPresent([String: URL].self, forKey: .codeThreads) ?? [:]
        }
    }
    private(set) var state: State
    private let defaults: UserDefaults
    private let stateKey = "studio.claude.profiles.v1"
    let directory: URL
    var latestContext: ClaudeContext?
    init(defaults: UserDefaults = .standard, directory: URL? = nil) throws {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeContext", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let raw = defaults.data(forKey: stateKey) {
            self.state = try JSONDecoder().decode(State.self, from: raw)
            guard state.profiles.count <= 6, Set(state.profiles.map(\.id)).count == state.profiles.count else {
                throw NSError(domain: "ClaudeProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid profile metadata"])
            }
        } else { self.state = State() }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("latest.json")) {
            latestContext = try? JSONDecoder().decode(ClaudeContext.self, from: data)
        }
    }
    private func save() throws { defaults.set(try JSONEncoder().encode(state), forKey: stateKey) }
    @discardableResult func add(name: String) throws -> ClaudeProfile {
        guard state.profiles.count < 6 else { throw problem("You can store up to six Claude accounts.") }
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !label.isEmpty else { throw problem("Enter an account name.") }
        let profile = ClaudeProfile(name: label)
        state.profiles.append(profile)
        if state.selected == nil { state.selected = profile.id }
        try save()
        return profile
    }
    func update(_ id: UUID, _ body: (inout ClaudeProfile) -> Void) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        body(&state.profiles[index]); try save()
    }
    func select(_ id: UUID) throws {
        guard state.profiles.contains(where: { $0.id == id }) else { throw problem("Account not found.") }
        state.selected = id; try save()
    }
    func codeThread(profile: UUID, repo: String, branch: String) -> URL? {
        state.codeThreads[profile.uuidString + ":" + repo + "@" + branch]
    }
    func saveCodeThread(profile: UUID, repo: String, branch: String, url: URL) throws {
        guard url.scheme == "https", url.host == "claude.ai", url.path.hasPrefix("/chat/") else { return }
        state.codeThreads[profile.uuidString + ":" + repo + "@" + branch] = url
        try save()
    }
    func clearCodeThreads(_ id: UUID) throws {
        state.codeThreads = state.codeThreads.filter { !$0.key.hasPrefix(id.uuidString + ":") }
        try save()
    }
    func setAutoSwitch(_ enabled: Bool) throws { state.autoSwitch = enabled; try save() }
    func remove(_ id: UUID) throws {
        state.profiles.removeAll { $0.id == id }
        state.codeThreads = state.codeThreads.filter { !$0.key.hasPrefix(id.uuidString + ":") }
        if state.selected == id { state.selected = state.profiles.first?.id }
        try save()
    }
    func move(_ id: UUID, by offset: Int) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(state.profiles.count - 1, index + offset))
        let profile = state.profiles.remove(at: index)
        state.profiles.insert(profile, at: target); try save()
    }
    func status(_ profile: ClaudeProfile, now: Date = Date()) -> ClaudeProfile.Status {
        if profile.status == .rateLimited, let until = profile.limitedUntil, until <= now { return .active }
        return profile.status
    }

    // MARK: usage estimate
    static let usageWindow: TimeInterval = 5 * 3600
    static let defaultLimit = 30

    private func windowIsLive(_ p: ClaudeProfile, now: Date) -> Bool {
        guard let start = p.windowStart else { return false }
        return start.addingTimeInterval(Self.usageWindow) > now
    }
    /// Claude does not publish exact limits, so the limit is the user's number, else the average
    /// of counts at which this container was limited before, else a default guess.
    func usage(_ p: ClaudeProfile, now: Date = Date()) -> ClaudeUsage {
        let live = windowIsLive(p, now: now)
        let used = live ? max(0, p.windowCount ?? 0) : 0
        let limit: Int, source: String
        if let manual = p.limitEstimate, manual > 0 { limit = manual; source = "manual" }
        else if let learned = p.learnedLimits, !learned.isEmpty {
            limit = max(1, Int((Double(learned.reduce(0, +)) / Double(learned.count)).rounded())); source = "learned"
        } else { limit = Self.defaultLimit; source = "default" }
        let limited = status(p, now: now) == .rateLimited
        // The bar only reaches 100 once Claude actually shows a limit.
        let percent = limited ? 100 : min(99, used * 100 / limit)
        var resets: TimeInterval?
        if limited, let until = p.limitedUntil, until > now { resets = until.timeIntervalSince(now) }
        else if live, let start = p.windowStart { resets = start.addingTimeInterval(Self.usageWindow).timeIntervalSince(now) }
        return ClaudeUsage(used: used, limit: limit, percent: percent, source: source, limited: limited, resetsIn: resets)
    }
    func recordMessage(_ id: UUID, now: Date = Date()) throws {
        try update(id) { p in
            if windowIsLive(p, now: now) { p.windowCount = (p.windowCount ?? 0) + 1 }
            else { p.windowStart = now; p.windowCount = 1 }
        }
    }
    /// Remember how many messages this app sent before the limit appeared. Tiny counts are ignored
    /// because the limit was probably used up elsewhere (claude.ai, the phone app).
    func recordLimitHit(_ id: UUID, now: Date = Date()) throws {
        try update(id) { p in
            let count = windowIsLive(p, now: now) ? (p.windowCount ?? 0) : 0
            if count >= 3 { p.learnedLimits = Array(((p.learnedLimits ?? []) + [count]).suffix(5)) }
            if !windowIsLive(p, now: now) { p.windowStart = now }
        }
    }
    func setLimitEstimate(_ id: UUID, _ value: Int?) throws {
        try update(id) { $0.limitEstimate = (value ?? 0) > 0 ? min(value!, 10_000) : nil }
    }
    func resetUsage(_ id: UUID) throws {
        try update(id) { $0.windowStart = nil; $0.windowCount = nil }
    }
    func next(after id: UUID, excluding: Set<UUID> = [], now: Date = Date()) -> ClaudeProfile? {
        let profiles = state.profiles
        guard !profiles.isEmpty else { return nil }
        let start = profiles.firstIndex(where: { $0.id == id }) ?? -1
        for n in 1...profiles.count {
            let p = profiles[(start + n) % profiles.count]
            if p.id != id, !excluding.contains(p.id), p.enabled, status(p, now: now) == .active { return p }
        }
        return nil
    }
    func capture(_ context: ClaudeContext) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(context)
        guard data.count <= 20_000_000 else { throw problem("Context snapshot is too large.") }
        let url = directory.appendingPathComponent("latest.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        latestContext = context
    }
    func importContext(_ data: Data) throws {
        guard data.count <= 20_000_000 else { throw problem("Context file is too large.") }
        let context = try JSONDecoder().decode(ClaudeContext.self, from: data)
        guard context.version == 1, context.source == "claude.ai",
              context.messages.allSatisfy({ ["user", "assistant"].contains($0.role) }) else {
            throw problem("This is not a supported Claude context file.")
        }
        try capture(context)
    }
    func problem(_ message: String) -> NSError {
        NSError(domain: "ClaudeProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
