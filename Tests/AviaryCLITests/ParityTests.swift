import ArgumentParser
import Foundation
import XCTest
@testable import AviaryCLI
import XClient

final class ParityCommandTests: XCTestCase {
    private func parse<T>(_ args: [String], as type: T.Type) throws -> T {
        try XCTUnwrap(AviaryRoot.parseAsRoot(AviaryRoot.rewrittenArguments(args)) as? T)
    }

    func testShorthandSkipsGlobalOptionValues() throws {
        let url = "https://x.com/example/status/123456789"
        let command = try parse(["--timeout", "1000", "--chrome-profile", "Profile 1", url, "--json"], as: Read.self)
        XCTAssertEqual(command.tweetIdOrUrl, url)
        XCTAssertEqual(command.opts.timeout, "1000")
        XCTAssertEqual(command.opts.chromeProfile, "Profile 1")
        XCTAssertTrue(command.json.asJson)
        XCTAssertEqual(AviaryRoot.rewrittenArguments(["--", "123456789"]), ["read", "123456789"])
        XCTAssertEqual(AviaryRoot.rewrittenArguments(["https://x.com/example"]), ["https://x.com/example"])
        XCTAssertEqual(AviaryRoot.rewrittenArguments(["--auth-token", "123456789", "whoami"]), ["--auth-token", "123456789", "whoami"])
        XCTAssertEqual(AviaryRoot.rewrittenArguments(["-V"]), ["--version"])
        XCTAssertEqual(AviaryRoot.rewrittenArguments(["tweet", "--", "-V"]), ["tweet", "--", "-V"])
    }

    func testVersionFlagDoesNotRewriteCommandOptionValues() throws {
        let search = try parse(["search", "swift", "--count", "-V"], as: Search.self)
        XCTAssertEqual(search.count, "-V")
        XCTAssertThrowsError(try timelineCount(search.count, usingPagination: false))
        let replies = try parse(["replies", "123", "--cursor", "-V"], as: Replies.self)
        XCTAssertEqual(try replies.page.resolved().cursor, "-V")
        let userTweets = try parse(["user-tweets", "alice", "--cursor", "-V"], as: UserTweets.self)
        XCTAssertEqual(userTweets.cursor, "-V")
    }

    func testOpaqueValuesCannotEnableOutputFlags() throws {
        for flag in ["--plain", "--no-emoji", "--no-color"] {
            let args = ["search", "swift", "--cursor", flag, "--max-pages", "0"]
            let invocation = InvocationArguments(args)
            let command = try parse(args, as: Search.self)
            XCTAssertEqual(command.page.cursor, flag)
            XCTAssertFalse(command.opts.plain)
            XCTAssertFalse(command.opts.noEmojiFlag)
            XCTAssertFalse(command.opts.noColorFlag)
            XCTAssertFalse(invocation.output.plain)
            XCTAssertTrue(invocation.output.emoji)
            XCTAssertThrowsError(try command.page.resolved())
        }
        let command = try parse(["search", "swift", "--cursor", "--plain", "--plain"], as: Search.self)
        XCTAssertEqual(command.page.cursor, "--plain")
        XCTAssertTrue(command.opts.plain)
        let tweet = try parse(["tweet", "--", "--plain"], as: Tweet.self)
        XCTAssertEqual(tweet.text, "--plain")
        XCTAssertFalse(tweet.opts.plain)
        XCTAssertFalse(InvocationArguments(["tweet", "--", "--plain"]).output.plain)
        let media = try parse(["tweet", "hello", "--alt", "-V"], as: Tweet.self)
        XCTAssertEqual(media.opts.alt, ["-V"])
    }

    func testGlobalFlagsBeforeAndAfterCommand() throws {
        for args in [
            ["--plain", "--quote-depth", "3", "read", "123"],
            ["read", "--plain", "123", "--quote-depth=3"],
        ] {
            let command = try parse(args, as: Read.self)
            XCTAssertTrue(command.opts.plain)
            XCTAssertEqual(command.opts.quoteDepth, "3")
        }
        let command = try parse(["--media", "one.jpg", "tweet", "hello", "--media", "two.png", "--alt", "first"], as: Tweet.self)
        XCTAssertEqual(command.opts.media, ["one.jpg", "two.png"])
        XCTAssertEqual(command.opts.alt, ["first"])
    }

