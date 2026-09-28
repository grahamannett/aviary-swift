import Foundation

extension TwitterClient {
    func mutationResult(success: Bool, error: String? = nil, tweetId: String? = nil, userId: String? = nil, username: String? = nil) -> MutationResult {
        .init(success: success, userId: userId, username: username, error: error, tweetId: tweetId)
    }

    public func like(_ tweetId: String) async -> MutationResult { await mutateTweet("FavoriteTweet", tweetId: tweetId) }
    public func unlike(_ tweetId: String) async -> MutationResult { await mutateTweet("UnfavoriteTweet", tweetId: tweetId) }
    public func retweet(_ tweetId: String) async -> MutationResult { await mutateTweet("CreateRetweet", tweetId: tweetId) }
    public func unretweet(_ tweetId: String) async -> MutationResult { await mutateTweet("DeleteRetweet", tweetId: tweetId) }
    public func bookmark(_ tweetId: String) async -> MutationResult { await mutateTweet("CreateBookmark", tweetId: tweetId) }
    public func unbookmark(_ tweetId: String) async -> MutationResult { await mutateTweet("DeleteBookmark", tweetId: tweetId) }

    func mutateTweet(_ operation: String, tweetId: String) async -> MutationResult {
        var variables: [String: Any] = ["tweet_id": tweetId]
        if operation == "DeleteRetweet" { variables["source_tweet_id"] = tweetId }
        let response = await graphMutation(operation: operation, variables: variables, referer: "https://x.com/i/status/\(tweetId)")
        return mutationResult(success: response.success, error: response.error, tweetId: response.success ? tweetId : nil)
    }

    public func createTweet(text: String, replyTo: String? = nil, mediaIds: [String] = []) async -> MutationResult {
        var variables: [String: Any] = [
            "tweet_text": text, "dark_request": false, "semantic_annotation_ids": [],
            "media": ["media_entities": mediaIds.map { ["media_id": $0, "tagged_users": []] as [String: Any] }, "possibly_sensitive": false],
        ]
        if let replyTo { variables["reply"] = ["in_reply_to_tweet_id": replyTo, "exclude_reply_user_ids": []] }
        let response = await graphMutation(operation: "CreateTweet", variables: variables, featureSet: "tweetCreate", referer: "https://x.com/compose/post")
        if response.success {
            guard let id = JSON.string(JSON.path(response.json, "data", "create_tweet", "tweet_results", "result", "rest_id")) else {
                return mutationResult(success: false, error: "Tweet created but no ID returned")
            }
            return mutationResult(success: true, tweetId: id)
        }
        let errors = (JSON.array(response.json?["errors"]) ?? []).compactMap(JSON.object)
        if errors.contains(where: { JSON.int($0["code"]) == 226 }) {
            let fallback = await statusUpdate(text: text, replyTo: replyTo, mediaIds: mediaIds)
            if fallback.success { return fallback }
            return mutationResult(success: false, error: "\(response.error ?? "Posting rejected") | fallback: \(fallback.error ?? "Unknown error")")
        }
        return mutationResult(success: false, error: response.error)
    }

    func statusUpdate(text: String, replyTo: String?, mediaIds: [String]) async -> MutationResult {
        var values = ["status": text]
        if let replyTo { values["in_reply_to_status_id"] = replyTo; values["auto_populate_reply_metadata"] = "true" }
        if !mediaIds.isEmpty { values["media_ids"] = mediaIds.joined(separator: ",") }
        do {
            let (data, http) = try await request(URL(string: "https://x.com/i/api/1.1/statuses/update.json")!, method: "POST", body: formData(values),
                extra: ["content-type": "application/x-www-form-urlencoded", "referer": "https://x.com/compose/post"])
            let parsed = parseGraph(data, http, operation: "StatusUpdate", allowPartial: false)
            guard parsed.success else { return mutationResult(success: false, error: parsed.error) }
            guard let id = stringID(parsed.json?["id_str"]) ?? stringID(parsed.json?["id"]) else { return mutationResult(success: false, error: "Tweet created but no ID returned") }
            return mutationResult(success: true, tweetId: id)
        } catch { return mutationResult(success: false, error: error.localizedDescription) }
    }
}
