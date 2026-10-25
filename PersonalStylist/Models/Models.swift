import Foundation

struct UserProfile: Codable, Equatable, Sendable {
    var name: String?
    var selfieUrl: String?
    var topSize: String?
    var pantSize: String?
    var shoeSize: String?
    var fitPreference: String?
    var budget: String?
}

struct ClosetItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var category: String
    var name: String
    var colors: [String]
    var pattern: String?
    var material: String?
    var fit: String?
    var styleTags: [String]
    var brand: String?
    var signal: String
    var cropUrl: String
    var sourceAssetId: String
    var sourceTimestamp: String?

    var isWorn: Bool { signal == "worn" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = (try? c.decode(String.self, forKey: .category)) ?? "item"
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled item"
        colors = (try? c.decode([String].self, forKey: .colors)) ?? []
        pattern = try? c.decodeIfPresent(String.self, forKey: .pattern)
        material = try? c.decodeIfPresent(String.self, forKey: .material)
        fit = try? c.decodeIfPresent(String.self, forKey: .fit)
        styleTags = (try? c.decode([String].self, forKey: .styleTags)) ?? []
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        signal = (try? c.decode(String.self, forKey: .signal)) ?? "worn"
        cropUrl = (try? c.decode(String.self, forKey: .cropUrl)) ?? ""
        sourceAssetId = (try? c.decode(String.self, forKey: .sourceAssetId)) ?? ""
        sourceTimestamp = try? c.decodeIfPresent(String.self, forKey: .sourceTimestamp)
    }
}

struct Evidence: Codable, Hashable, Sendable {
    var claim: String
    var itemIds: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = (try? c.decode(String.self, forKey: .claim)) ?? ""
        itemIds = (try? c.decode([String].self, forKey: .itemIds)) ?? []
    }
}

struct TasteProfile: Codable, Sendable {
    var summary: String
    var palette: [String]
    var silhouettes: [String]
    var styleKeywords: [String]
    var preferredBrands: [String]
    var priceBand: String?
    var avoid: [String]
    var gaps: [String]
    var evidence: [Evidence]
    var updatedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        palette = (try? c.decode([String].self, forKey: .palette)) ?? []
        silhouettes = (try? c.decode([String].self, forKey: .silhouettes)) ?? []
        styleKeywords = (try? c.decode([String].self, forKey: .styleKeywords)) ?? []
        preferredBrands = (try? c.decode([String].self, forKey: .preferredBrands)) ?? []
        priceBand = try? c.decodeIfPresent(String.self, forKey: .priceBand)
        avoid = (try? c.decode([String].self, forKey: .avoid)) ?? []
        gaps = (try? c.decode([String].self, forKey: .gaps)) ?? []
        evidence = (try? c.decode([Evidence].self, forKey: .evidence)) ?? []
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct Candidate: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var brand: String?
    var price: String?
    var url: String
    var imageUrl: String?
    var why: String
    var matchedItemIds: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? "Product"
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        price = try? c.decodeIfPresent(String.self, forKey: .price)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
        matchedItemIds = (try? c.decode([String].self, forKey: .matchedItemIds)) ?? []
    }
}

struct HealthResponse: Codable, Sendable {
    var ok: Bool
    var browser: String?
    var extensionConnected: Bool?
}

struct IngestResponse: Codable, Sendable {
    var assetId: String?
    var items: [ClosetItem]
    var skipped: Bool?
    var reason: String?
}

struct ClosetResponse: Codable, Sendable {
    var items: [ClosetItem]
}

struct SavedLook: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var candidateId: String
    var imageUrl: String
    var iteration: Int?
    var title: String
    var brand: String?
    var price: String?
    var url: String
    var productImageUrl: String?
    var aestheticNote: String?
    var savedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        candidateId = (try? c.decode(String.self, forKey: .candidateId)) ?? ""
        imageUrl = (try? c.decode(String.self, forKey: .imageUrl)) ?? ""
        iteration = c.flexibleDouble(.iteration).map { Int($0) }
        title = (try? c.decode(String.self, forKey: .title)) ?? "Look"
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        price = try? c.decodeIfPresent(String.self, forKey: .price)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        productImageUrl = try? c.decodeIfPresent(String.self, forKey: .productImageUrl)
        aestheticNote = try? c.decodeIfPresent(String.self, forKey: .aestheticNote)
        savedAt = try? c.decodeIfPresent(String.self, forKey: .savedAt)
    }
}

struct LooksResponse: Codable, Sendable {
    var looks: [SavedLook]
}

struct FeedbackResponse: Codable, Sendable {
    var ok: Bool?
    var profile: TasteProfile?
}

// MARK: - Virtual try-on