    func testBirdCommandDefaults() throws {
        XCTAssertNil(try parse(["mentions"], as: Mentions.self).username)
        XCTAssertNil(try parse(["likes"], as: Likes.self).username)
        XCTAssertNil(try parse(["following"], as: Following.self).flags.user)
        XCTAssertNil(try parse(["followers"], as: Followers.self).flags.username)
        XCTAssertEqual(try parse(["search", "swift"], as: Search.self).count, "10")
        XCTAssertEqual(try parse(["mentions"], as: Mentions.self).count, "10")
        XCTAssertEqual(try parse(["home"], as: Home.self).count, "20")
        XCTAssertFalse(try parse(["home"], as: Home.self).following)
        XCTAssertEqual(try parse(["lists"], as: Lists.self).count, "100")
        XCTAssertEqual(try parse(["news"], as: News.self).tweetsPerItem, "5")
        XCTAssertEqual(try parse(["news"], as: News.self).count, "10")
        XCTAssertEqual(try parse(["bookmarks"], as: Bookmarks.self).count, "20")
        XCTAssertEqual(try parse(["likes"], as: Likes.self).count, "20")
        XCTAssertEqual(try parse(["following"], as: Following.self).flags.count, "20")
        XCTAssertEqual(try parse(["followers"], as: Followers.self).flags.count, "20")
        XCTAssertEqual(try parse(["list-timeline", "12345"], as: ListTimeline.self).count, "20")
        XCTAssertEqual(try parse(["replies", "123"], as: Replies.self).delay, "1000")
        XCTAssertEqual(try parse(["thread", "123"], as: AviaryCLI.Thread.self).delay, "1000")
        let userTweets = try parse(["user-tweets", "alice"], as: UserTweets.self).limits()
        XCTAssertEqual(userTweets.count, 20)
        XCTAssertEqual(userTweets.delay, 1000)
        XCTAssertNil(userTweets.maxPages)
    }

    func testRequiredArgumentsCannotBeOmitted() {
        for args in [["read"], ["replies"], ["thread"], ["search"], ["tweet"], ["reply"], ["reply", "123"],
                     ["user-tweets"], ["unbookmark"], ["list-timeline"], ["follow"], ["unfollow"], ["about"]] {
            XCTAssertThrowsError(try AviaryRoot.parseAsRoot(args), "\(args) must require its target or text")
        }
    }

    func testEmptyCountsUseCommandDefaults() throws {
        for fallback in [5, 10, 20, 100] {
            XCTAssertEqual(try countFlag("", defaultValue: fallback), fallback)
            XCTAssertThrowsError(try countFlag(" ", defaultValue: fallback))
        }
        XCTAssertEqual(try timelineCount("", usingPagination: false, defaultValue: 10), 10)
        XCTAssertEqual(try timelineCount("", usingPagination: false), 20)
        XCTAssertEqual(try timelineCount("", usingPagination: true, defaultValue: 10), 20)
        let command = try parse(["user-tweets", "alice", "--count", ""], as: UserTweets.self)
        XCTAssertEqual(try command.limits().count, 20)
        XCTAssertThrowsError(try positiveInt("", flag: "--max-pages"))
    }

    func testCanonicalValidationMessages() async throws {
        let mentions = try parse(["mentions", "--user", "invalid-handle"], as: Mentions.self)
        do {
            try await mentions.run()
            XCTFail("Invalid handle must fail before accessing credentials")
        } catch let error as CLIError {
            XCTAssertEqual(error.description, "Invalid --user handle. Expected something like @steipete (letters, digits, underscore; max 15).")
            XCTAssertEqual(error.exitCode, 2)
        }
        for flag in ["--count", "--tweets-per-item"] {
            let news = try parse(["news", flag, "0"], as: News.self)
            do {
                try await news.run()
                XCTFail("Invalid count must fail before accessing credentials")
            } catch let error as CLIError {
                XCTAssertEqual(error.description, "\(flag) must be a positive number")
                XCTAssertEqual(error.exitCode, 1)
            }
        }
    }

