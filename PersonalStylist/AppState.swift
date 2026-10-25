import Foundation
import SwiftUI

/// One row in the chat transcript.
struct ChatEntry: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        case thought(String)
        case tool(name: String, summary: String)
        case candidates([Candidate])
        case error(String)
    }

    let id = UUID()
    var kind: Kind
}

enum HealthState: Equatable {
    case unknown
    case checking
    case ok(browser: String, extensionConnected: Bool)
    case unreachable(String)
}

@Observable
@MainActor
final class AppState {
    static let baseURLKey = "backendBaseURL"

    var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Self.baseURLKey) }
    }

    var api: APIClient { APIClient(baseURLString: baseURLString) }

    // Closet + profile
    var closet: [ClosetItem] = []
    var looks: [SavedLook] = []
    var tasteProfile: TasteProfile?
    var userProfile = UserProfile()
    var isRebuildingProfile = false
    var profileError: String?
    var health: HealthState = .unknown

    let scanner = PhotoScanner()

    // Chat
    var chat: [ChatEntry] = []
    var conversationId: String?
    var isStreaming = false
    var activity: String?
    var feedback: [String: String] = [:] // candidate_id -> verdict
    private var chatTask: Task<Void, Never>?

    init() {
        baseURLString = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? APIClient.defaultBaseURL
    }

    func item(id: String) -> ClosetItem? {
        closet.first { $0.id == id }
    }

    func url(_ path: String?) -> URL? { api.resolve(path) }

    // MARK: - Loading

    func refreshAll() async {
        async let h: Void = checkHealth()
        async let c: Void = loadCloset()
        async let l: Void = loadLooks()
        async let p: Void = loadProfile()
        _ = await (h, c, l, p)
    }

    func checkHealth() async {
        health = .checking
        do {
            let r = try await api.health()
            health = .ok(browser: r.browser ?? "none", extensionConnected: r.extensionConnected ?? false)
        } catch {
            health = .unreachable(error.localizedDescription)
        }
    }

    func loadCloset() async {
        if let items = try? await api.closet() {
            closet = items
        }
    }

    func loadLooks() async {
        if let saved = try? await api.looks() {
            looks = saved
        }
    }

    func saveLook(candidate: Candidate, imageUrl: String, iteration: Int?) async throws -> SavedLook {
        let look = try await api.saveLook(candidateId: candidate.id, imageUrl: imageUrl, iteration: iteration)
        if !looks.contains(where: { $0.id == look.id }) {
            looks.insert(look, at: 0)
        }
        return look
    }

    func deleteLook(_ look: SavedLook) async {
        looks.removeAll { $0.id == look.id }
        try? await api.deleteLook(look.id)
    }

    func loadProfile() async {
        if let p = try? await api.profile() {
            tasteProfile = p
        }
    }

    func merge(_ items: [ClosetItem]) {
        for item in items {
            if let idx = closet.firstIndex(where: { $0.id == item.id }) {
                closet[idx] = item
            } else {
                closet.insert(item, at: 0)
            }
        }
    }

    func delete(_ item: ClosetItem) async {
        closet.removeAll { $0.id == item.id }
        try? await api.deleteItem(item.id)
    }

    func startScan() {
        guard !scanner.isRunning else { return }
        let api = self.api
        Task {
            await scanner.scan(api: api) { [weak self] items in
                withAnimation(.spring) { self?.merge(items) }
            }
        }
    }

    func scanPicked(assetIds: [String], asAspirational: Bool = false) {
        guard !scanner.isRunning else { return }
        let api = self.api
        Task {
            await scanner.scanPicked(assetIds: assetIds, api: api, asAspirational: asAspirational) { [weak self] items in
                withAnimation(.spring) { self?.merge(items) }
            }
        }
    }

    func rebuildProfile() async {
        guard !isRebuildingProfile else { return }
        isRebuildingProfile = true
        profileError = nil
        defer { isRebuildingProfile = false }
        do {
            tasteProfile = try await api.rebuildProfile()
        } catch {
            profileError = error.localizedDescription
        }
    }

    // MARK: - Chat

    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isStreaming else { return }
        chat.append(ChatEntry(kind: .user(message)))
        isStreaming = true
        activity = "Thinking…"
        let stream = api.chat(message: message, conversationId: conversationId)

        chatTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.handle(event)
                }
            } catch is CancellationError {
            } catch {
                self?.chat.append(ChatEntry(kind: .error(error.localizedDescription)))
            }
            self?.isStreaming = false
            self?.activity = nil
        }
    }

    func cancelChat() {
        chatTask?.cancel()
        isStreaming = false
        activity = nil
    }

    /// Stops the live search and drops the thread so the next message starts fresh.
    func newChat() {
        cancelChat()
        chat = []
        conversationId = nil
    }

    private func handle(_ event: ChatEvent) {
        switch event {
        case .status(let text):
            activity = text
        case .thought(let text):
            guard !text.isEmpty else { return }
            if case .thought(let prev) = chat.last?.kind {
                chat[chat.count - 1].kind = .thought(prev + "\n\n" + text)
            } else {
                chat.append(ChatEntry(kind: .thought(text)))
            }
        case .tool(let name, let summary):
            chat.append(ChatEntry(kind: .tool(name: name, summary: summary)))
        case .candidate(let candidate):
            withAnimation(.spring) {
                if case .candidates(var list) = chat.last?.kind {
                    if !list.contains(where: { $0.id == candidate.id }) { list.append(candidate) }
                    chat[chat.count - 1].kind = .candidates(list)
                } else {
                    chat.append(ChatEntry(kind: .candidates([candidate])))
                }
            }
        case .message(let text):
            guard !text.isEmpty else { return }
            chat.append(ChatEntry(kind: .assistant(text)))
        case .done(let id):
            if let id { conversationId = id }
            isStreaming = false
            activity = nil
        case .error(let text):
            chat.append(ChatEntry(kind: .error(text)))
        }
    }

    func sendFeedback(_ candidate: Candidate, verdict: String, reason: String? = nil) {
        feedback[candidate.id] = verdict
        let api = self.api
        Task { [weak self] in
            if let resp = try? await api.feedback(candidateId: candidate.id, verdict: verdict, reason: reason),
               let profile = resp.profile {
                self?.tasteProfile = profile
            }
        }
    }

    // MARK: - Reset

    /// Replaces the live closet with the saved one. The selfie and sizes just entered stay.
    func openPreparedCloset() async throws {
        _ = try await api.restoreDemo()
        await refreshAll()
    }

    func resetDemo() async {
        cancelChat()
        try? await api.reset()
        closet = []
        tasteProfile = nil
        userProfile = UserProfile()
        chat = []
        conversationId = nil
        feedback = [:]
        scanner.resetHistory()
    }
}
