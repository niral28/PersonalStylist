import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid backend URL"
        case .http(let code, let body): return "Server error \(code): \(body.prefix(200))"
        }
    }
}

/// Stateless HTTP client for the PersonalStylist backend. Safe to use from any actor.
struct APIClient: Sendable {
    var baseURL: URL

    static let defaultBaseURL = "http://localhost:8000"

    init(baseURLString: String) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        baseURL = URL(string: trimmed) ?? URL(string: Self.defaultBaseURL)!
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 60 * 20
        return URLSession(configuration: config)
    }()

    private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60 * 15
        config.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: config)
    }()

    /// Resolves a relative path like "/crops/abc.jpg" or passes through absolute URLs.
    func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: baseURL.absoluteString + p)
    }

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    // MARK: - Core

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(URLRequest(url: url(path)), as: type)
    }

    private func post<T: Decodable>(_ path: String, json: (any Encodable)? = nil, method: String = "POST", timeout: TimeInterval = 180, as type: T.Type) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(json)
        }
        return try await send(req, as: type)
    }

    private func multipart<T: Decodable>(
        _ path: String,
        fields: [String: String],
        file: Data,
        filename: String = "image.jpg",
        contentType: String = "image/jpeg",
        timeout: TimeInterval = 180,
        as type: T.Type
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        body.append(file)
        body.append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let session = timeout > 180 ? Self.streamSession : Self.session
        let (data, response) = try await session.upload(for: req, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    /// POSTs JSON and yields each `data:` payload of the SSE response, parsed by `parse`.
    /// Stops after an event for which `isTerminal` returns true.
    private func sse<Event: Sendable>(
        _ path: String,
        json: any Encodable,
        parse: @escaping @Sendable (String) -> Event?,
        isTerminal: @escaping @Sendable (Event) -> Bool
    ) -> AsyncThrowingStream<Event, Error> {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60 * 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? Self.encoder.encode(json)
        let request = req

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.httpBody != nil else { throw APIError.badURL }
                    let (bytes, response) = try await Self.streamSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw APIError.http(http.statusCode, "\(path) request failed")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let event = parse(payload) {
                            continuation.yield(event)
                            if isTerminal(event) { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Endpoints

    func health() async throws -> HealthResponse {
        var req = URLRequest(url: url("/health"))
        req.timeoutInterval = 5
        return try await send(req, as: HealthResponse.self)
    }

    func getOnboarding() async throws -> UserProfile {
        try await get("/onboarding", as: UserProfile.self)
    }

    func saveOnboarding(_ profile: UserProfile) async throws -> UserProfile {
        try await post("/onboarding", json: profile, as: UserProfile.self)
    }

    func uploadSelfie(_ jpeg: Data) async throws -> UserProfile {
        try await multipart("/selfie", fields: [:], file: jpeg, as: UserProfile.self)
    }

    func ingest(jpeg: Data, assetId: String, source: String) async throws -> IngestResponse {
        try await multipart("/ingest", fields: ["asset_id": assetId, "source": source], file: jpeg, as: IngestResponse.self)
    }

    func ingestVideo(mp4: Data, assetId: String) async throws -> IngestResponse {
        try await multipart(
            "/ingest",
            fields: ["asset_id": assetId, "source": "video"],
            file: mp4,
            filename: "video.mp4",
            contentType: "video/mp4",
            timeout: 60 * 5,
            as: IngestResponse.self
        )
    }

    func closet() async throws -> [ClosetItem] {
        try await get("/closet", as: ClosetResponse.self).items
    }

    func deleteItem(_ id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await post("/closet/\(escaped)", method: "DELETE", as: FeedbackResponse.self)
    }

    func profile() async throws -> TasteProfile? {
        let (data, response) = try await Self.session.data(from: url("/profile"))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) == "null" {
            return nil
        }
        return try Self.decoder.decode(TasteProfile.self, from: data)
    }

    func rebuildProfile() async throws -> TasteProfile {
        try await post("/profile/rebuild", timeout: 60 * 15, as: TasteProfile.self)
    }

    func feedback(candidateId: String, verdict: String, reason: String?) async throws -> FeedbackResponse {
        struct Body: Encodable { var candidateId: String; var verdict: String; var reason: String? }
        return try await post("/feedback", json: Body(candidateId: candidateId, verdict: verdict, reason: reason), as: FeedbackResponse.self)
    }

    func looks() async throws -> [SavedLook] {
        try await get("/looks", as: LooksResponse.self).looks
    }

    func saveLook(candidateId: String, imageUrl: String, iteration: Int?) async throws -> SavedLook {
        struct Body: Encodable { var candidateId: String; var imageUrl: String; var iteration: Int? }
        return try await post("/looks", json: Body(candidateId: candidateId, imageUrl: imageUrl, iteration: iteration), as: SavedLook.self)
    }

    func deleteLook(_ id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await post("/looks/\(escaped)", method: "DELETE", as: FeedbackResponse.self)
    }

    func reset() async throws {
        _ = try await post("/reset", as: FeedbackResponse.self)
    }

    func demoStatus() async throws -> DemoStatus {
        try await get("/demo", as: DemoStatus.self)
    }

    func snapshotDemo() async throws -> DemoStatus {
        try await post("/demo/snapshot", as: DemoStatus.self)
    }

    func restoreDemo() async throws -> DemoStatus {
        try await post("/demo/restore", as: DemoStatus.self)
    }

    /// Streams SSE events from POST /chat.
    func chat(message: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        struct Body: Encodable { var message: String; var conversationId: String? }
        return sse(
            "/chat",
            json: Body(message: message, conversationId: conversationId),
            parse: { ChatEvent.parse($0, decoder: Self.decoder) },
            isTerminal: { if case .done = $0 { return true } else { return false } }
        )
    }

    /// Streams SSE events from POST /tryon.
    func tryOn(candidateId: String, baseId: String? = nil, context: String? = nil) -> AsyncThrowingStream<TryOnEvent, Error> {
        struct Body: Encodable {
            var candidateId: String
            var baseId: String?
            var context: String?
        }
        return sse(
            "/tryon",
            json: Body(candidateId: candidateId, baseId: baseId, context: context),
            parse: { TryOnEvent.parse($0, decoder: Self.decoder) },
            isTerminal: { if case .done = $0 { return true } else { return false } }
        )
    }
}

struct DemoStatus: Decodable, Sendable {
    var ready: Bool
    var items: Int
    var looks: Int
    var savedAt: String?
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