    func testReadAndListPaginationContracts() throws {
        let replies = try parse(["replies", "123", "--all", "--max-pages", "2", "--delay", "0", "--json-full"], as: Replies.self)
        let page = try replies.page.resolved(maxPagesImpliesPagination: true)
        XCTAssertEqual(page.maxPages, 2)
        XCTAssertTrue(page.use)
        XCTAssertEqual(try nonNegativeInt(replies.delay, flag: "--delay"), 0)
        XCTAssertTrue(replies.json.includeRaw)
        let thread = try parse(["thread", "123", "--max-pages", "3"], as: AviaryCLI.Thread.self)
        XCTAssertTrue(try thread.page.resolved(maxPagesImpliesPagination: true).use)
        let search = try parse(["search", "swift", "--max-pages", "2"], as: Search.self)
        XCTAssertThrowsError(try search.page.resolved())
        let following = try parse(["following", "--cursor", "next", "--max-pages", "2"], as: Following.self)
        XCTAssertThrowsError(try following.flags.page.resolved(requiresAll: true))
        let list = try parse(["list-timeline", "12345", "-n", "40", "--max-pages", "2"], as: ListTimeline.self)
        XCTAssertEqual(list.count, "40")
        XCTAssertTrue(try list.page.resolved(maxPagesImpliesPagination: true).use)
    }

    func testAllRestoredOptionsParse() throws {
        let bookmarks = try parse(["bookmarks", "-n", "80", "--folder-id", "12345", "--all", "--max-pages", "4", "--cursor", "resume",
                                   "--expand-root-only", "--author-chain", "--author-only", "--full-chain-only",
                                   "--include-ancestor-branches", "--include-parent", "--thread-meta", "--sort-chronological", "--json-full"], as: Bookmarks.self)
        XCTAssertTrue(bookmarks.fullChain && bookmarks.threadMeta && bookmarks.includeParent && bookmarks.sortChronological)
        XCTAssertEqual(bookmarks.folderId, "12345")
        XCTAssertEqual(try bookmarks.page.resolved().maxPages, 4)
        XCTAssertTrue(try parse(["bookmarks", "--full-chain"], as: Bookmarks.self).fullChain)
        XCTAssertEqual(try parse(["mentions", "--user", "@alice", "-n", "7"], as: Mentions.self).user, "@alice")
        XCTAssertEqual(try parse(["following", "--user", "12345", "--all"], as: Following.self).flags.user, "12345")
        XCTAssertTrue(try parse(["home", "--following"], as: Home.self).following)
        XCTAssertTrue(try parse(["lists", "--member-of"], as: Lists.self).memberOf)
        XCTAssertEqual(try parse(["unbookmark", "1", "2", "3"], as: Unbookmark.self).tweetIdOrUrls, ["1", "2", "3"])
    }

    func testPaginatedTimelinesIgnoreUnusedCount() throws {
        let search = try parse(["search", "swift", "--all", "--count", "invalid"], as: Search.self)
        let bookmarks = try parse(["bookmarks", "--cursor", "next", "--count", "0"], as: Bookmarks.self)
        let likes = try parse(["likes", "--all", "--count=-1"], as: Likes.self)
        let list = try parse(["list-timeline", "12345", "--max-pages", "2", "--count", "invalid"], as: ListTimeline.self)
        for (raw, paged) in [
            (search.count, try search.page.resolved().use),
            (bookmarks.count, try bookmarks.page.resolved().use),
            (likes.count, try likes.page.resolved().use),
            (list.count, try list.page.resolved(maxPagesImpliesPagination: true).use),
        ] {
            XCTAssertEqual(try timelineCount(raw, usingPagination: paged), 20)
            XCTAssertThrowsError(try timelineCount(raw, usingPagination: false))
        }
    }

    func testNewsAliasAndTabDefaults() throws {
        let news = try parse(["trending", "--sports", "--news-only", "--ai-only", "--with-tweets", "--tweets-per-item", "3", "--json-full"], as: News.self)
        XCTAssertEqual(news.selectedTabs, ["news", "sports"])
        XCTAssertTrue(news.aiOnly && news.withTweets && news.json.includeRaw)
        XCTAssertEqual(try parse(["news"], as: News.self).selectedTabs, ["forYou", "news", "sports", "entertainment"])
    }

