import Cookies
import Foundation

struct GraphResponse {
    var json: [String: Any]?
    var status = 0
    var error: String?
    var needsRefresh = false
    var success: Bool { json != nil && error == nil }
}

public actor TwitterClient {
    public let authToken: String
    public let ct0: String
    public let cookieHeader: String
    public let timeoutMs: Double?
    public let quoteDepth: Int
    public var session: HTTPSession
    let queryIdStore: QueryIdStore
    let sleepMilliseconds: @Sendable (Int) async throws -> Void
    let resolveUserBeforeMutation: Bool
    let clientUuid = UUID().uuidString
    let clientDeviceId = UUID().uuidString
    var clientUserId: String?

    public static let bearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    public static let graphqlBase = "https://x.com/i/api/graphql"

    public init(cookies: TwitterCookies, timeoutMs: Double? = nil, quoteDepth: Int = 1,
                session: HTTPSession = URLSessionHTTP(), queryIdStore: QueryIdStore = .shared,
                resolveUserBeforeMutation: Bool = true,
                sleepMilliseconds: @escaping @Sendable (Int) async throws -> Void = { ms in
                    if ms > 0 { try await Task.sleep(for: .milliseconds(ms)) }
                }) {
        self.authToken = cookies.authToken ?? ""
        self.ct0 = cookies.ct0 ?? ""
        self.cookieHeader = cookies.cookieHeader ?? "auth_token=\(cookies.authToken ?? ""); ct0=\(cookies.ct0 ?? "")"
        self.timeoutMs = timeoutMs
        self.quoteDepth = max(0, quoteDepth)
        self.session = session
        self.queryIdStore = queryIdStore
        self.resolveUserBeforeMutation = resolveUserBeforeMutation
        self.sleepMilliseconds = sleepMilliseconds
    }

    public func setSession(_ session: HTTPSession) { self.session = session }

    public func baseHeaders() -> [String: String] {
        var headers = [
            "accept": "*/*", "accept-language": "en-US,en;q=0.9",
            "authorization": "Bearer \(Self.bearer)", "x-csrf-token": ct0,
            "x-twitter-auth-type": "OAuth2Session", "x-twitter-active-user": "yes",
            "x-twitter-client-language": "en", "x-client-uuid": clientUuid,
            "x-twitter-client-deviceid": clientDeviceId,
            "x-client-transaction-id": (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined(),
            "cookie": cookieHeader,
            "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "origin": "https://x.com", "referer": "https://x.com/",
        ]
        if let clientUserId { headers["x-twitter-client-user-id"] = clientUserId }
        return headers
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil, extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard !authToken.isEmpty, !ct0.isEmpty else { throw ClientError("Both authToken and ct0 cookies are required") }
        try Task.checkCancellation()
        var req = URLRequest(url: url)
        req.httpMethod = method
        baseHeaders().merging(extra) { _, new in new }.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = body
        if let timeoutMs, timeoutMs > 0 { req.timeoutInterval = timeoutMs / 1000 }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func queryId(_ operation: String) async -> String { await queryIdStore.getQueryId(operation) }
    func refreshQueryIds() async { await queryIdStore.refresh(force: true, session: session) }

    func queryIds(_ operation: String) async -> [String] {
        let alternatives: [String: [String]] = [
            "TweetDetail": ["97JF30KziU00483E_8elBA", "aFvUsJm2c-oDkJV75blV6g"],
            "SearchTimeline": ["M1jEez78PEfVfbQLvlWMvQ", "5h0kNbk3ii97rmfY6CdgAA", "Tp1sewRU1AsZpBWhqCZicQ"],
            "Bookmarks": ["RV1g3b8n_SGOHwkqKYSCFw", "tmd4ifV8RHltzn8ymGg1aw"],
            "CreateFriendship": ["8h9JVdV8dlSyqyRDJEPCsA", "OPwKc1HXnBT_bWXfAlo-9g"],
            "DestroyFriendship": ["ppXWuagMNXgvzx6WoXBW0Q", "8h9JVdV8dlSyqyRDJEPCsA"],
            "UserByScreenName": ["xc8f1g7BYqr6VTzTbvNlGw", "qW5u-DAuXpMEG0zA1F7UGQ", "sLVLhk0bGj3MVFEKTdax1w"],
        ]
        return uniqueStrings([await queryId(operation)] + (alternatives[operation] ?? [fallbackQueryIds[operation] ?? ""]))
    }

    func apiErrors(_ json: [String: Any]?) -> String? {
        let errors = (JSON.array(json?["errors"]) ?? []).compactMap(JSON.object)
        guard !errors.isEmpty else { return nil }
        return errors.map { error in
            let message = JSON.string(error["message"]) ?? "Unknown API error"
            return JSON.int(error["code"]).map { "\(message) (\($0))" } ?? message
        }.joined(separator: ", ")
    }

    func parseGraph(_ data: Data, _ response: HTTPURLResponse, operation: String, allowPartial: Bool) -> GraphResponse {
        let json = JSON.parse(data)
        let apiError = apiErrors(json)
        let errors = (JSON.array(json?["errors"]) ?? []).compactMap(JSON.object)
        let mismatch = response.statusCode == 404 || errors.contains {
            let message = (JSON.string($0["message"]) ?? "").lowercased()
            return JSON.string(JSON.path($0, "extensions", "code")) == "GRAPHQL_VALIDATION_FAILED"
                || message.contains("query: unspecified")
                || (message.contains("rawquery") && message.contains("must be defined"))
                || ((JSON.array($0["path"]) as? [String])?.contains("rawQuery") == true && message.contains("must be defined"))
        }
        guard (200..<300).contains(response.statusCode) else {
            return GraphResponse(json: json, status: response.statusCode,
                                 error: "HTTP \(response.statusCode): \(apiError ?? String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "")", needsRefresh: mismatch)
        }
        guard let json else { return GraphResponse(status: response.statusCode, error: "Invalid JSON response") }
        if let apiError {
            let instructions = instructionsForOperation(json, operation)
            let usefulDetail = operation == "TweetDetail" && JSON.path(json, "data", "tweetResult", "result") != nil
            let usable = operation == "TweetDetail" ? usefulDetail || (!(JSON.array(instructions) ?? []).isEmpty) : instructions != nil
            let fatalUserError = operation == "UserTweets" && (apiError.contains("User has been suspended") || apiError.contains("User not found"))
            if !allowPartial || !usable || fatalUserError {
                return GraphResponse(json: json, status: response.statusCode, error: apiError, needsRefresh: mismatch)
            }
        }
        return GraphResponse(json: json, status: response.statusCode)
    }

    func graphRead(operation: String, variables: [String: Any], featureSet: String? = nil,
                   fieldToggles: [String: Bool]? = nil, allowPartial: Bool = false) async -> GraphResponse {
        var last = GraphResponse(error: "No query ID available for \(operation)")
        for attempt in 0..<2 {
            var shouldRefresh = false
            for id in await queryIds(operation) {
                var params = ["variables": jsonString(variables)]
                var features = featureSet.map { ClientFeatures.values($0) }
                if operation == "TweetDetail" {
                    features?.merge(["articles_preview_enabled": true, "articles_rest_api_enabled": true,
                                     "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
                                     "creator_subscriptions_tweet_preview_api_enabled": true,
                                     "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
                                     "view_counts_everywhere_api_enabled": true, "longform_notetweets_consumption_enabled": true,
                                     "responsive_web_twitter_article_tweet_consumption_enabled": true,
                                     "freedom_of_speech_not_reach_fetch_enabled": true, "standardized_nudges_misinfo": true,
                                     "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
                                     "rweb_video_timestamps_enabled": true]) { _, new in new }
                }
                let isSearch = operation == "SearchTimeline"
                if let features, !isSearch { params["features"] = jsonString(features) }
                if let fieldToggles { params["fieldToggles"] = jsonString(fieldToggles) }
                var components = URLComponents(string: "\(Self.graphqlBase)/\(id)/\(operation)")!
                components.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
                do {
                    var body: Data?
                    if isSearch { body = try JSONSerialization.data(withJSONObject: ["features": features ?? [:], "queryId": id]) }
                    var result = try await request(components.url!, method: isSearch ? "POST" : "GET", body: body, extra: ["content-type": "application/json"])
                    if operation == "Bookmarks" || operation == "BookmarkFolderTimeline" {
                        for retry in 0..<2 {
                            guard [429, 500, 502, 503, 504].contains(result.1.statusCode) else { break }
                            let retryAfter = result.1.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { seconds -> Int? in
                                guard seconds >= 0, seconds <= Int.max / 1000 else { return nil }
                                return seconds * 1000
                            }
                            let delay = retryAfter ?? (500 * (1 << retry))
                            try await sleepMilliseconds(delay)
                            result = try await request(components.url!, extra: ["content-type": "application/json"])
                        }
                    }
                    // TweetDetail supports a read-only POST fallback when the GET operation URL is absent.
                    if result.1.statusCode == 404, operation == "TweetDetail" {
                        var payload: [String: Any] = ["variables": variables, "features": features ?? [:], "queryId": id]
                        if let fieldToggles { payload["fieldToggles"] = fieldToggles }
                        result = try await request(URL(string: "\(Self.graphqlBase)/\(id)/\(operation)")!, method: "POST",
                                                   body: try JSONSerialization.data(withJSONObject: payload), extra: ["content-type": "application/json"])
                    }
                    last = parseGraph(result.0, result.1, operation: operation, allowPartial: allowPartial)
                    if last.success { return last }
                    if !last.needsRefresh { return last }
                    shouldRefresh = true
                } catch {
                    return GraphResponse(error: error.localizedDescription)
                }
            }
            guard attempt == 0, shouldRefresh else { return last }
            await refreshQueryIds()
        }
        return last
    }

    func graphMutation(operation: String, variables: [String: Any], featureSet: String? = nil, referer: String? = nil) async -> GraphResponse {
        if operation != "DeleteBookmark", resolveUserBeforeMutation, clientUserId == nil { _ = await getCurrentUser() }
        let friendship = operation == "CreateFriendship" || operation == "DestroyFriendship"
        var last = GraphResponse(error: "Unable to perform \(operation)")
        for attempt in 0..<(friendship ? 2 : 3) {
            let ids = friendship ? await queryIds(operation) : [await queryId(operation)]
            for id in ids {
                var payload: [String: Any] = ["variables": variables, "queryId": id]
                if let featureSet { payload["features"] = ClientFeatures.values(featureSet) }
                let url = attempt == 2 ? Self.graphqlBase : "\(Self.graphqlBase)/\(id)/\(operation)"
                do {
                    let result = try await request(URL(string: url)!, method: "POST", body: try JSONSerialization.data(withJSONObject: payload),
                                                   extra: ["content-type": "application/json", "referer": referer ?? "https://x.com/"])
                    last = parseGraph(result.0, result.1, operation: operation, allowPartial: false)
                    // Never repeat a mutation after timeout, 429, 5xx, or an ambiguous response.
                    if result.1.statusCode != 404 || attempt == 2 { return last }
                } catch { return GraphResponse(error: error.localizedDescription) }
            }
            if attempt == 0 { await refreshQueryIds() }
        }
        return last
    }

    func instructionsForOperation(_ json: [String: Any]?, _ operation: String) -> Any? {
        switch operation {
        case "TweetDetail": return JSON.path(json, "data", "threaded_conversation_with_injections_v2", "instructions")
        case "SearchTimeline": return JSON.path(json, "data", "search_by_raw_query", "search_timeline", "timeline", "instructions")
        case "HomeTimeline", "HomeLatestTimeline": return JSON.path(json, "data", "home", "home_timeline_urt", "instructions")
        case "Bookmarks": return JSON.path(json, "data", "bookmark_timeline_v2", "timeline", "instructions") ?? JSON.path(json, "data", "bookmark_timeline", "timeline", "instructions")
        case "BookmarkFolderTimeline": return JSON.path(json, "data", "bookmark_collection_timeline", "timeline", "instructions")
        case "ListLatestTweetsTimeline": return JSON.path(json, "data", "list", "tweets_timeline", "timeline", "instructions")
        case "GenericTimelineById": return JSON.path(json, "data", "timeline", "timeline", "instructions")
        case "ListOwnerships": return JSON.path(json, "data", "user", "result", "timeline", "timeline", "instructions")
        case "ListMemberships": return JSON.path(json, "data", "user", "result", "timeline", "timeline", "instructions")
        default: return JSON.path(json, "data", "user", "result", "timeline", "timeline", "instructions")
        }
    }

    func tweetDetail(_ tweetId: String, cursor: String?) async -> GraphResponse {
        var variables: [String: Any] = ["focalTweetId": tweetId, "with_rux_injections": false, "rankingMode": "Relevance",
            "includePromotedContent": true, "withCommunity": true, "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true, "withVoice": true]
        if let cursor { variables["cursor"] = cursor }
        return await graphRead(operation: "TweetDetail", variables: variables, featureSet: "tweetDetail",
                               fieldToggles: ["withPayments": false, "withAuxiliaryUserLabels": false, "withArticleRichContentState": true,
                                              "withArticlePlainText": true, "withGrokAnalyze": false, "withDisallowedReplyControls": false], allowPartial: true)
    }

    public func getTweet(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        let response = await tweetDetail(tweetId, cursor: nil)
        guard response.success else { return failure(response.error, had404: response.needsRefresh) }
        let instructions = instructionsForOperation(response.json, "TweetDetail")
        var tweet = JSON.object(JSON.path(response.json, "data", "tweetResult", "result"))
            .flatMap { JSON.mapTweet($0, quoteDepth: quoteDepth, includeRaw: includeRaw) }
        if tweet?.id != tweetId { tweet = JSON.walkTweets(instructions, quoteDepth: quoteDepth, includeRaw: includeRaw).first { $0.id == tweetId } }
        guard var tweet else { return failure("Tweet not found in response") }
        if let title = tweet.article?.title, tweet.text.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines), let userId = tweet.authorId {
            if let fallback = await articleText(userId: userId, tweetId: tweetId) { tweet = tweet.replacingText(fallback) }
        }
        return .init(success: true, tweets: [tweet], nextCursor: nil, error: nil, had404: false)
    }

    func articleText(userId: String, tweetId: String) async -> String? {
        let response = await graphRead(operation: "UserArticlesTweets", variables: [
            "userId": userId, "count": 20, "includePromotedContent": true, "withVoice": true,
            "withQuickPromoteEligibilityTweetFields": true, "withBirdwatchNotes": true, "withCommunity": true,
            "withSafetyModeUserFields": true, "withSuperFollowsUserFields": true, "withDownvotePerspective": false,
            "withReactionsMetadata": false, "withReactionsPerspective": false, "withSuperFollowsTweetFields": true,
            "withSuperFollowsReplyCount": false, "withClientEventToken": false,
        ], featureSet: "article", fieldToggles: ["withPayments": false, "withAuxiliaryUserLabels": false, "withArticleRichContentState": true,
                                                     "withArticlePlainText": true, "withGrokAnalyze": false, "withDisallowedReplyControls": false])
        guard response.success else { return nil }
        for item in timelineItemContents(instructionsForOperation(response.json, "UserArticlesTweets")) {
            guard var tweet = JSON.object(JSON.path(item, "tweet_results", "result")) else { continue }
            if let inner = JSON.object(tweet["tweet"]) { tweet = inner }
            guard JSON.string(tweet["rest_id"]) == tweetId, let article = JSON.object(tweet["article"]) else { continue }
            let inner = JSON.object(JSON.path(article, "article_results", "result")) ?? article
            guard let plainText = JSON.string(inner["plain_text"]) ?? JSON.string(article["plain_text"]), !plainText.isEmpty else { return nil }
            let title = JSON.string(inner["title"]) ?? JSON.string(article["title"])
            return title.map { "\($0)\n\n\(plainText)" } ?? plainText
        }
        return nil
    }

    func fetchTweetDetail(_ tweetId: String, cursor: String?, includeRaw: Bool) async -> TweetListResult {
        let response = await tweetDetail(tweetId, cursor: cursor)
        guard response.success else { return failure(response.error, had404: response.needsRefresh) }
        let instructions = instructionsForOperation(response.json, "TweetDetail")
        return .init(success: true, tweets: JSON.walkTweets(instructions, quoteDepth: quoteDepth, includeRaw: includeRaw), nextCursor: JSON.cursor(instructions), error: nil, had404: false)
    }

    public func getReplies(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        var page = await fetchTweetDetail(tweetId, cursor: nil, includeRaw: includeRaw)
        page.tweets = page.tweets.filter { $0.inReplyToStatusId == tweetId }
        return page
    }

    public func getThread(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        var page = await fetchTweetDetail(tweetId, cursor: nil, includeRaw: includeRaw)
        let root = page.tweets.first { $0.id == tweetId }?.conversationId ?? tweetId
        page.tweets = page.tweets.filter { $0.conversationId == root }.sorted(by: tweetCreatedAtAsc)
        return page
    }

    public func getRepliesPaged(_ tweetId: String, includeRaw: Bool, maxPages: Int?, cursor: String?, pageDelayMs: Int) async -> TweetListResult {
        await paginateTweets(limit: nil, maxPages: maxPages, cursor: cursor, delay: pageDelayMs, stopWhenEmpty: false) { cur, _ in
            var page = await self.fetchTweetDetail(tweetId, cursor: cur, includeRaw: includeRaw)
            page.tweets = page.tweets.filter { $0.inReplyToStatusId == tweetId }
            return page
        }
    }

    public func getThreadPaged(_ tweetId: String, includeRaw: Bool, maxPages: Int?, cursor: String?, pageDelayMs: Int) async -> TweetListResult {
        var rootId: String?
        var result = await paginateTweets(limit: nil, maxPages: maxPages, cursor: cursor, delay: pageDelayMs, stopWhenEmpty: false) { cur, _ in
            var page = await self.fetchTweetDetail(tweetId, cursor: cur, includeRaw: includeRaw)
            if rootId == nil { rootId = page.tweets.first { $0.id == tweetId }?.conversationId ?? tweetId }
            page.tweets = page.tweets.filter { $0.conversationId == rootId }
            return page
        }
        result.tweets.sort(by: tweetCreatedAtAsc)
        return result
    }

    func failure(_ error: String?, had404: Bool = false) -> TweetListResult {
        .init(success: false, tweets: [], nextCursor: nil, error: error ?? "Unknown API error", had404: had404)
    }
}

struct ClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
