import Foundation

public func filterAuthorChain(tweets: [TweetData], bookmarkedTweet: TweetData) -> [TweetData] {
    let author = bookmarkedTweet.author.username
    var byId = Dictionary(uniqueKeysWithValues: tweets.map { ($0.id, $0) })
    var chainIds = Set<String>()
    var current: TweetData? = bookmarkedTweet
    while let cur = current, cur.author.username == author {
        chainIds.insert(cur.id)
        guard let parentId = cur.inReplyToStatusId else { break }
        guard let parent = byId[parentId], parent.author.username == author else { break }
        current = parent
    }
    var changed = true
    while changed {
        changed = false
        for tweet in tweets {
            if tweet.author.username != author { continue }
            if chainIds.contains(tweet.id) { continue }
            if let parent = tweet.inReplyToStatusId, chainIds.contains(parent) {
                chainIds.insert(tweet.id)
                changed = true
            }
        }
    }
    return tweets.filter { chainIds.contains($0.id) }.sorted(by: createdAtAsc)
}

public func filterAuthorOnly(tweets: [TweetData], bookmarkedTweet: TweetData) -> [TweetData] {
    tweets.filter { $0.author.username == bookmarkedTweet.author.username }
}

public func filterFullChain(tweets: [TweetData], bookmarkedTweet: TweetData, includeAncestorBranches: Bool = false) -> [TweetData] {
    let byId = Dictionary(uniqueKeysWithValues: tweets.map { ($0.id, $0) })
    var repliesByParent: [String: [TweetData]] = [:]
    for tweet in tweets {
        if let p = tweet.inReplyToStatusId {
            repliesByParent[p, default: []].append(tweet)
        }
    }
    var chainIds = Set<String>([bookmarkedTweet.id])
    var ancestorIds: [String] = []
    var current: TweetData? = bookmarkedTweet
    while let parentId = current?.inReplyToStatusId, let parent = byId[parentId] {
        if !chainIds.contains(parent.id) {
            chainIds.insert(parent.id)
            ancestorIds.append(parent.id)
        }
        current = parent
    }
    func addDescendants(_ start: [String]) {
        var queue = start
        while !queue.isEmpty {
            let currentId = queue.removeFirst()
            chainIds.insert(currentId)
            for reply in repliesByParent[currentId] ?? [] {
                if chainIds.contains(reply.id) { continue }
                chainIds.insert(reply.id)
                queue.append(reply.id)
            }
        }
    }
    addDescendants([bookmarkedTweet.id])
    if includeAncestorBranches {
        for id in ancestorIds { addDescendants([id]) }
    }
    return tweets.filter { chainIds.contains($0.id) }.sorted(by: createdAtAsc)
}

public struct ThreadMetadata {
    public var isThread: Bool
    public var threadPosition: String
    public var hasSelfReplies: Bool
    public var threadRootId: String?
}

public func addThreadMetadata(tweet: TweetData, allConversationTweets: [TweetData]) -> ThreadMetadata {
    let author = tweet.author.username
    let hasSelfReplies = allConversationTweets.contains {
        $0.inReplyToStatusId == tweet.id && $0.author.username == author
    }
    let isRoot = tweet.inReplyToStatusId == nil
    let position: String
    if isRoot && !hasSelfReplies { position = "standalone" }
    else if isRoot && hasSelfReplies { position = "root" }
    else if !isRoot && hasSelfReplies { position = "middle" }
    else { position = "end" }
    return ThreadMetadata(
        isThread: hasSelfReplies || !isRoot,
        threadPosition: position,
        hasSelfReplies: hasSelfReplies,
        threadRootId: tweet.conversationId
    )
}

private func createdAtAsc(_ a: TweetData, _ b: TweetData) -> Bool {
    return tweetTime(a.createdAt) < tweetTime(b.createdAt)
}

private func tweetTime(_ value: String?) -> Double {
    guard let value else { return 0 }
    if let d = ISO8601DateFormatter().date(from: value) { return d.timeIntervalSince1970 }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
    return f.date(from: value)?.timeIntervalSince1970 ?? 0
}
