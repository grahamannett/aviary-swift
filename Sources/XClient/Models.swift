import Foundation

public struct TweetAuthor: Codable, Sendable {
    public var username: String
    public var name: String
    public init(username: String, name: String) {
        self.username = username
        self.name = name
    }
}

public struct TweetMedia: Codable, Sendable {
    public var type: String
    public var url: String
    public var width: Int?
    public var height: Int?
    public var previewUrl: String?
    public var videoUrl: String?
    public var durationMs: Int?
    public init(type: String, url: String, width: Int? = nil, height: Int? = nil, previewUrl: String? = nil, videoUrl: String? = nil, durationMs: Int? = nil) {
        self.type = type; self.url = url; self.width = width; self.height = height; self.previewUrl = previewUrl; self.videoUrl = videoUrl; self.durationMs = durationMs
    }
}

public struct TweetArticle: Codable, Sendable {
    public var title: String
    public var previewText: String?
    public init(title: String, previewText: String? = nil) { self.title = title; self.previewText = previewText }
}

public final class TweetData: Codable, Sendable {
    public var id: String
    public var text: String
    public var author: TweetAuthor
    public var authorId: String?
    public var createdAt: String?
    public var replyCount: Int?
    public var retweetCount: Int?
    public var likeCount: Int?
    public var conversationId: String?
    public var inReplyToStatusId: String?
    public var quotedTweet: TweetData?
    public var media: [TweetMedia]?
    public var article: TweetArticle?
    public var _raw: AnyCodable?

    public init(
        id: String,
        text: String,
        author: TweetAuthor,
        authorId: String? = nil,
        createdAt: String? = nil,
        replyCount: Int? = nil,
        retweetCount: Int? = nil,
        likeCount: Int? = nil,
        conversationId: String? = nil,
        inReplyToStatusId: String? = nil,
        quotedTweet: TweetData? = nil,
        media: [TweetMedia]? = nil,
        article: TweetArticle? = nil,
        _raw: AnyCodable? = nil
    ) {
        self.id = id
        self.text = text
        self.author = author
        self.authorId = authorId
        self.createdAt = createdAt
        self.replyCount = replyCount
        self.retweetCount = retweetCount
        self.likeCount = likeCount
        self.conversationId = conversationId
        self.inReplyToStatusId = inReplyToStatusId
        self.quotedTweet = quotedTweet
        self.media = media
        self.article = article
        self._raw = _raw
    }
}

public struct TwitterUser: Codable, Sendable {
    public var id: String
    public var username: String
    public var name: String?
    public init(id: String, username: String, name: String? = nil) {
        self.id = id; self.username = username; self.name = name
    }
}

public struct AboutProfile: Codable, Sendable {
    public var accountBasedIn: String?
    public var source: String?
    public var createdCountryAccurate: Bool?
    public var locationAccurate: Bool?
    public var learnMoreUrl: String?
    public init(accountBasedIn: String? = nil, source: String? = nil, createdCountryAccurate: Bool? = nil, locationAccurate: Bool? = nil, learnMoreUrl: String? = nil) {
        self.accountBasedIn = accountBasedIn; self.source = source; self.createdCountryAccurate = createdCountryAccurate; self.locationAccurate = locationAccurate; self.learnMoreUrl = learnMoreUrl
    }
}

public struct AnyCodable: Codable, Sendable {
    public let value: JSONValue
    public init(_ value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = .bool(v); return }
        if let v = try? c.decode(Int.self) { value = .int(v); return }
        if let v = try? c.decode(Double.self) { value = .double(v); return }
        if let v = try? c.decode(String.self) { value = .string(v); return }
        if let v = try? c.decode([AnyCodable].self) { value = .array(v.map(\.value)); return }
        if let v = try? c.decode([String: AnyCodable].self) { value = .object(v.mapValues(\.value)); return }
        value = .null
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v.map(AnyCodable.init))
        case .object(let v): try c.encode(v.mapValues(AnyCodable.init))
        }
    }
}

public enum JSONValue: Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
}

public struct TweetListResult: Sendable {
    public var success: Bool
    public var tweets: [TweetData]
    public var nextCursor: String?
    public var error: String?
    public var had404: Bool
    public init(success: Bool, tweets: [TweetData], nextCursor: String?, error: String?, had404: Bool) {
        self.success = success; self.tweets = tweets; self.nextCursor = nextCursor; self.error = error; self.had404 = had404
    }
}

public struct UserListResult: Sendable {
    public var success: Bool
    public var users: [TwitterUser]
    public var nextCursor: String?
    public var error: String?
    public init(success: Bool, users: [TwitterUser], nextCursor: String?, error: String?) {
        self.success = success; self.users = users; self.nextCursor = nextCursor; self.error = error
    }
}

public struct MutationResult: Sendable {
    public var success: Bool
    public var userId: String?
    public var username: String?
    public var error: String?
    public var tweetId: String?
    public init(success: Bool, userId: String?, username: String?, error: String?, tweetId: String?) {
        self.success = success; self.userId = userId; self.username = username; self.error = error; self.tweetId = tweetId
    }
}

public protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionHTTP: HTTPSession {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

public func extractTweetId(_ input: String) -> String {
    let pattern = #"(?:twitter\.com|x\.com)/(?:\w+/status|i/web/status)/(\d+)"#
    if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
       let m = re.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
       let r = Range(m.range(at: 1), in: input)
    {
        return String(input[r])
    }
    return input
}

public func normalizeHandle(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("@") { s = String(s.dropFirst()) }
    return s.isEmpty ? nil : s
}