    func testUserTweetsLimitsAndValidation() throws {
        let valid = try parse(["user-tweets", "@alice", "-n", "200", "--max-pages", "10", "--delay", "0"], as: UserTweets.self)
        XCTAssertEqual(try valid.limits().count, 200)
        XCTAssertEqual(try valid.limits().maxPages, 10)
        for args in [
            ["user-tweets", "alice", "-n", "201"],
            ["user-tweets", "alice", "--max-pages", "11"],
            ["user-tweets", "alice", "--delay", "-1"],
        ] {
            XCTAssertThrowsError(try parse(args, as: UserTweets.self).limits()) { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
            }
        }
        XCTAssertEqual(integerPrefix("  +12.8rest"), 12)
        XCTAssertThrowsError(try positiveInt("0", flag: "--count"))
        XCTAssertThrowsError(try positiveInt("-1", flag: "--count"))
        XCTAssertThrowsError(try rejectConflictingTarget(user: "123", positional: "alice"))
    }

    func testListAndFolderURLExtraction() {
        XCTAssertEqual(extractCollectionID(" https://x.com/i/lists/12345?s=20 ", kind: "lists"), "12345")
        XCTAssertEqual(extractCollectionID("https://twitter.com/i/bookmarks/12345", kind: "bookmarks"), "12345")
        XCTAssertEqual(extractCollectionID("12345", kind: "lists"), "12345")
        XCTAssertNil(extractCollectionID("123", kind: "lists"))
        XCTAssertNil(extractCollectionID("https://x.com/example/status/12345", kind: "lists"))
    }
}

final class ParityOutputTests: XCTestCase {
    private let normal = CLIOutput(isTTY: false, environment: [:])
    private let plain = CLIOutput(plain: true, isTTY: false, environment: [:])

    func testEmptyUserCollectionsDifferInAllMode() throws {
        let opts = try GlobalOptions.parse(["--plain"])
        let result = UserListResult(success: true, users: [], nextCursor: nil, error: nil)
        var lines: [String] = [], errors: [String] = []
        try printUserResult(result, json: false, pagination: true, all: true, opts: opts, kind: "following",
            write: { lines.append($0) }, writeError: { errors.append($0) })
        XCTAssertEqual(lines, [])
        XCTAssertEqual(errors, ["[info] Total: 0 users"])
        errors.removeAll()
        try printUserResult(result, json: false, pagination: false, all: false, opts: opts, kind: "followers",
            write: { lines.append($0) }, writeError: { errors.append($0) })
        XCTAssertEqual(lines, ["No users found."])
        XCTAssertTrue(errors.isEmpty)
    }

    private func example() -> TweetData {
        TweetData(id: "100", text: "Main post", author: TweetAuthor(username: "alice", name: "Alice"),
                  createdAt: "Tue Sep 22 13:27:42 +0000 2026", replyCount: 3, retweetCount: 2, likeCount: 5,
                  quotedTweet: TweetData(id: "99", text: "Quoted post\nSecond line", author: TweetAuthor(username: "bob", name: "Bob"),
                                         media: [TweetMedia(type: "photo", url: "https://example.com/photo.jpg")]))
    }

    func testQuotedTweetRenderingMatchesBird() {
        XCTAssertEqual(normal.tweets([example()], separator: false), """

        @alice (Alice):
        Main post
        ┌─ QT @bob:
        │ Quoted post
        │ Second line
        │ 🖼️ https://example.com/photo.jpg
        └─ https://x.com/bob/status/99
        📅 Tue Sep 22 13:27:42 +0000 2026
        🔗 https://x.com/alice/status/100
        """)
        XCTAssertEqual(normal.stats(example()), "❤️ 5  🔁 2  💬 3")
        let text = plain.tweets([example()], separator: false)
        XCTAssertTrue(text.contains(">  QT @bob:\n> Quoted post\n> Second line\n> PHOTO: https://example.com/photo.jpg\n>  https://x.com/bob/status/99"))
        XCTAssertTrue(text.contains("date: Tue Sep 22"))
        XCTAssertTrue(text.contains("url: https://x.com/alice/status/100"))
        XCTAssertEqual(plain.stats(example()), "likes: 5  retweets: 2  replies: 3")
    }

