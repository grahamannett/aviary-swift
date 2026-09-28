import XCTest
import XClient

final class ThreadFilterTests: XCTestCase {
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

    func testAuthorChain() {
        let root = tweet("1", "alice", created: "2026-01-01T00:00:00Z")
        let reply = tweet("2", "alice", parent: "1", created: "2026-01-01T00:01:00Z")
        let other = tweet("3", "bob", parent: "1", created: "2026-01-01T00:02:00Z")
        let nested = tweet("5", "alice", parent: "2", created: "2026-01-01T00:04:00Z")
        let ids = filterAuthorChain(tweets: [root, reply, other, nested], bookmarkedTweet: reply).map(\.id)
        XCTAssertTrue(ids == ["1", "2", "5"])
    }

    func testAuthorOnly() {
        let root = tweet("1", "alice")
        let reply = tweet("2", "alice", parent: "1")
        let other = tweet("3", "bob", parent: "1")
        let ids = filterAuthorOnly(tweets: [root, reply, other], bookmarkedTweet: root).map(\.id)
        XCTAssertTrue(ids == ["1", "2"])
    }

    func testFullChain() {
        let parent = tweet("root-parent", "dave", created: "2025-12-31T00:00:00Z")
        let sibling = tweet("4", "carol", parent: "root-parent", created: "2026-01-01T00:03:00Z")
        let root = tweet("1", "alice", parent: "root-parent")
        let reply = tweet("2", "alice", parent: "1")
        let other = tweet("3", "bob", parent: "1")
        let without = filterFullChain(tweets: [parent, sibling, root, reply, other], bookmarkedTweet: root)
        XCTAssertTrue(without.map(\.id).sorted() == ["1", "2", "3", "root-parent"])
        let withB = filterFullChain(tweets: [parent, sibling, root, reply, other], bookmarkedTweet: root, includeAncestorBranches: true)
        XCTAssertTrue(withB.map(\.id).contains("4"))
    }

    func testMetadata() {
        let root = tweet("1", "alice")
        let reply = tweet("2", "alice", parent: "1")
        let meta = addThreadMetadata(tweet: root, allConversationTweets: [root, reply])
        XCTAssertTrue(meta.isThread)
        XCTAssertTrue(meta.threadPosition == "root")
        XCTAssertTrue(meta.hasSelfReplies)
        XCTAssertTrue(meta.threadRootId == "c1")
    }

    func testMixedTimestampFormatsAndEmptyParent() {
        let early = tweet("early", "alice", created: "2026-01-01T00:01:00Z")
        let late = tweet("late", "alice", created: "2026-01-01T00:02:00.123Z")
        XCTAssertEqual([late, early].sorted(by: tweetCreatedAtAsc).map(\.id), ["early", "late"])
        XCTAssertEqual(tweetTimestamp("Thu Jan 01 00:01:00 +0000 2026"), tweetTimestamp(early.createdAt))
        XCTAssertEqual(addThreadMetadata(tweet: tweet("root", "alice", parent: ""), allConversationTweets: []).threadPosition, "standalone")
    }

    func testCyclesAndDuplicateIDsDoNotTrapOrLoop() {
        let first = tweet("a", "alice", parent: "b")
        let second = tweet("b", "alice", parent: "a")
        XCTAssertEqual(Set(filterAuthorChain(tweets: [first, second, first], bookmarkedTweet: first).map(\.id)), ["a", "b"])
        XCTAssertEqual(Set(filterFullChain(tweets: [first, second, first], bookmarkedTweet: first).map(\.id)), ["a", "b"])
    }
}