struct TryOnScores: Decodable, Hashable, Sendable {
    var garmentFidelity: Double?
    var identity: Double?
    var fit: Double?
    var styleMatch: Double?
    var overall: Double?

    var rows: [(label: String, value: Double?)] {
        [("Garment", garmentFidelity), ("Identity", identity), ("Fit", fit), ("Style", styleMatch), ("Overall", overall)]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        garmentFidelity = c.flexibleDouble(.garmentFidelity)
        identity = c.flexibleDouble(.identity)
        fit = c.flexibleDouble(.fit)
        styleMatch = c.flexibleDouble(.styleMatch)
        overall = c.flexibleDouble(.overall)
    }

    private enum CodingKeys: String, CodingKey {
        case garmentFidelity, identity, fit, styleMatch, overall
    }

    static func == (a: TryOnScores, b: TryOnScores) -> Bool {
        a.garmentFidelity == b.garmentFidelity && a.identity == b.identity && a.fit == b.fit
            && a.styleMatch == b.styleMatch && a.overall == b.overall
    }

    func hash(into hasher: inout Hasher) { hasher.combine(overall) }
}

struct TryOnRender: Decodable, Identifiable, Hashable, Sendable {
    var iteration: Int
    var imageUrl: String?
    var scores: TryOnScores?
    var critique: String
    var edits: [String]

    var id: Int { iteration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iteration = c.flexibleDouble(.iteration).map { Int($0) } ?? 0
        imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
        scores = try? c.decodeIfPresent(TryOnScores.self, forKey: .scores)
        critique = (try? c.decode(String.self, forKey: .critique)) ?? ""
        if let list = try? c.decode([String].self, forKey: .edits) {
            edits = list
        } else if let text = try? c.decode(String.self, forKey: .edits), !text.isEmpty {
            edits = [text]
        } else {
            edits = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case iteration, imageUrl, scores, critique, edits
    }
}

struct TryOnResult: Decodable, Sendable {
    var bestIteration: Int?
    var baselineScore: Double?
    var finalScore: Double?
    var imageUrl: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestIteration = c.flexibleDouble(.bestIteration).map { Int($0) }
        baselineScore = c.flexibleDouble(.baselineScore)
        finalScore = c.flexibleDouble(.finalScore)
        imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case bestIteration, baselineScore, finalScore, imageUrl
    }
}

struct TryOnBase: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var imageUrl: String
    var label: String
    var timeOfDay: String?
    var place: String?
}

struct TryOnScene: Decodable, Sendable {
    var selectedId: String?
    var occasion: String?
    var options: [TryOnBase]
}

enum TryOnEvent: Sendable {
    case status(String)
    case scene(TryOnScene)
    case render(TryOnRender)
    case done(TryOnResult)
    case error(String)

    private struct Header: Decodable { var type: String; var text: String? }

    static func parse(_ json: String, decoder: JSONDecoder) -> TryOnEvent? {
        guard let data = json.data(using: .utf8),
              let header = try? decoder.decode(Header.self, from: data) else { return nil }
        switch header.type {
        case "status": return .status(header.text ?? "")
        case "scene": return (try? decoder.decode(TryOnScene.self, from: data)).map { .scene($0) }
        case "render": return (try? decoder.decode(TryOnRender.self, from: data)).map { .render($0) }
        case "done": return (try? decoder.decode(TryOnResult.self, from: data)).map { .done($0) }
        case "error": return .error(header.text ?? "Try-on failed")
        default: return nil
        }
    }
}

extension KeyedDecodingContainer {
    /// Accepts numbers or numeric strings.
    func flexibleDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// One SSE event from POST /chat.
enum ChatEvent: Sendable {
    case status(String)
    case thought(String)
    case tool(name: String, summary: String)
    case candidate(Candidate)
    case message(String)
    case done(conversationId: String?)
    case error(String)
}

extension ChatEvent {
    private struct Raw: Decodable {
        var type: String
        var text: String?
        var name: String?
        var summary: String?
        var candidate: Candidate?
        var conversationId: String?
    }

    static func parse(_ json: String, decoder: JSONDecoder) -> ChatEvent? {
        guard let data = json.data(using: .utf8),
              let raw = try? decoder.decode(Raw.self, from: data) else { return nil }
        switch raw.type {
        case "status": return .status(raw.text ?? "")
        case "thought": return .thought(raw.text ?? "")
        case "tool": return .tool(name: raw.name ?? "tool", summary: raw.summary ?? raw.text ?? "")
        case "candidate": return raw.candidate.map { .candidate($0) }
        case "message": return .message(raw.text ?? "")
        case "done": return .done(conversationId: raw.conversationId)
        case "error": return .error(raw.text ?? "Something went wrong")
        default: return nil
        }
    }
}