    func testQuoteTruncationAndArticlePresentation() {
        let quoted = TweetData(id: "2", text: String(repeating: "x", count: 300), author: TweetAuthor(username: "bob", name: "Bob"))
        let tweet = TweetData(id: "1", text: "Title\nFull article", author: TweetAuthor(username: "alice", name: "Alice"),
                              quotedTweet: quoted, article: TweetArticle(title: "Title", previewText: "Preview"))
        let text = plain.tweets([tweet])
        XCTAssertTrue(text.contains("Article: Title\nFull article"))
        XCTAssertTrue(text.contains("> " + String(repeating: "x", count: 280) + "..."))
        XCTAssertFalse(text.contains("Preview"))
        let preview = TweetData(id: "1", text: "Intro", author: TweetAuthor(username: "alice", name: "Alice"),
                                article: TweetArticle(title: "Title", previewText: "Preview"))
        XCTAssertTrue(plain.tweets([preview]).contains("Article: Title\n   Preview"))
    }

    func testDistinctPlainAndNoEmojiAndTerminalModes() {
        let noEmoji = CLIOutput(noEmoji: true, isTTY: false, environment: [:])
        XCTAssertEqual(plain.status("ok"), "[ok] ")
        XCTAssertEqual(noEmoji.status("ok"), "OK: ")
        XCTAssertEqual(plain.label("userId"), "user_id: ")
        XCTAssertEqual(noEmoji.label("userId"), "User ID: ")
        XCTAssertFalse(CLIOutput(isTTY: true, environment: ["TERM": "dumb"]).color)
        XCTAssertFalse(CLIOutput(isTTY: true, environment: ["NO_COLOR": ""]).color)
        XCTAssertTrue(CLIOutput(isTTY: true, environment: [:]).hyperlink("https://x.com").contains("\u{1b}]8;"))
        XCTAssertEqual(CLIOutput(plain: true, isTTY: true, environment: [:]).hyperlink("https://x.com"), "https://x.com")
    }

