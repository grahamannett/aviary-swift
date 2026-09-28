import Foundation

extension TwitterClient {
    public func lists(count: Int = 100, memberships: Bool = false) async -> ListsResult {
        guard count > 0 else { return ListsResult(success: false, lists: [], error: "Count must be greater than zero") }
        let current = await getCurrentUser()
        guard current.success, let user = current.user else { return ListsResult(success: false, lists: [], error: current.error) }
        let operation = memberships ? "ListMemberships" : "ListOwnerships"
        let response = await graphRead(operation: operation, variables: ["userId": user.id, "count": count,
            "isListMembershipShown": true, "isListMemberTargetUserId": user.id], featureSet: "lists")
        guard response.success else { return ListsResult(success: false, lists: [], error: response.error) }
        guard let instructions = instructionsForOperation(response.json, operation) else { return ListsResult(success: false, lists: [], error: "Missing list timeline in response") }
        let lists = timelineItemContents(instructions).compactMap { item -> TwitterList? in
            guard let list = JSON.object(item["list"]), let id = stringID(list["id_str"]), let name = JSON.string(list["name"]) else { return nil }
            let owner = mapUser(JSON.object(JSON.path(list, "user_results", "result"))).map {
                TwitterUser(id: $0.id, username: $0.username, name: $0.name)
            }
            return TwitterList(id: id, name: name, description: JSON.string(list["description"]), memberCount: JSON.int(list["member_count"]),
                               subscriberCount: JSON.int(list["subscriber_count"]), isPrivate: JSON.string(list["mode"])?.lowercased() == "private",
                               createdAt: JSON.string(list["created_at"]), owner: owner)
        }
        return ListsResult(success: true, lists: lists, error: nil)
    }

    public func news(count: Int = 10, includeRaw: Bool = false, withTweets: Bool = false, tweetsPerItem: Int = 5,
                     aiOnly: Bool = false, tabs: [String] = ["forYou", "news", "sports", "entertainment"]) async -> NewsResult {
        guard count > 0, tweetsPerItem > 0 else { return NewsResult(success: false, items: [], error: "Counts must be greater than zero") }
        let timelineIds = [
            "forYou": "VGltZWxpbmU6DAC2CwABAAAAB2Zvcl95b3UAAA==", "trending": "VGltZWxpbmU6DAC2CwABAAAACHRyZW5kaW5nAAA=",
            "news": "VGltZWxpbmU6DAC2CwABAAAABG5ld3MAAA==", "sports": "VGltZWxpbmU6DAC2CwABAAAABnNwb3J0cwAA",
            "entertainment": "VGltZWxpbmU6DAC2CwABAAAADWVudGVydGFpbm1lbnQAAA==",
        ]
        var items: [NewsItem] = []
        var seen = Set<String>()
        var lastError: String?
        for tab in tabs {
            guard let id = timelineIds[tab] else { continue }
            let response = await graphRead(operation: "GenericTimelineById", variables: ["timelineId": id, "count": min(count, Int.max / 2) * 2, "includePromotedContent": false], featureSet: "explore")
            guard response.success else { lastError = response.error; continue }
            let instructions = instructionsForOperation(response.json, "GenericTimelineById")
            for instruction in JSON.array(instructions) ?? [] {
                let object = JSON.object(instruction) ?? [:]
                let entries = JSON.array(object["entries"]) ?? object["entry"].map { [$0] } ?? []
                for entry in entries {
                    let entryId = JSON.string(JSON.object(entry)?["entryId"])
                    let wrapper: [[String: Any]] = [["entries": [entry]]]
                    for content in timelineItemContents(wrapper) {
                        if let item = parseNewsItem(content, entryId: entryId, source: tab, aiOnly: aiOnly, includeRaw: includeRaw), seen.insert(item.headline).inserted {
                            items.append(item)
                        }
                        if items.count >= count { break }
                    }
                    if items.count >= count { break }
                }
                if items.count >= count { break }
            }
            if items.count >= count { break }
        }
        guard !items.isEmpty else { return NewsResult(success: false, items: [], error: lastError ?? "No news items found") }
        if withTweets {
            for index in items.indices {
                let result = await search(items[index].headline, count: tweetsPerItem, includeRaw: includeRaw)
                if result.success { items[index].tweets = result.tweets }
            }
        }
        return NewsResult(success: true, items: items, error: nil)
    }

    func parseNewsItem(_ content: [String: Any], entryId: String?, source: String, aiOnly: Bool, includeRaw: Bool) -> NewsItem? {
        guard let headline = JSON.string(content["name"]) ?? JSON.string(content["title"]), !headline.isEmpty else { return nil }
        let metadata = JSON.object(content["trend_metadata"]) ?? [:]
        let url = JSON.string(JSON.path(content, "trend_url", "url")) ?? JSON.string(JSON.path(metadata, "url", "url"))
        let social = JSON.string(JSON.path(content, "social_context", "text")) ?? ""
        let ai = JSON.bool(content["is_ai_trend"]) == true || (headline.split(separator: " ").count >= 5 && (social.contains("News") || social.contains("hours ago")))
        if aiOnly, !ai { return nil }
        var category = "Trending"
        var timeAgo: String?
        var postCount: Int?
        for part in social.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if part.contains("ago") { timeAgo = part }
            else if let count = parsePostCount(part) { postCount = count }
            else if !part.isEmpty { category = part }
        }
        if let description = JSON.string(metadata["meta_description"]), let count = parsePostCount(description) { postCount = count }
        if ["Trending", "News"].contains(category), let domain = JSON.string(metadata["domain_context"]) { category = domain }
        return NewsItem(id: url ?? "\(entryId ?? source)-\(headline)", headline: headline, category: ai ? "AI · \(category)" : category,
                        timeAgo: timeAgo, postCount: postCount, description: JSON.string(content["description"]), url: url,
                        tweets: nil, _raw: includeRaw ? rawJSON(content) : nil)
    }

    func parsePostCount(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"([\d,]+(?:\.\d+)?)([KMB]?)\s*posts?"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let number = Double(text[numberRange].replacingOccurrences(of: ",", with: "")), number.isFinite,
              let suffixRange = Range(match.range(at: 2), in: text) else { return nil }
        let multiplier: Double = ["K": 1_000, "M": 1_000_000, "B": 1_000_000_000][String(text[suffixRange]).uppercased()] ?? 1
        let count = (number * multiplier).rounded()
        return count < Double(Int.max) ? Int(count) : nil
    }
}
