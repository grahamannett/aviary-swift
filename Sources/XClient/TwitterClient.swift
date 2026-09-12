import Cookies
import Foundation

public actor TwitterClient {
    public let authToken: String
    public let ct0: String
    public let cookieHeader: String
    public let timeoutMs: Int?
    public let quoteDepth: Int
    public var session: HTTPSession
    private let clientUuid = UUID().uuidString
    private let clientDeviceId = UUID().uuidString
    private var clientUserId: String?

    public static let bearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    public static let graphqlBase = "https://x.com/i/api/graphql"

    public init(cookies: TwitterCookies, timeoutMs: Int? = nil, quoteDepth: Int = 1, session: HTTPSession = URLSessionHTTP()) {
        guard let auth = cookies.authToken, let ct0 = cookies.ct0 else {
            fatalError("Both authToken and ct0 cookies are required")
        }
        self.authToken = auth
        self.ct0 = ct0
        self.cookieHeader = cookies.cookieHeader ?? "auth_token=\(auth); ct0=\(ct0)"
        self.timeoutMs = timeoutMs
        self.quoteDepth = max(0, quoteDepth)
        self.session = session
    }

    public func setSession(_ session: HTTPSession) {
        self.session = session
    }

    private func transactionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func baseHeaders() -> [String: String] {
        var headers: [String: String] = [
            "accept": "*/*",
            "accept-language": "en-US,en;q=0.9",
            "authorization": "Bearer \(Self.bearer)",
            "x-csrf-token": ct0,
            "x-twitter-auth-type": "OAuth2Session",
            "x-twitter-active-user": "yes",
            "x-twitter-client-language": "en",
            "x-client-uuid": clientUuid,
            "x-twitter-client-deviceid": clientDeviceId,
            "x-client-transaction-id": transactionId(),
            "cookie": cookieHeader,
            "user-agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "origin": "https://x.com",
            "referer": "https://x.com/",
        ]
        if let clientUserId { headers["x-twitter-client-user-id"] = clientUserId }
        return headers
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil, extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in baseHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        if let timeoutMs, timeoutMs > 0 {
            req.timeoutInterval = Double(timeoutMs) / 1000.0
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    func queryId(_ name: String) async -> String {
        await QueryIdStore.shared.getQueryId(name)
    }

    func refreshQueryIds() async {
        await QueryIdStore.shared.refresh(force: true, session: session)
    }

    func graphqlGET(operation: String, queryIds: [String], params: [String: String]) async -> (json: [String: Any]?, status: Int, had404: Bool, error: String?) {
        var had404 = false
        var last: String?
        for qid in queryIds {
            var comps = URLComponents(string: "\(Self.graphqlBase)/\(qid)/\(operation)")!
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps.url else { continue }
            do {
                let (data, http) = try await request(url)
                if http.statusCode == 404 {
                    had404 = true
                    last = "HTTP 404"
                    continue
                }
                if http.statusCode >= 400 {
                    last = "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
                    continue
                }
                return (JSON.parse(data), http.statusCode, had404, nil)
            } catch {
                last = error.localizedDescription
            }
        }
        return (nil, 0, had404, last)
    }

    func graphqlPOST(operation: String, queryIds: [String], body: [String: Any]) async -> (json: [String: Any]?, had404: Bool, error: String?) {
        var had404 = false
        var last: String?
        let payload = try? JSONSerialization.data(withJSONObject: body)
        for qid in queryIds {
            let urls = [
                URL(string: "\(Self.graphqlBase)/\(qid)/\(operation)")!,
                URL(string: Self.graphqlBase)!,
            ]
            for url in urls {
                do {
                    let (data, http) = try await request(
                        url,
                        method: "POST",
                        body: payload,
                        extra: ["content-type": "application/json"]
                    )
                    if http.statusCode == 404 {
                        had404 = true
                        last = "HTTP 404"
                        continue
                    }
                    if http.statusCode >= 400 {
                        last = "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
                        continue
                    }
                    return (JSON.parse(data), had404, nil)
                } catch {
                    last = error.localizedDescription
                }
            }
        }
        return (nil, had404, last)
    }

    public func getTweet(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        let page = await fetchTweetDetail(tweetId, cursor: nil, includeRaw: includeRaw)
        if !page.success { return page }
        let target = page.tweets.first { $0.id == tweetId }
        return TweetListResult(success: true, tweets: target.map { [$0] } ?? page.tweets, nextCursor: nil, error: nil, had404: false)
    }

    public func getReplies(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        let page = await fetchTweetDetail(tweetId, cursor: nil, includeRaw: includeRaw)
        if !page.success { return page }
        let replies = page.tweets.filter { $0.inReplyToStatusId == tweetId }
        return TweetListResult(success: true, tweets: replies, nextCursor: page.nextCursor, error: nil, had404: false)
    }

    public func getThread(_ tweetId: String, includeRaw: Bool = false) async -> TweetListResult {
        let page = await fetchTweetDetail(tweetId, cursor: nil, includeRaw: includeRaw)
        if !page.success { return page }
        let target = page.tweets.first { $0.id == tweetId }
        let rootId = target?.conversationId ?? tweetId
        let thread = page.tweets.filter { $0.conversationId == rootId }.sorted {
            ($0.createdAt ?? "") < ($1.createdAt ?? "")
        }
        return TweetListResult(success: true, tweets: thread, nextCursor: page.nextCursor, error: nil, had404: false)
    }

    public func getRepliesPaged(_ tweetId: String, includeRaw: Bool, maxPages: Int?, cursor: String?, pageDelayMs: Int) async -> TweetListResult {
        await paginateTweets(maxPages: maxPages, cursor: cursor, delay: pageDelayMs) { cur in
            let page = await self.fetchTweetDetail(tweetId, cursor: cur, includeRaw: includeRaw)
            let replies = page.tweets.filter { $0.inReplyToStatusId == tweetId }
            return TweetListResult(success: page.success, tweets: replies, nextCursor: page.nextCursor, error: page.error, had404: page.had404)
        }
    }

    public func getThreadPaged(_ tweetId: String, includeRaw: Bool, maxPages: Int?, cursor: String?, pageDelayMs: Int) async -> TweetListResult {
        var rootId: String?
        let r = await paginateTweets(maxPages: maxPages, cursor: cursor, delay: pageDelayMs) { cur in
            let page = await self.fetchTweetDetail(tweetId, cursor: cur, includeRaw: includeRaw)
            if rootId == nil {
                let target = page.tweets.first { $0.id == tweetId }
                rootId = target?.conversationId ?? tweetId
            }
            let thread = page.tweets.filter { $0.conversationId == rootId }
            return TweetListResult(success: page.success, tweets: thread, nextCursor: page.nextCursor, error: page.error, had404: page.had404)
        }
        let sorted = r.tweets.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        return TweetListResult(success: r.success, tweets: sorted, nextCursor: r.nextCursor, error: r.error, had404: r.had404)
    }

    private func paginateTweets(maxPages: Int?, cursor: String?, delay: Int, fetch: (String?) async -> TweetListResult) async -> TweetListResult {
        var all: [TweetData] = []
        var seen = Set<String>()
        var next = cursor
        var pages = 0
        var lastError: String?
        while true {
            if pages > 0, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
            let page = await fetch(next)
            if !page.success {
                lastError = page.error
                if all.isEmpty { return page }
                return TweetListResult(success: false, tweets: all, nextCursor: next, error: lastError, had404: page.had404)
            }
            pages += 1
            for t in page.tweets where seen.insert(t.id).inserted { all.append(t) }
            let pageCursor = page.nextCursor
            if pageCursor == nil || pageCursor == next {
                return TweetListResult(success: true, tweets: all, nextCursor: nil, error: nil, had404: false)
            }
            if let maxPages, pages >= maxPages {
                return TweetListResult(success: true, tweets: all, nextCursor: pageCursor, error: nil, had404: false)
            }
            next = pageCursor
        }
    }

    func fetchTweetDetail(_ tweetId: String, cursor: String?, includeRaw: Bool) async -> TweetListResult {
        let primary = await queryId("TweetDetail")
        let ids = Array(Set([primary, "97JF30KziU00483E_8elBA", "aFvUsJm2c-oDkJV75blV6g", "_NvJCnIjOW__EP5-RF197A"]))
        var variables: [String: Any] = [
            "focalTweetId": tweetId,
            "with_rux_injections": false,
            "includePromotedContent": true,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true,
            "withVoice": true,
            "withV2Timeline": true,
        ]
        if let cursor { variables["cursor"] = cursor }
        let params = [
            "variables": stringify(variables),
            "features": stringify(tweetDetailFeatures()),
            "fieldToggles": stringify(["withArticleRichContentState": true, "withArticlePlainText": false]),
        ]
        func attempt() async -> TweetListResult {
            let r = await graphqlGET(operation: "TweetDetail", queryIds: ids, params: params)
            if let err = r.error, r.json == nil {
                return TweetListResult(success: false, tweets: [], nextCursor: nil, error: err, had404: r.had404)
            }
            let instructions = JSON.path(r.json, "data", "threaded_conversation_with_injections_v2", "instructions")
            let tweets = JSON.walkTweets(instructions, quoteDepth: quoteDepth, includeRaw: includeRaw)
            return TweetListResult(success: true, tweets: tweets, nextCursor: JSON.cursor(instructions), error: nil, had404: r.had404)
        }
        var first = await attempt()
        if !first.success, first.had404 {
            await refreshQueryIds()
            first = await attempt()
        }
        return first
    }

    public func follow(_ userId: String) async -> MutationResult {
        let rest = await followRest(userId, action: "create")
        if rest.success { return rest }
        return await followGql(userId, follow: true)
    }

    public func unfollow(_ userId: String) async -> MutationResult {
        let rest = await followRest(userId, action: "destroy")
        if rest.success { return rest }
        return await followGql(userId, follow: false)
    }

    private func followRest(_ userId: String, action: String) async -> MutationResult {
        let urls = [
            "https://x.com/i/api/1.1/friendships/\(action).json",
            "https://api.twitter.com/1.1/friendships/\(action).json",
        ]
        let body = "user_id=\(userId)&skip_status=true".data(using: .utf8)
        var last: String?
        for url in urls {
            do {
                let (data, http) = try await request(
                    URL(string: url)!,
                    method: "POST",
                    body: body,
                    extra: ["content-type": "application/x-www-form-urlencoded"]
                )
                if let obj = JSON.parse(data), let errors = JSON.array(obj["errors"]), let first = JSON.object(errors.first) {
                    let code = JSON.int(first["code"])
                    if code == 160 { return MutationResult(success: true, userId: nil, username: nil, error: nil, tweetId: nil) }
                    if code == 162 { return MutationResult(success: false, userId: nil, username: nil, error: "You have been blocked from following this account", tweetId: nil) }
                    if code == 108 { return MutationResult(success: false, userId: nil, username: nil, error: "User not found", tweetId: nil) }
                    last = "\(JSON.string(first["message"]) ?? "") (code \(code ?? 0))"
                    continue
                }
                if http.statusCode >= 400 {
                    last = "HTTP \(http.statusCode)"
                    continue
                }
                let obj = JSON.parse(data)
                return MutationResult(
                    success: true,
                    userId: JSON.string(obj?["id_str"]),
                    username: JSON.string(obj?["screen_name"]),
                    error: nil,
                    tweetId: nil
                )
            } catch {
                last = error.localizedDescription
            }
        }
        return MutationResult(success: false, userId: nil, username: nil, error: last, tweetId: nil)
    }

    private func followGql(_ userId: String, follow: Bool) async -> MutationResult {
        let op = follow ? "CreateFriendship" : "DestroyFriendship"
        let qid = await queryId(op)
        let r = await graphqlPOST(operation: op, queryIds: [qid], body: [
            "variables": ["user_id": userId],
            "queryId": qid,
        ])
        if r.json != nil { return MutationResult(success: true, userId: userId, username: nil, error: nil, tweetId: nil) }
        return MutationResult(success: false, userId: nil, username: nil, error: r.error, tweetId: nil)
    }

    public func getUserIdByUsername(_ username: String) async -> (success: Bool, userId: String?, username: String?, name: String?, error: String?) {
        guard let handle = normalizeHandle(username) else {
            return (false, nil, nil, nil, "Invalid username: \(username)")
        }
        let qids = ["xc8f1g7BYqr6VTzTbvNlGw", "qW5u-DAuXpMEG0zA1F7UGQ", "sLVLhk0bGj3MVFEKTdax1w"]
        let variables = stringify(["screen_name": handle, "withSafetyModeUserFields": true])
        let r = await graphqlGET(operation: "UserByScreenName", queryIds: qids, params: [
            "variables": variables,
            "features": stringify(["hidden_profile_subscriptions_enabled": true]),
        ])
        let result = JSON.object(JSON.path(r.json, "data", "user", "result"))
        if JSON.string(result?["__typename"]) == "UserUnavailable" {
            return (false, nil, nil, nil, "User @\(handle) not found or unavailable")
        }
        if let id = JSON.string(result?["rest_id"]) {
            let uname = JSON.string(JSON.path(result, "legacy", "screen_name")) ?? JSON.string(JSON.path(result, "core", "screen_name")) ?? handle
            let name = JSON.string(JSON.path(result, "legacy", "name")) ?? JSON.string(JSON.path(result, "core", "name"))
            return (true, id, uname, name, nil)
        }
        return (false, nil, nil, nil, r.error ?? "Could not parse user data from response")
    }

    public func getUserAboutAccount(_ username: String) async -> (success: Bool, about: AboutProfile?, error: String?) {
        guard let handle = normalizeHandle(username) else {
            return (false, nil, "Invalid username: \(username)")
        }
        let primary = await queryId("AboutAccountQuery")
        func attempt() async -> (success: Bool, about: AboutProfile?, error: String?, had404: Bool) {
            let r = await graphqlGET(
                operation: "AboutAccountQuery",
                queryIds: [primary, "zs_jFPFT78rBpXv9Z3U2YQ"],
                params: ["variables": stringify(["screenName": handle])]
            )
            if let about = JSON.object(JSON.path(r.json, "data", "user_result_by_screen_name", "result", "about_profile")) {
                let mapped = AboutProfile(
                    accountBasedIn: JSON.string(about["account_based_in"]),
                    source: JSON.string(about["source"]),
                    createdCountryAccurate: JSON.bool(about["created_country_accurate"]),
                    locationAccurate: JSON.bool(about["location_accurate"]),
                    learnMoreUrl: JSON.string(about["learn_more_url"])
                )
                return (true, mapped, nil, r.had404)
            }
            return (false, nil, r.error ?? "Missing about_profile in response", r.had404)
        }
        var first = await attempt()
        if !first.success, first.had404 {
            await refreshQueryIds()
            first = await attempt()
        }
        return (first.success, first.about, first.error)
    }

    public func getCurrentUser() async -> (success: Bool, user: TwitterUser?, error: String?) {
        let urls = [
            "https://x.com/i/api/account/settings.json",
            "https://api.twitter.com/1.1/account/settings.json",
            "https://x.com/i/api/account/verify_credentials.json?skip_status=true&include_entities=false",
            "https://api.twitter.com/1.1/account/verify_credentials.json?skip_status=true&include_entities=false",
        ]
        var last: String?
        for u in urls {
            guard let url = URL(string: u) else { continue }
            do {
                let (data, http) = try await request(url)
                if http.statusCode >= 400 {
                    last = "HTTP \(http.statusCode)"
                    continue
                }
                if let obj = JSON.parse(data) {
                    let username = JSON.string(obj["screen_name"]) ?? JSON.string(JSON.path(obj, "user", "screen_name"))
                    let name = JSON.string(obj["name"]) ?? JSON.string(JSON.path(obj, "user", "name"))
                    let userId = JSON.string(obj["user_id"]) ?? JSON.string(obj["user_id_str"])
                        ?? JSON.string(JSON.path(obj, "user", "id_str"))
                    if let username {
                        if let userId { clientUserId = userId }
                        return (true, TwitterUser(id: userId ?? "", username: username, name: name ?? username), nil)
                    }
                }
                last = "Could not determine current user from response"
            } catch {
                last = error.localizedDescription
            }
        }
        for page in ["https://x.com/settings/account", "https://twitter.com/settings/account"] {
            guard let url = URL(string: page) else { continue }
            do {
                var req = URLRequest(url: url)
                req.setValue(cookieHeader, forHTTPHeaderField: "cookie")
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                if let http, http.statusCode >= 400 {
                    last = "HTTP \(http.statusCode) (settings page)"
                    continue
                }
                let html = String(data: data, encoding: .utf8) ?? ""
                let username = capture(html, "\"screen_name\":\"([^\"]+)\"")
                let userId = capture(html, "\"user_id\"\\s*:\\s*\"(\\d+)\"")
                if let username, let userId {
                    clientUserId = userId
                    return (true, TwitterUser(id: userId, username: username, name: username), nil)
                }
                last = "Could not parse settings page for user info"
            } catch {
                last = error.localizedDescription
            }
        }
        return (false, nil, last)
    }

    public func like(_ tweetId: String) async -> MutationResult { await mutateTweet("FavoriteTweet", tweetId: tweetId) }
    public func unlike(_ tweetId: String) async -> MutationResult { await mutateTweet("UnfavoriteTweet", tweetId: tweetId) }
    public func retweet(_ tweetId: String) async -> MutationResult {
        await mutateTweet("CreateRetweet", tweetId: tweetId, extra: ["source_tweet_id": tweetId])
    }
    public func unretweet(_ tweetId: String) async -> MutationResult { await mutateTweet("DeleteRetweet", tweetId: tweetId) }
    public func bookmark(_ tweetId: String) async -> MutationResult { await mutateTweet("CreateBookmark", tweetId: tweetId) }
    public func unbookmark(_ tweetId: String) async -> MutationResult { await mutateTweet("DeleteBookmark", tweetId: tweetId) }

    private func mutateTweet(_ op: String, tweetId: String, extra: [String: String] = [:]) async -> MutationResult {
        var vars: [String: Any] = ["tweet_id": tweetId]
        for (k, v) in extra { vars[k] = v }
        func attempt() async -> (MutationResult, Bool) {
            let qid = await queryId(op)
            let r = await graphqlPOST(operation: op, queryIds: [qid], body: ["variables": vars, "queryId": qid])
            if r.json != nil { return (MutationResult(success: true, userId: nil, username: nil, error: nil, tweetId: tweetId), r.had404) }
            return (MutationResult(success: false, userId: nil, username: nil, error: r.error, tweetId: nil), r.had404)
        }
        var (res, had404) = await attempt()
        if !res.success, had404 {
            await refreshQueryIds()
            (res, _) = await attempt()
        }
        return res
    }

    public func createTweet(text: String, replyTo: String? = nil) async -> MutationResult {
        var vars: [String: Any] = ["tweet_text": text, "media": ["media_entities": [], "possibly_sensitive": false]]
        if let replyTo {
            vars["reply"] = ["in_reply_to_tweet_id": replyTo, "exclude_reply_user_ids": []]
        }
        let qid = await queryId("CreateTweet")
        let r = await graphqlPOST(operation: "CreateTweet", queryIds: [qid], body: [
            "variables": vars,
            "features": tweetDetailFeatures(),
            "queryId": qid,
        ])
        if let id = JSON.string(JSON.path(r.json, "data", "create_tweet", "tweet_results", "result", "rest_id")) {
            return MutationResult(success: true, userId: nil, username: nil, error: nil, tweetId: id)
        }
        if let errors = JSON.array(JSON.path(r.json, "errors")), let first = JSON.object(errors.first), JSON.int(first["code"]) == 226 {
            return await statusUpdate(text: text, replyTo: replyTo)
        }
        return MutationResult(success: r.json != nil, userId: nil, username: nil, error: r.error, tweetId: nil)
    }

    private func statusUpdate(text: String, replyTo: String?) async -> MutationResult {
        var body = "status=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)"
        if let replyTo { body += "&in_reply_to_status_id=\(replyTo)" }
        do {
            let (data, http) = try await request(
                URL(string: "https://x.com/i/api/1.1/statuses/update.json")!,
                method: "POST",
                body: body.data(using: .utf8),
                extra: ["content-type": "application/x-www-form-urlencoded"]
            )
            let obj = JSON.parse(data)
            if http.statusCode < 400 {
                return MutationResult(success: true, userId: nil, username: nil, error: nil, tweetId: JSON.string(obj?["id_str"]))
            }
            return MutationResult(success: false, userId: nil, username: nil, error: "HTTP \(http.statusCode)", tweetId: nil)
        } catch {
            return MutationResult(success: false, userId: nil, username: nil, error: error.localizedDescription, tweetId: nil)
        }
    }

    public func search(_ query: String, includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "SearchTimeline", variables: [
            "rawQuery": query, "count": 20, "querySource": "typed_query", "product": "Latest",
        ], includeRaw: includeRaw)
    }

    public func home(includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "HomeLatestTimeline", variables: ["count": 20, "includePromotedContent": true], includeRaw: includeRaw)
    }

    public func userTweets(userId: String, includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "UserTweets", variables: ["userId": userId, "count": 20, "includePromotedContent": true], includeRaw: includeRaw)
    }

    public func likes(userId: String, includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "Likes", variables: ["userId": userId, "count": 20, "includePromotedContent": false], includeRaw: includeRaw)
    }

    public func bookmarks(includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "Bookmarks", variables: ["count": 20], includeRaw: includeRaw)
    }

    public func following(userId: String) async -> UserListResult { await usersTimeline("Following", userId: userId) }
    public func followers(userId: String) async -> UserListResult { await usersTimeline("Followers", userId: userId) }

    public func lists() async -> UserListResult {
        UserListResult(success: true, users: [], nextCursor: nil, error: nil)
    }

    public func listTimeline(_ listId: String, includeRaw: Bool = false) async -> TweetListResult {
        await timeline(operation: "ListLatestTweetsTimeline", variables: ["listId": listId, "count": 20], includeRaw: includeRaw)
    }

    public func news() async -> [[String: String]] {
        let qid = await queryId("ExplorePage")
        let r = await graphqlGET(operation: "ExplorePage", queryIds: [qid], params: [
            "variables": stringify(["includeTweetReplies": false]),
        ])
        return flattenTrends(r.json)
    }

    private func flattenTrends(_ json: [String: Any]?) -> [[String: String]] {
        var out: [[String: String]] = []
        func walk(_ any: Any?) {
            if let obj = JSON.object(any) {
                if let name = JSON.string(obj["name"]), obj["trend_url"] != nil || obj["query"] != nil {
                    out.append(["name": name, "query": JSON.string(obj["query"]) ?? name])
                }
                for v in obj.values { walk(v) }
            } else if let arr = JSON.array(any) {
                arr.forEach(walk)
            }
        }
        walk(json)
        return out
    }

    private func timeline(operation: String, variables: [String: Any], includeRaw: Bool) async -> TweetListResult {
        let qid = await queryId(operation)
        let r = await graphqlGET(operation: operation, queryIds: [qid], params: [
            "variables": stringify(variables),
            "features": stringify(tweetDetailFeatures()),
        ])
        if r.json == nil { return TweetListResult(success: false, tweets: [], nextCursor: nil, error: r.error, had404: r.had404) }
        let instructions = findInstructions(r.json)
        let tweets = JSON.walkTweets(instructions, quoteDepth: quoteDepth, includeRaw: includeRaw)
        return TweetListResult(success: true, tweets: tweets, nextCursor: JSON.cursor(instructions), error: nil, had404: r.had404)
    }

    private func usersTimeline(_ operation: String, userId: String) async -> UserListResult {
        let qid = await queryId(operation)
        let r = await graphqlGET(operation: operation, queryIds: [qid], params: [
            "variables": stringify(["userId": userId, "count": 20, "includePromotedContent": false]),
            "features": stringify(tweetDetailFeatures()),
        ])
        var users: [TwitterUser] = []
        func walk(_ any: Any?) {
            if let obj = JSON.object(any) {
                if let rest = JSON.string(obj["rest_id"]),
                   let uname = JSON.string(JSON.path(obj, "legacy", "screen_name")) ?? JSON.string(JSON.path(obj, "core", "screen_name"))
                {
                    users.append(TwitterUser(id: rest, username: uname, name: JSON.string(JSON.path(obj, "legacy", "name"))))
                }
                for v in obj.values { walk(v) }
            } else if let arr = JSON.array(any) {
                arr.forEach(walk)
            }
        }
        walk(r.json)
        return UserListResult(success: r.json != nil, users: uniqueUsers(users), nextCursor: JSON.cursor(findInstructions(r.json)), error: r.error)
    }

    private func uniqueUsers(_ users: [TwitterUser]) -> [TwitterUser] {
        var seen = Set<String>()
        return users.filter { seen.insert($0.id).inserted }
    }

    private func findInstructions(_ json: [String: Any]?) -> Any? {
        var found: Any?
        func walk(_ any: Any?) {
            if found != nil { return }
            if let obj = JSON.object(any) {
                if obj["instructions"] != nil { found = obj["instructions"]; return }
                for v in obj.values { walk(v) }
            } else if let arr = JSON.array(any) {
                arr.forEach(walk)
            }
        }
        walk(json)
        return found
    }

    private func stringify(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func tweetDetailFeatures() -> [String: Any] {
        [
            "rweb_lists_timeline_redesign_enabled": true,
            "responsive_web_graphql_exclude_directive_enabled": true,
            "verified_phone_label_enabled": false,
            "creator_subscriptions_tweet_preview_api_enabled": true,
            "responsive_web_graphql_timeline_navigation_enabled": true,
            "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
            "tweetypie_unmention_optimization_enabled": true,
            "responsive_web_edit_tweet_api_enabled": true,
            "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
            "view_counts_everywhere_api_enabled": true,
            "longform_notetweets_consumption_enabled": true,
            "responsive_web_twitter_article_tweet_consumption_enabled": true,
            "tweet_awards_web_tipping_enabled": false,
            "freedom_of_speech_not_reach_fetch_enabled": true,
            "standardized_nudges_misinfo": true,
            "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
            "longform_notetweets_rich_text_read_enabled": true,
            "longform_notetweets_inline_media_enabled": true,
            "responsive_web_media_download_video_enabled": false,
            "responsive_web_enhance_cards_enabled": false,
        ]
    }

    private func capture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
