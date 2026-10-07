import Foundation

extension TwitterClient {
    public func getUserIdByUsername(_ username: String) async -> (success: Bool, userId: String?, username: String?, name: String?, error: String?) {
        guard let handle = normalizeHandle(username) else { return (false, nil, nil, nil, "Invalid username: \(username)") }
        let response = await graphRead(operation: "UserByScreenName", variables: ["screen_name": handle, "withSafetyModeUserFields": true],
                                       featureSet: "userLookup", fieldToggles: ["withAuxiliaryUserLabels": false])
        let result = JSON.object(JSON.path(response.json, "data", "user", "result"))
        if JSON.string(result?["__typename"]) == "UserUnavailable" { return (false, nil, nil, nil, "User @\(handle) not found or unavailable") }
        if response.success, let user = mapUser(result) { return (true, user.id, user.username, user.name, nil) }
        var lastError = response.error ?? "Could not parse user data from response"
        for host in ["https://x.com/i/api", "https://api.twitter.com"] {
            var url = URLComponents(string: "\(host)/1.1/users/show.json")!
            url.queryItems = [URLQueryItem(name: "screen_name", value: handle)]
            do {
                let (data, http) = try await request(url.url!)
                if http.statusCode == 404 { return (false, nil, nil, nil, "User @\(handle) not found") }
                let rest = parseGraph(data, http, operation: "UserByScreenName", allowPartial: false)
                if rest.success, let id = stringID(rest.json?["id_str"]) ?? stringID(rest.json?["id"]) {
                    return (true, id, JSON.string(rest.json?["screen_name"]) ?? handle, JSON.string(rest.json?["name"]), nil)
                }
                lastError = rest.error ?? "Could not parse user ID from response"
            } catch { lastError = error.localizedDescription }
        }
        return (false, nil, nil, nil, lastError)
    }

    public func getUserAboutAccount(_ username: String) async -> (success: Bool, about: AboutProfile?, error: String?) {
        guard let handle = normalizeHandle(username) else { return (false, nil, "Invalid username: \(username)") }
        let response = await graphRead(operation: "AboutAccountQuery", variables: ["screenName": handle])
        guard response.success else { return (false, nil, response.error) }
        guard let about = JSON.object(JSON.path(response.json, "data", "user_result_by_screen_name", "result", "about_profile")) else {
            return (false, nil, "Missing about_profile in response")
        }
        return (true, AboutProfile(accountBasedIn: JSON.string(about["account_based_in"]), source: JSON.string(about["source"]),
                                   createdCountryAccurate: JSON.bool(about["created_country_accurate"]), locationAccurate: JSON.bool(about["location_accurate"]),
                                   learnMoreUrl: JSON.string(about["learn_more_url"])), nil)
    }

