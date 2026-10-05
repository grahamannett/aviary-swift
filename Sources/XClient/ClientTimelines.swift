import Foundation

extension TwitterClient {
    func paginateTweets(limit: Int?, maxPages: Int?, cursor: String?, delay: Int = 0, stopWhenEmpty: Bool = true,
                        fetch: (String?, Int) async -> TweetListResult) async -> TweetListResult {
        if let limit, limit <= 0 { return failure("Count must be greater than zero") }
        if let maxPages, maxPages <= 0 { return failure("maxPages must be greater than zero") }
        var tweets: [TweetData] = []
        var seen = Set<String>()
        var cursors = Set<String>()
        var current = cursor
        var pages = 0
        if let cursor { cursors.insert(cursor) }
        while true {
            do {
                try Task.checkCancellation()
                if pages > 0, delay > 0 { try await sleepMilliseconds(delay) }
            } catch { return .init(success: false, tweets: tweets, nextCursor: current, error: error.localizedDescription, had404: false) }
            let page = await fetch(current, min(20, limit.map { $0 - tweets.count } ?? 20))
            if !page.success { return .init(success: false, tweets: tweets, nextCursor: current, error: page.error, had404: page.had404) }
            pages += 1
            let before = tweets.count
            for tweet in page.tweets where seen.insert(tweet.id).inserted {
                tweets.append(tweet)
                if let limit, tweets.count >= limit { break }
            }
            guard let next = page.nextCursor, !next.isEmpty, !cursors.contains(next),
                  !(stopWhenEmpty && (page.tweets.isEmpty || before == tweets.count)) else {
                return .init(success: true, tweets: tweets, nextCursor: nil, error: nil, had404: false)
            }
            if (maxPages.map { pages >= $0 } ?? false) || (limit.map { tweets.count >= $0 } ?? false) {
                return .init(success: true, tweets: tweets, nextCursor: next, error: nil, had404: false)
            }
            cursors.insert(next)
            current = next
        }
    }

    func timelinePage(_ operation: String, variables: [String: Any], featureSet: String, includeRaw: Bool,
                      fieldToggles: [String: Bool]? = nil, allowPartial: Bool = false) async -> TweetListResult {
        var response = await graphRead(operation: operation, variables: variables, featureSet: featureSet,
                                       fieldToggles: fieldToggles, allowPartial: allowPartial)
        if operation == "BookmarkFolderTimeline", !response.success, response.error?.contains("Variable \"$count\"") == true {
            var withoutCount = variables
            withoutCount.removeValue(forKey: "count")
            response = await graphRead(operation: operation, variables: withoutCount, featureSet: featureSet, allowPartial: allowPartial)
        }
        if operation == "BookmarkFolderTimeline", !response.success, response.error?.contains("Variable \"$cursor\"") == true, variables["cursor"] != nil {
            return failure("Bookmark folder pagination rejected the cursor parameter")
        }
        guard response.success else { return failure(response.error, had404: response.needsRefresh) }
        guard let instructions = instructionsForOperation(response.json, operation) else { return failure("Missing timeline instructions in \(operation) response") }
        return .init(success: true, tweets: JSON.walkTweets(instructions, quoteDepth: quoteDepth, includeRaw: includeRaw),
                     nextCursor: JSON.cursor(instructions), error: nil, had404: false)
    }

    public func search(_ query: String, count: Int = 20, includeRaw: Bool = false, all: Bool = false, maxPages: Int? = nil, cursor: String? = nil) async -> TweetListResult {
        await paginateTweets(limit: all ? nil : count, maxPages: maxPages, cursor: cursor) { cur, size in
            var vars: [String: Any] = ["rawQuery": query, "count": size, "querySource": "typed_query", "product": "Latest"]
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage("SearchTimeline", variables: vars, featureSet: "search", includeRaw: includeRaw)
        }
    }

    public func home(count: Int = 20, following: Bool = false, includeRaw: Bool = false) async -> TweetListResult {
        await paginateTweets(limit: count, maxPages: nil, cursor: nil) { cur, size in
            var vars: [String: Any] = ["count": size, "includePromotedContent": true, "latestControlAvailable": true,
                                      "requestContext": "launch", "withCommunity": true]
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage(following ? "HomeLatestTimeline" : "HomeTimeline", variables: vars, featureSet: "homeTimeline", includeRaw: includeRaw)
        }
    }

    public func userTweets(userId: String, count: Int = 20, includeRaw: Bool = false, maxPages: Int? = nil,
                           cursor: String? = nil, pageDelayMs: Int = 1000) async -> TweetListResult {
        let pages = min(10, maxPages ?? max(1, Int(ceil(Double(count) / 20))))
        return await paginateTweets(limit: count, maxPages: pages, cursor: cursor, delay: pageDelayMs) { cur, size in
            var vars: [String: Any] = ["userId": userId, "count": size, "includePromotedContent": false,
                                      "withQuickPromoteEligibilityTweetFields": true, "withVoice": true]
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage("UserTweets", variables: vars, featureSet: "userTweets", includeRaw: includeRaw,
                                           fieldToggles: ["withArticlePlainText": false], allowPartial: true)
        }
    }

    public func likes(userId: String, count: Int = 20, includeRaw: Bool = false, all: Bool = false, maxPages: Int? = nil, cursor: String? = nil) async -> TweetListResult {
        await paginateTweets(limit: all ? nil : count, maxPages: maxPages, cursor: cursor) { cur, size in
            var vars: [String: Any] = ["userId": userId, "count": size, "includePromotedContent": false,
                                      "withClientEventToken": false, "withBirdwatchNotes": false, "withVoice": true]
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage("Likes", variables: vars, featureSet: "likes", includeRaw: includeRaw, allowPartial: true)
        }
    }

    public func bookmarks(count: Int = 20, folderId: String? = nil, includeRaw: Bool = false, all: Bool = false,
                           maxPages: Int? = nil, cursor: String? = nil) async -> TweetListResult {
        await paginateTweets(limit: all ? nil : count, maxPages: maxPages, cursor: cursor) { cur, size in
            var vars: [String: Any]
            if let folderId {
                vars = ["bookmark_collection_id": folderId, "count": size, "includePromotedContent": true]
            } else {
                vars = ["count": size, "includePromotedContent": false, "withDownvotePerspective": false,
                        "withReactionsMetadata": false, "withReactionsPerspective": false]
            }
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage(folderId == nil ? "Bookmarks" : "BookmarkFolderTimeline", variables: vars,
                                           featureSet: "bookmarks", includeRaw: includeRaw, allowPartial: true)
        }
    }

    public func listTimeline(_ listId: String, count: Int = 20, includeRaw: Bool = false, all: Bool = false,
                             maxPages: Int? = nil, cursor: String? = nil) async -> TweetListResult {
        await paginateTweets(limit: all ? nil : count, maxPages: maxPages, cursor: cursor) { cur, size in
            var vars: [String: Any] = ["listId": listId, "count": size]
            if let cur { vars["cursor"] = cur }
            return await self.timelinePage("ListLatestTweetsTimeline", variables: vars, featureSet: "lists", includeRaw: includeRaw)
        }
    }
}
