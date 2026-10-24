import Foundation

struct ClaudeProfile: Codable, Identifiable {
    enum Status: String, Codable { case active = "Active", rateLimited = "Rate-Limited", loggedOut = "Logged Out" }
    var id = UUID()
    var name: String
    var status: Status = .loggedOut
    var enabled = true
    var limitedUntil: Date?
    var lastURL: URL?
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
    }
    private(set) var state: State
    private let defaults: UserDefaults
    private let stateKey = "studio.claude.profiles.v1"
    let directory: URL
    var latestContext: ClaudeContext?
    /// One shared memory for every Claude container. Stays on this device, never in the repository.
    private(set) var masterMemory = ""
    static let memoryLimit = 4000
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
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("memory.md")),
           let text = String(data: data, encoding: .utf8) { masterMemory = String(text.prefix(Self.memoryLimit)) }
    }
    func setMasterMemory(_ text: String) throws {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.memoryLimit))
        try Data(clean.utf8).write(to: directory.appendingPathComponent("memory.md"), options: [.atomic, .completeFileProtection])
        masterMemory = clean
    }
    /// Text typed into a new chat. The user reads it and presses send.
    var memoryPrompt: String {
        """
        Shared memory from my AI Studio app. Follow it in this chat:
        <memory>
        \(masterMemory)
        </memory>
        If you learn a lasting preference or fact about me in this chat, end your reply with the complete updated memory, kept short, between the lines <<<STUDIO_MEMORY and STUDIO_MEMORY>>>. Otherwise leave that block out. For now, just reply "Memory loaded."
        """
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
    func setAutoSwitch(_ enabled: Bool) throws { state.autoSwitch = enabled; try save() }
    func remove(_ id: UUID) throws {
        state.profiles.removeAll { $0.id == id }
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
