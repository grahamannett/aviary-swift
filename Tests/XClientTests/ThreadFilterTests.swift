import Testing
import XClient

@Suite struct ThreadFilterTests {
    func tweet(_ id: String, _ username: String, parent: String? = nil, created: String = "2026-01-01T00:00:00Z") -> TweetData {
        TweetData(
            id: id,
            text: id,
            author: TweetAuthor(username: username, name: username),
            createdAt: created,
            conversationId: "c1",
            inReplyToStatusId: parent
        )
    }

    @Test func authorChain() {
        let root = tweet("1", "alice", created: "2026-01-01T00:00:00Z")
        let reply = tweet("2", "alice", parent: "1", created: "2026-01-01T00:01:00Z")
        let other = tweet("3", "bob", parent: "1", created: "2026-01-01T00:02:00Z")
        let nested = tweet("5", "alice", parent: "2", created: "2026-01-01T00:04:00Z")
        let ids = filterAuthorChain(tweets: [root, reply, other, nested], bookmarkedTweet: reply).map(\.id)
        #expect(ids == ["1", "2", "5"])
    }

    @Test func authorOnly() {
        let root = tweet("1", "alice")
        let reply = tweet("2", "alice", parent: "1")
        let other = tweet("3", "bob", parent: "1")
        let ids = filterAuthorOnly(tweets: [root, reply, other], bookmarkedTweet: root).map(\.id)
        #expect(ids == ["1", "2"])
    }

    @Test func fullChain() {
        let parent = tweet("root-parent", "dave", created: "2025-12-31T00:00:00Z")
        let sibling = tweet("4", "carol", parent: "root-parent", created: "2026-01-01T00:03:00Z")
        let root = tweet("1", "alice", parent: "root-parent")
        let reply = tweet("2", "alice", parent: "1")
        let other = tweet("3", "bob", parent: "1")
        let without = filterFullChain(tweets: [parent, sibling, root, reply, other], bookmarkedTweet: root)
        #expect(without.map(\.id).sorted() == ["1", "2", "3", "root-parent"])
        let withB = filterFullChain(tweets: [parent, sibling, root, reply, other], bookmarkedTweet: root, includeAncestorBranches: true)
        #expect(withB.map(\.id).contains("4"))
    }

    @Test func metadata() {
        let root = tweet("1", "alice")
        let reply = tweet("2", "alice", parent: "1")
        let meta = addThreadMetadata(tweet: root, allConversationTweets: [root, reply])
        #expect(meta.isThread)
        #expect(meta.threadPosition == "root")
        #expect(meta.hasSelfReplies)
        #expect(meta.threadRootId == "c1")
    }
}