    public func getCurrentUser() async -> (success: Bool, user: TwitterUser?, error: String?) {
        let candidates = [
            "https://x.com/i/api/account/settings.json", "https://api.twitter.com/1.1/account/settings.json",
            "https://x.com/i/api/account/verify_credentials.json?skip_status=true&include_entities=false",
            "https://api.twitter.com/1.1/account/verify_credentials.json?skip_status=true&include_entities=false",
        ]
        var lastError = "Could not determine current user from response"
        for url in candidates {
            do {
                let (data, response) = try await request(URL(string: url)!, extra: ["content-type": "application/json"])
                let parsed = parseGraph(data, response, operation: "CurrentUser", allowPartial: false)
                guard parsed.success, let json = parsed.json else { lastError = parsed.error ?? lastError; continue }
                let user = JSON.object(json["user"]) ?? json
                let id = stringID(json["user_id"]) ?? stringID(json["user_id_str"]) ?? stringID(user["id_str"]) ?? stringID(user["id"])
                if let username = JSON.string(user["screen_name"]), let id {
                    clientUserId = id
                    return (true, TwitterUser(id: id, username: username, name: JSON.string(user["name"]) ?? username), nil)
                }
            } catch { lastError = error.localizedDescription }
        }
        for url in ["https://x.com/settings/account", "https://twitter.com/settings/account"] {
            do {
                let (data, response) = try await request(URL(string: url)!, headers: ["cookie": cookieHeader, "user-agent": Self.userAgent])
                guard (200..<300).contains(response.statusCode) else { lastError = "HTTP \(response.statusCode) (settings page)"; continue }
                let html = String(data: data, encoding: .utf8) ?? ""
                if let username = capture(html, #""screen_name"\s*:\s*"([^"]+)""#), let id = capture(html, #""user_id"\s*:\s*"(\d+)""#) {
                    clientUserId = id
                    let name = capture(html, #""name"\s*:\s*"((?:\\.|[^"\\])*)""#)?.replacingOccurrences(of: #"\""#, with: "\"")
                    return (true, TwitterUser(id: id, username: username, name: name ?? username), nil)
                }
                lastError = "Could not parse settings page for user info"
            } catch { lastError = error.localizedDescription }
        }
        return (false, nil, lastError)
    }

    public func follow(_ userId: String) async -> MutationResult { await followUser(userId, follow: true) }
    public func unfollow(_ userId: String) async -> MutationResult { await followUser(userId, follow: false) }

    func followUser(_ userId: String, follow: Bool) async -> MutationResult {
        if resolveUserBeforeMutation, clientUserId == nil { _ = await getCurrentUser() }
        let action = follow ? "create" : "destroy"
        for prefix in ["https://x.com/i/api", "https://api.twitter.com"] {
            do {
                let (data, response) = try await request(URL(string: "\(prefix)/1.1/friendships/\(action).json")!, method: "POST",
                    body: formData(["user_id": userId, "skip_status": "true"]), extra: ["content-type": "application/x-www-form-urlencoded"])
                let json = JSON.parse(data)
                if let first = (JSON.array(json?["errors"]) ?? []).compactMap(JSON.object).first {
                    if JSON.int(first["code"]) == 160 { return mutationResult(success: true, userId: userId) }
                    if JSON.int(first["code"]) == 162 { return mutationResult(success: false, error: "You have been blocked from following this account") }
                    if JSON.int(first["code"]) == 108 { return mutationResult(success: false, error: "User not found") }
                }
                if response.statusCode == 404 { continue }
                let parsed = parseGraph(data, response, operation: follow ? "CreateFriendship" : "DestroyFriendship", allowPartial: false)
                guard parsed.success, let json = parsed.json else {
                    return mutationResult(success: false, error: parsed.error)
                }
                guard let id = stringID(json["id_str"]) ?? stringID(json["id"]) else {
                    return mutationResult(success: false, error: "Friendship response did not return a user ID")
                }
                return mutationResult(success: true, userId: id, username: JSON.string(json["screen_name"]))
            } catch { return mutationResult(success: false, error: error.localizedDescription) }
        }
        let response = await graphMutation(operation: follow ? "CreateFriendship" : "DestroyFriendship", variables: ["user_id": userId])
        let user = mapUser(JSON.object(JSON.path(response.json, "data", "user", "result")))
        return mutationResult(success: response.success, error: response.error, userId: response.success ? user?.id ?? userId : nil, username: user?.username)
    }

    public func following(userId: String, count: Int = 20, cursor: String? = nil) async -> UserListResult {
        await usersTimeline("Following", userId: userId, count: count, cursor: cursor)
    }
    public func followers(userId: String, count: Int = 20, cursor: String? = nil) async -> UserListResult {
        await usersTimeline("Followers", userId: userId, count: count, cursor: cursor)
    }

    func usersTimeline(_ operation: String, userId: String, count: Int, cursor: String?) async -> UserListResult {
        guard count > 0 else { return .init(success: false, users: [], nextCursor: nil, error: "Count must be greater than zero") }
        var variables: [String: Any] = ["userId": userId, "count": count, "includePromotedContent": false]
        if let cursor { variables["cursor"] = cursor }
        let response = await graphRead(operation: operation, variables: variables, featureSet: "following")
        if response.success {
            guard let instructions = instructionsForOperation(response.json, operation) else {
                return .init(success: false, users: [], nextCursor: nil, error: "Missing timeline instructions in \(operation) response")
            }
            var users: [TwitterUser] = []
            for item in JSON.timelineItemContents(instructions) {
                if let user = mapUser(JSON.object(JSON.path(item, "user_results", "result"))) { users.append(user) }
            }
            var seen = Set<String>()
            return .init(success: true, users: users.filter { seen.insert($0.id).inserted }, nextCursor: JSON.cursor(instructions), error: nil)
        }
        // Bird falls back to the cookie-auth REST lists after GraphQL query-ID failures.
        if response.needsRefresh {
            let endpoint = operation == "Followers" ? "followers" : "friends"
            var params = ["user_id": userId, "count": String(count), "skip_status": "true", "include_user_entities": "false"]
            if let cursor { params["cursor"] = cursor }
            for host in ["https://x.com/i/api", "https://api.twitter.com"] {
                var url = URLComponents(string: "\(host)/1.1/\(endpoint)/list.json")!
                url.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                do {
                    let (data, http) = try await request(url.url!)
                    let result = parseGraph(data, http, operation: operation, allowPartial: false)
                    if result.success {
                        let users = (JSON.array(result.json?["users"]) ?? []).compactMap { mapUser(JSON.object($0), rest: true) }
                        let next = stringID(result.json?["next_cursor_str"]) ?? stringID(result.json?["next_cursor"])
                        return .init(success: true, users: users, nextCursor: next == "0" ? nil : next, error: nil)
                    }
                } catch { if error is CancellationError { break } }
            }
        }
        return .init(success: false, users: [], nextCursor: nil, error: response.error)
    }

    func mapUser(_ result: [String: Any]?, rest: Bool = false) -> TwitterUser? {
        guard let result else { return nil }
        let legacy = rest ? result : JSON.object(result["legacy"]) ?? [:]
        let core = JSON.object(result["core"]) ?? [:]
        guard let id = stringID(result[rest ? "id_str" : "rest_id"]) ?? stringID(result["id"]),
              let username = JSON.string(legacy["screen_name"]) ?? JSON.string(core["screen_name"]) else { return nil }
        return TwitterUser(id: id, username: username, name: JSON.string(legacy["name"]) ?? JSON.string(core["name"]) ?? username,
                           description: JSON.string(legacy["description"]), followersCount: JSON.int(legacy["followers_count"]),
                           followingCount: JSON.int(legacy["friends_count"]), isBlueVerified: JSON.bool(result[rest ? "verified" : "is_blue_verified"]),
                           profileImageUrl: JSON.string(legacy["profile_image_url_https"]), createdAt: JSON.string(legacy["created_at"]))
    }

    func stringID(_ value: Any?) -> String? {
        JSON.string(value) ?? (value as? NSNumber)?.stringValue
    }
    func capture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