    func testJSONContractsPreserveCursorNullAndSingleTweet() throws {
        let single = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString(example()).utf8)) as? [String: Any])
        XCTAssertEqual(single["id"] as? String, "100")
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString(TweetPage(tweets: [example()], nextCursor: nil)).utf8)) as? [String: Any])
        XCTAssertNotNil(page["tweets"] as? [[String: Any]])
        XCTAssertTrue(page["nextCursor"] is NSNull)
        let users = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString(UserPage(users: [], nextCursor: "next")).utf8)) as? [String: Any])
        XCTAssertEqual(users["nextCursor"] as? String, "next")
    }

    func testPartialRepliesAndThreadPrintResumeHintBeforeFailing() throws {
        let opts = try GlobalOptions.parse(["--plain"])
        let result = TweetListResult(success: false, tweets: [example()], nextCursor: "retry-page", error: "HTTP 429", had404: false)
        for kind in ["replies", "thread tweets"] {
            var events: [String] = []
            do {
                try printTweetResult(result, json: false, pagination: true, opts: opts, failure: "Failed to fetch \(kind)",
                    preservePartial: true, resumeKind: kind,
                    write: { _ in events.append("tweets") }, writeError: { events.append($0) })
                XCTFail("Partial failure must preserve a failing exit status")
            } catch { events.append((error as? CLIError)?.description ?? "unexpected error") }
            XCTAssertEqual(events, ["tweets", "[info] More \(kind) available. Use --cursor \"retry-page\" to continue.", "[err] Failed to fetch \(kind): HTTP 429"])
        }
        var output = ""
        XCTAssertThrowsError(try printTweetResult(result, json: true, pagination: true, opts: opts, failure: "Failed to fetch replies",
            preservePartial: true, resumeKind: "replies", write: { output = $0 }, writeError: { _ in XCTFail("JSON has its own cursor") }))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["nextCursor"] as? String, "retry-page")
    }

    func testAboutListsUsersAndNewsRetainUsefulFields() throws {
        let about = AboutProfile(accountBasedIn: "US", source: "IP", createdCountryAccurate: false, locationAccurate: true, learnMoreUrl: "https://x.com/help")
        XCTAssertEqual(plain.about(about, handle: "alice"), """
        [info] Account information for @alice:
          Account based in: US
          Creation country accurate: No
          Location accurate: Yes
        source: IP
          Learn more: https://x.com/help
        """)
        let user = TwitterUser(id: "1", username: "alice", name: "Alice", description: "Biography", followersCount: 1234)
        XCTAssertTrue(plain.users([user]).contains("Biography\n  [info] 1,234 followers"))
        let list = try JSONDecoder().decode(TwitterList.self, from: Data(#"{"id":"12345","name":"Swift","memberCount":42,"isPrivate":true,"owner":{"id":"1","username":"alice","name":"Alice"}}"#.utf8))
        XCTAssertTrue(plain.lists([list], memberships: false).contains("Swift [private]\n  [info] 42 members\n  Owner: @alice"))
        let item = try JSONDecoder().decode(NewsItem.self, from: Data(#"{"id":"n","headline":"New release","category":"Technology","postCount":1200,"timeAgo":"1 hour ago","url":"https://x.com/news"}"#.utf8))
        XCTAssertTrue(plain.news([item], tweetLimit: nil).contains("[Technology] New release\n  1 hour ago | 1.2K posts\n  url: https://x.com/news"))
    }
}

final class ParityWorkflowTests: XCTestCase {
    private func tweet(_ id: String, author: String = "alice", parent: String? = nil, conversation: String? = nil, date: String? = nil) -> TweetData {
        TweetData(id: id, text: id, author: TweetAuthor(username: author, name: author), createdAt: date,
                  conversationId: conversation, inReplyToStatusId: parent)
    }
    private func result(_ tweets: [TweetData], success: Bool = true) -> TweetListResult {
        TweetListResult(success: success, tweets: tweets, nextCursor: nil, error: success ? nil : "Unavailable", had404: false)
    }

    func testEveryBookmarkExpandsItsOwnAuthorChain() async {
        let alice = tweet("a", conversation: "a")
        let bob = tweet("b", author: "bob", conversation: "b")
        let conversations = ["a": [alice, tweet("a2", parent: "a", conversation: "a"), tweet("stranger", author: "x", parent: "a", conversation: "a")],
                             "b": [bob, tweet("b2", author: "bob", parent: "b", conversation: "b")]]
        var fetched: [String] = []
        let output = await expandBookmarks([alice, bob], options: BookmarkExpansionOptions(authorChain: true),
            fetchThread: { id in fetched.append(id); return self.result(conversations[id]!) },
            fetchTweet: { _ in XCTFail("Unexpected parent request"); return self.result([]) }, delay: {})
        XCTAssertEqual(fetched, ["a", "b"])
        XCTAssertEqual(output.map(\.tweet.id), ["a", "a2", "b", "b2"])
    }

    func testExpansionFailureRetainsBookmarkAndStillAddsParent() async {
        let bookmark = tweet("reply", parent: "root", conversation: "root")
        var warnings: [String] = []
        let output = await expandBookmarks([bookmark], options: BookmarkExpansionOptions(authorOnly: true, includeParent: true),
            fetchThread: { _ in self.result([], success: false) },
            fetchTweet: { id in self.result([self.tweet(id)]) },
            warn: { warnings.append($0) }, delay: {})
        XCTAssertEqual(output.map(\.tweet.id), ["root", "reply"])
        XCTAssertEqual(warnings, ["Failed to expand thread for reply: Unavailable"])
    }

    func testRootOnlyMetadataCacheDeduplicationAndChronologicalSort() async throws {
        let root = tweet("root", conversation: "root", date: "Tue Sep 22 13:00:00 +0000 2026")
        let child = tweet("child", parent: "root", conversation: "root", date: "Tue Sep 22 14:00:00 +0000 2026")
        var requests = 0
        let output = await expandBookmarks([child, root], options: BookmarkExpansionOptions(expandRootOnly: true, threadMeta: true, sortChronological: true),
            fetchThread: { _ in requests += 1; return self.result([root, child]) },
            fetchTweet: { _ in self.result([]) }, delay: {})
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(output.map(\.tweet.id), ["root", "child"])
        XCTAssertEqual(output[0].metadata?.threadPosition, "root")
        XCTAssertEqual(output[1].metadata?.threadPosition, "end")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString(output[0]).utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "root")
        XCTAssertEqual(json["threadRootId"] as? String, "root")
        XCTAssertEqual(json["isThread"] as? Bool, true)
        XCTAssertNil(json["tweet"])
    }

    func testEmptyParentIsRootAndDoesNotFetchEmptyParent() async {
        let root = tweet("root", parent: "", conversation: "root")
        let child = tweet("child", parent: "root", conversation: "root")
        var fetched: [String] = []
        let output = await expandBookmarks([root], options: BookmarkExpansionOptions(expandRootOnly: true, includeParent: true),
            fetchThread: { id in fetched.append(id); return self.result([root, child]) },
            fetchTweet: { _ in XCTFail("An empty parent ID must not be fetched"); return self.result([]) }, delay: {})
        XCTAssertEqual(fetched, ["root"])
        XCTAssertEqual(output.map(\.tweet.id), ["root", "child"])
    }

    func testMetadataUsesExplicitNullForUnknownConversation() async throws {
        let output = await expandBookmarks([tweet("one")], options: BookmarkExpansionOptions(threadMeta: true),
            fetchThread: { _ in self.result([self.tweet("one")]) },
            fetchTweet: { _ in self.result([]) }, delay: {})
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString(output[0]).utf8)) as? [String: Any])
        XCTAssertTrue(json["threadRootId"] is NSNull)
    }

    func testMediaLoadingValidatesAndRetainsAltText() throws {
        var paths: [String] = []
        let items = try loadMedia(paths: ["one.JPG", "two.png"], alts: ["First image", "Second image"], read: { paths.append($0); return Data($0.utf8) })
        XCTAssertEqual(paths, ["one.JPG", "two.png"])
        XCTAssertEqual(items.map(\.mimeType), ["image/jpeg", "image/png"])
        XCTAssertEqual(items.map(\.alt), ["First image", "Second image"])
        XCTAssertThrowsError(try loadMedia(paths: ["file.txt"], alts: [], read: { _ in XCTFail("Unsupported file should not be read"); return Data() }))
        XCTAssertThrowsError(try loadMedia(paths: ["one.mp4", "two.jpg"], alts: [], read: { _ in Data() }))
        XCTAssertThrowsError(try loadMedia(paths: ["one.mp4", "two.mov"], alts: [], read: { _ in Data() }))
        XCTAssertThrowsError(try loadMedia(paths: Array(repeating: "one.jpg", count: 5), alts: [], read: { _ in Data() }))
        XCTAssertEqual(try loadMedia(paths: ["clip.M4V"], alts: [], read: { _ in Data([1]) }).first?.mimeType, "video/mp4")
    }

    func testChronologicalBookmarksRespectFractionalSeconds() async {
        let later = tweet("later", date: "2026-09-22T13:00:00.900Z")
        let earlier = tweet("earlier", date: "2026-09-22T13:00:00.100Z")
        let result = await expandBookmarks([later, earlier], options: BookmarkExpansionOptions(sortChronological: true),
            fetchThread: { _ in self.result([]) }, fetchTweet: { _ in self.result([]) }, delay: {})
        XCTAssertEqual(result.map(\.tweet.id), ["earlier", "later"])
    }

    func testUserPaginationHonorsLimitAndDeduplicates() async {
        var cursors: [String?] = []
        let result = await collectUsers(cursor: "start", maxPages: 2, fetch: { cursor in
            cursors.append(cursor)
            let users = cursor == "start" ? [TwitterUser(id: "1", username: "a")] : [TwitterUser(id: "1", username: "a"), TwitterUser(id: "2", username: "b")]
            return UserListResult(success: true, users: users, nextCursor: cursor == "start" ? "second" : "third", error: nil)
        }, delay: {})
        XCTAssertEqual(cursors, ["start", "second"])
        XCTAssertEqual(result.users.map(\.id), ["1", "2"])
        XCTAssertEqual(result.nextCursor, "third")
    }

    func testFailedUploadNeverPostsTextWithoutAttachment() async {
        do {
            _ = try await uploadThenCreate(text: "hello", replyTo: nil,
                media: [MediaInput(data: Data(), mimeType: "image/png", alt: nil)],
                upload: { _ in UploadMediaResult(success: false, mediaId: nil, error: "rejected") },
                create: { _, _, _ in
                    XCTFail("Must not post after failed upload")
                    return MutationResult(success: false, userId: nil, username: nil, error: nil, tweetId: nil)
                })
            XCTFail("Expected failed upload")
        } catch { XCTAssertEqual((error as? CLIError)?.description, "Media upload failed: rejected") }
    }

    func testUserPaginationStopsWhenNoNewUsers() async {
        var requests = 0
        let result = await collectUsers(cursor: nil, maxPages: nil, fetch: { _ in
            requests += 1
            return UserListResult(success: true, users: [TwitterUser(id: "1", username: "a")], nextCursor: "cursor\(requests)", error: nil)
        }, delay: {})
        XCTAssertEqual(requests, 2)
        XCTAssertNil(result.nextCursor)
    }
}
