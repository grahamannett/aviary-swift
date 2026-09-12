import Foundation

enum JSON {
    static func object(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    static func array(_ any: Any?) -> [Any]? { any as? [Any] }
    static func string(_ any: Any?) -> String? { any as? String }
    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
    static func bool(_ any: Any?) -> Bool? { any as? Bool }
    static func path(_ root: Any?, _ keys: String...) -> Any? {
        var cur: Any? = root
        for key in keys {
            cur = object(cur)?[key]
        }
        return cur
    }
    static func walkTweets(_ instructions: Any?, quoteDepth: Int, includeRaw: Bool) -> [TweetData] {
        var tweets: [TweetData] = []
        var seen = Set<String>()
        for instr in array(instructions) ?? [] {
            for entry in array(object(instr)?["entries"]) ?? [] {
                for result in tweetResults(from: entry) {
                    if let mapped = mapTweet(result, quoteDepth: quoteDepth, includeRaw: includeRaw),
                       seen.insert(mapped.id).inserted
                    {
                        tweets.append(mapped)
                    }
                }
            }
        }
        return tweets
    }

    static func cursor(_ instructions: Any?, preferredTypes: [String] = ["Bottom", "ShowMore"]) -> String? {
        var fallback: String?
        func consider(_ content: [String: Any]?) {
            guard let content else { return }
            let cursorType = string(content["cursorType"]) ?? ""
            guard let v = string(content["value"]), !v.isEmpty else { return }
            if preferredTypes.contains(cursorType) {
                if fallback == nil { fallback = v }
            }
        }
        for instr in array(instructions) ?? [] {
            for entry in array(object(instr)?["entries"]) ?? [] {
                let content = object(entry)?["content"] as? [String: Any]
                consider(content)
                consider(object(path(content, "itemContent")))
                for item in array(content?["items"]) ?? [] {
                    let o = object(item)
                    consider(object(o?["content"]))
                    consider(object(path(o, "item", "content")))
                    consider(object(path(o, "item", "itemContent")))
                }
            }
        }
        if let fallback { return fallback }
        return nil
    }

    static func tweetResults(from entry: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func push(_ any: Any?) {
            if let obj = object(any), string(obj["rest_id"]) != nil {
                out.append(obj)
            }
        }
        let content = object(entry)?["content"] as? [String: Any]
        push(path(content, "itemContent", "tweet_results", "result"))
        push(path(content, "item", "itemContent", "tweet_results", "result"))
        for item in array(content?["items"]) ?? [] {
            let o = object(item)
            push(path(o, "item", "itemContent", "tweet_results", "result"))
            push(path(o, "itemContent", "tweet_results", "result"))
            push(path(o, "content", "itemContent", "tweet_results", "result"))
        }
        return out
    }

    static func mapTweet(_ result: [String: Any], quoteDepth: Int, includeRaw: Bool) -> TweetData? {
        var result = result
        if let inner = object(result["tweet"]) as [String: Any]? {
            result = inner
        }
        guard let id = string(result["rest_id"]) else { return nil }
        let user = object(path(result, "core", "user_results", "result"))
        let username = string(path(user, "legacy", "screen_name")) ?? string(path(user, "core", "screen_name"))
        let name = string(path(user, "legacy", "name")) ?? string(path(user, "core", "name")) ?? username
        guard let username else { return nil }
        let text = extractText(result)
        guard let text else { return nil }
        var quoted: TweetData?
        if quoteDepth > 0, let q = object(path(result, "quoted_status_result", "result")) {
            quoted = mapTweet(q, quoteDepth: quoteDepth - 1, includeRaw: includeRaw)
        }
        var tweet = TweetData(
            id: id,
            text: text,
            author: TweetAuthor(username: username, name: name ?? username),
            authorId: string(user?["rest_id"]),
            createdAt: string(path(result, "legacy", "created_at")),
            replyCount: int(path(result, "legacy", "reply_count")),
            retweetCount: int(path(result, "legacy", "retweet_count")),
            likeCount: int(path(result, "legacy", "favorite_count")),
            conversationId: string(path(result, "legacy", "conversation_id_str")),
            inReplyToStatusId: string(path(result, "legacy", "in_reply_to_status_id_str")),
            quotedTweet: quoted,
            media: extractMedia(result),
            article: extractArticle(result)
        )
        if includeRaw, let data = try? JSONSerialization.data(withJSONObject: result),
           let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
        {
            tweet._raw = decoded
        }
        return tweet
    }

    static func extractText(_ result: [String: Any]) -> String? {
        let note = object(path(result, "note_tweet", "note_tweet_results", "result"))
        let candidates = [
            string(note?["text"]),
            string(path(note, "richtext", "text")),
            string(path(result, "legacy", "full_text")),
        ]
        for c in candidates {
            if let c, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c }
        }
        return nil
    }

    static func extractMedia(_ result: [String: Any]) -> [TweetMedia]? {
        let raw = array(path(result, "legacy", "extended_entities", "media"))
            ?? array(path(result, "legacy", "entities", "media"))
        guard let raw, !raw.isEmpty else { return nil }
        var media: [TweetMedia] = []
        for item in raw {
            let o = object(item)
            guard let type = string(o?["type"]), let url = string(o?["media_url_https"]) else { continue }
            media.append(TweetMedia(type: type, url: url))
        }
        return media.isEmpty ? nil : media
    }

    static func extractArticle(_ result: [String: Any]) -> TweetArticle? {
        let article = object(result["article"])
        let inner = object(path(article, "article_results", "result")) ?? article
        guard let title = string(inner?["title"]) ?? string(article?["title"]) else { return nil }
        return TweetArticle(title: title, previewText: string(inner?["preview_text"]))
    }

    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
