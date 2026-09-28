import Foundation

public struct TwitterList: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var memberCount: Int?
    public var subscriberCount: Int?
    public var isPrivate: Bool?
    public var createdAt: String?
    public var owner: TwitterUser?

    public init(id: String, name: String, description: String? = nil, memberCount: Int? = nil,
                subscriberCount: Int? = nil, isPrivate: Bool? = nil, createdAt: String? = nil, owner: TwitterUser? = nil) {
        self.id = id; self.name = name; self.description = description; self.memberCount = memberCount
        self.subscriberCount = subscriberCount; self.isPrivate = isPrivate; self.createdAt = createdAt; self.owner = owner
    }
}

public struct ListsResult: Sendable {
    public var success: Bool
    public var lists: [TwitterList]
    public var error: String?

    public init(success: Bool, lists: [TwitterList], error: String? = nil) {
        self.success = success; self.lists = lists; self.error = error
    }
}

public struct NewsItem: Codable, Sendable {
    public var id: String
    public var headline: String
    public var category: String?
    public var timeAgo: String?
    public var postCount: Int?
    public var description: String?
    public var url: String?
    public var tweets: [TweetData]?
    public var _raw: AnyCodable?

    public init(id: String, headline: String, category: String? = nil, timeAgo: String? = nil, postCount: Int? = nil,
                description: String? = nil, url: String? = nil, tweets: [TweetData]? = nil, _raw: AnyCodable? = nil) {
        self.id = id; self.headline = headline; self.category = category; self.timeAgo = timeAgo; self.postCount = postCount
        self.description = description; self.url = url; self.tweets = tweets; self._raw = _raw
    }
}

public struct NewsResult: Sendable {
    public var success: Bool
    public var items: [NewsItem]
    public var error: String?

    public init(success: Bool, items: [NewsItem], error: String? = nil) {
        self.success = success; self.items = items; self.error = error
    }
}

public struct UploadMediaResult: Sendable {
    public var success: Bool
    public var mediaId: String?
    public var error: String?

    public init(success: Bool, mediaId: String? = nil, error: String? = nil) {
        self.success = success; self.mediaId = mediaId; self.error = error
    }
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: JSON.foundationValue(value), options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}

func rawJSON(_ value: Any?) -> AnyCodable? {
    guard let value else { return nil }
    let normalized = JSON.foundationValue(value)
    guard JSONSerialization.isValidJSONObject(normalized),
          let data = try? JSONSerialization.data(withJSONObject: normalized) else { return nil }
    return try? JSONDecoder().decode(AnyCodable.self, from: data)
}

func formData(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let text = values.keys.sorted().map { key in
        "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(values[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }.joined(separator: "&")
    return Data(text.utf8)
}

func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
}
