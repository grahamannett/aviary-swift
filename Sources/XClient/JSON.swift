import Foundation

enum JSON {
    static func object(_ any: Any?) -> [String: Any]? {
        (any as? OrderedJSONObject)?.fields ?? any as? [String: Any]
    }
    static func array(_ any: Any?) -> [Any]? { any as? [Any] }
    static func string(_ any: Any?) -> String? { any as? String }
    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
    static func bool(_ any: Any?) -> Bool? { any as? Bool }
    static func firstText(_ values: Any?...) -> String? {
        for value in values {
            if let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }
    static func path(_ root: Any?, _ keys: String...) -> Any? {
        var cur: Any? = root
        for key in keys {
            cur = object(cur)?[key]
        }
        return cur
    }
    // Only timeline containers are traversed; tweet/user payloads and quoted tweets
    // remain leaves for the operation-specific mappers.
    // Returning false from item stops traversal, retaining count-limited callers.
    static func walkTimeline(_ instructions: Any?,
                             item: ([String: Any], String?) -> Bool = { _, _ in true },
                             cursor: ([String: Any]) -> Void = { _ in }) {
        func walkNode(_ value: Any?, entryId inheritedId: String?) -> Bool {
            guard let node = object(value) else { return true }
            let entryId = inheritedId ?? string(node["entryId"])
            if let content = object(node["content"]) {
                cursor(content)
                if !walkNode(content, entryId: entryId) { return false }
            }
            if let content = object(node["itemContent"]) {
                cursor(content)
                if !item(content, entryId) { return false }
            }
            if let nested = node["item"], !walkNode(nested, entryId: entryId) { return false }
            for nested in array(node["items"]) ?? [] {
                if !walkNode(nested, entryId: entryId) { return false }
            }
            return true
        }
        for instruction in array(instructions) ?? [] {
            guard let instruction = object(instruction) else { continue }
            if let entries = array(instruction["entries"]) {
                for entry in entries {
                    if !walkNode(entry, entryId: nil) { return }
                }
            } else if let entry = instruction["entry"], !walkNode(entry, entryId: nil) {
                return
            }
            for nested in array(instruction["moduleItems"]) ?? [] {
                if !walkNode(nested, entryId: string(instruction["moduleEntryId"])) { return }
            }
        }
    }

    static func timelineItemContents(_ instructions: Any?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        walkTimeline(instructions, item: { content, _ in
            result.append(content)
            return true
        })
        return result
    }

    static func walkTweets(_ instructions: Any?, quoteDepth: Int, includeRaw: Bool) -> [TweetData] {
        var tweets: [TweetData] = []
        var seen = Set<String>()
        walkTimeline(instructions, item: { content, _ in
            if let result = object(path(content, "tweet_results", "result")),
               let mapped = mapTweet(result, quoteDepth: quoteDepth, includeRaw: includeRaw),
               seen.insert(mapped.id).inserted
            {
                tweets.append(mapped)
            }
            return true
        })
        return tweets
    }

    static func cursor(_ instructions: Any?, preferredTypes: [String] = ["Bottom", "ShowMore"]) -> String? {
        var cursors: [String: String] = [:]
        walkTimeline(instructions, cursor: { content in
            let cursorType = string(content["cursorType"]) ?? ""
            guard let value = string(content["value"]), !value.isEmpty else { return }
            if cursors[cursorType] == nil { cursors[cursorType] = value }
        })
        for type in preferredTypes {
            if let value = cursors[type] { return value }
        }
        return nil
    }

    static func mapTweet(_ result: [String: Any], quoteDepth: Int, includeRaw: Bool) -> TweetData? {
        var result = result
        if let inner = object(result["tweet"]) as [String: Any]? {
            result = inner
        }
        guard let id = string(result["rest_id"]), !id.isEmpty else { return nil }
        let rawUser = object(path(result, "core", "user_results", "result"))
        let user = object(rawUser?["user"]) ?? rawUser
        let username = string(path(user, "legacy", "screen_name")) ?? string(path(user, "core", "screen_name"))
        let name = string(path(user, "legacy", "name")) ?? string(path(user, "core", "name")) ?? username
        guard let username, !username.isEmpty else { return nil }
        let text = extractText(result)
        guard let text else { return nil }
        var quoted: TweetData?
        if quoteDepth > 0, let q = object(path(result, "quoted_status_result", "result")) {
            quoted = mapTweet(q, quoteDepth: quoteDepth - 1, includeRaw: includeRaw)
        }
        var raw: AnyCodable?
        if includeRaw, let data = try? JSONSerialization.data(withJSONObject: foundationValue(result)) {
            raw = try? JSONDecoder().decode(AnyCodable.self, from: data)
        }
        return TweetData(
            id: id,
            text: text,
            author: TweetAuthor(username: username, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? username),
            authorId: string(user?["rest_id"]),
            createdAt: string(path(result, "legacy", "created_at")),
            replyCount: int(path(result, "legacy", "reply_count")),
            retweetCount: int(path(result, "legacy", "retweet_count")),
            likeCount: int(path(result, "legacy", "favorite_count")),
            conversationId: string(path(result, "legacy", "conversation_id_str")),
            inReplyToStatusId: string(path(result, "legacy", "in_reply_to_status_id_str")),
            quotedTweet: quoted,
            media: extractMedia(result),
            article: extractArticle(result),
            _raw: raw
        )
    }

    static func extractText(_ result: [String: Any]) -> String? {
        if let article = extractArticleText(result) { return article }
        let note = object(path(result, "note_tweet", "note_tweet_results", "result"))
        return firstText(note?["text"], path(note, "richtext", "text"), path(note, "rich_text", "text"),
                         path(note, "content", "text"), path(note, "content", "richtext", "text"),
                         path(note, "content", "rich_text", "text"), path(result, "legacy", "full_text"))
    }

    static func extractMedia(_ result: [String: Any]) -> [TweetMedia]? {
        let raw = array(path(result, "legacy", "extended_entities", "media"))
            ?? array(path(result, "legacy", "entities", "media"))
        guard let raw, !raw.isEmpty else { return nil }
        var media: [TweetMedia] = []
        for item in raw {
            let o = object(item)
            guard let type = string(o?["type"]), let url = string(o?["media_url_https"]) else { continue }
            let sizes = object(o?["sizes"])
            let size = object(sizes?["large"]) ?? object(sizes?["medium"])
            let video = object(o?["video_info"])
            var videoURL: String?
            var duration: Int?
            if (type == "video" || type == "animated_gif"), array(video?["variants"]) != nil {
                let variants = (array(video?["variants"]) ?? []).compactMap(object).filter {
                    string($0["content_type"]) == "video/mp4" && string($0["url"]) != nil
                }
                let best = variants.filter { int($0["bitrate"]) != nil }.max {
                    (int($0["bitrate"]) ?? 0) < (int($1["bitrate"]) ?? 0)
                } ?? variants.first
                videoURL = string(best?["url"])
                duration = int(video?["duration_millis"])
            }
            media.append(TweetMedia(type: type, url: url, width: int(size?["w"]), height: int(size?["h"]),
                                    previewUrl: object(sizes?["small"]) == nil ? nil : "\(url):small",
                                    videoUrl: videoURL, durationMs: duration))
        }
        return media.isEmpty ? nil : media
    }

    static func extractArticle(_ result: [String: Any]) -> TweetArticle? {
        let article = object(result["article"])
        let inner = object(path(article, "article_results", "result")) ?? article
        guard let title = firstText(inner?["title"], article?["title"]) else { return nil }
        return TweetArticle(title: title, previewText: firstText(inner?["preview_text"], article?["preview_text"]))
    }

    static func parse(_ data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data), let fields = value as? [String: Any] else { return nil }
        var ordering = JSONFieldOrder(data: data)
        let restored = ordering.restore(in: fields)
        return ordering.valid ? object(restored) ?? fields : fields
    }
}
