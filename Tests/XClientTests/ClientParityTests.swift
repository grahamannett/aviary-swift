import XCTest
import Foundation
import Cookies
@testable import XClient

actor ClientMockSession: HTTPSession {
    typealias Handler = (URLRequest, Int) throws -> (Int, String)
    private var requests: [URLRequest] = []
    private let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, body) = try handler(request, requests.count)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func recorded() -> [URLRequest] { requests }
}

final class ClientParityTests: XCTestCase {
    func client(_ session: ClientMockSession, store: QueryIdStore? = nil) -> TwitterClient { Self.makeClient(session, store: store) }

    static func makeClient(_ session: ClientMockSession, store: QueryIdStore? = nil) -> TwitterClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return TwitterClient(cookies: .init(authToken: "test", ct0: "csrf", cookieHeader: "auth_token=test; ct0=csrf"), session: session,
            queryIdStore: store ?? QueryIdStore(cachePath: root.appendingPathComponent("aviary.json").path, legacyCachePath: root.appendingPathComponent("legacy.json").path, allowRefresh: false),
            resolveUserBeforeMutation: false, sleepMilliseconds: { _ in })
    }

    func testGraphQLErrorsAreFailuresForReadsAndMutations() async {
        let session = ClientMockSession { _, _ in (200, #"{"errors":[{"message":"Not authorized","code":32}]}"#) }
        let client = client(session)
        let read = await client.getTweet("1")
        let search = await client.search("test")
        let like = await client.like("1")
        let post = await client.createTweet(text: "test")
        XCTAssertFalse(read.success)
        XCTAssertFalse(search.success)
        XCTAssertFalse(like.success)
        XCTAssertFalse(post.success)
        XCTAssertTrue(post.error?.contains("Not authorized") == true)
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 4)
    }

    func testMutationDoesNotRetryAmbiguousHTTPOrTransportFailure() async {
        for transport in [false, true] {
            let session = ClientMockSession { _, _ in
                if transport { throw URLError(.timedOut) }
                return (503, "unavailable")
            }
            let result = await client(session).createTweet(text: "one submission")
            XCTAssertFalse(result.success)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testOverflowingRetryAfterUsesBackoffAndReturnsBookmarks() async {
        actor Session: HTTPSession {
            var requestCount = 0
            var delays: [Int] = []
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                requestCount += 1
                let first = requestCount == 1
                let body = first ? "rate limited" : ClientParityTests.timeline("Bookmarks", tweets: [ClientParityTests.tweet("1")])
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: first ? 429 : 200,
                    httpVersion: nil, headerFields: first ? ["Retry-After": String(Int.max)] : nil)!)
            }
            func recordDelay(_ delay: Int) { delays.append(delay) }
            func recorded() -> (Int, [Int]) { (requestCount, delays) }
        }
        let session = Session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TwitterClient(cookies: .init(authToken: "test", ct0: "csrf"), session: session,
            queryIdStore: QueryIdStore(cachePath: root.appendingPathComponent("aviary.json").path,
                                      legacyCachePath: root.appendingPathComponent("legacy.json").path, allowRefresh: false),
            resolveUserBeforeMutation: false, sleepMilliseconds: { await session.recordDelay($0) })
        let result = await client.bookmarks()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.map(\.id), ["1"])
        let (requests, delays) = await session.recorded()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(delays, [500])
    }

    func testPostingRequiresReturnedIDAndUnretweetUsesSourceID() async throws {
        let session = ClientMockSession { _, _ in (200, #"{"data":{}}"#) }
        let client = client(session)
        let post = await client.createTweet(text: "test")
        XCTAssertFalse(post.success)
        XCTAssertEqual(post.error, "Tweet created but no ID returned")
        _ = await client.unretweet("123")
        let requests = await session.recorded()
        let body = try XCTUnwrap(JSON.parse(try XCTUnwrap(requests.last?.httpBody)))
        XCTAssertEqual(JSON.string(JSON.path(body, "variables", "source_tweet_id")), "123")
    }

    func testPostingRESTFallbackPreservesSpecialCharactersAndMedia() async throws {
        let session = ClientMockSession { request, _ in
            if request.url!.path.contains("CreateTweet") { return (200, #"{"errors":[{"code":226,"message":"blocked"}]}"#) }
            return (200, #"{"id_str":"321"}"#)
        }
        let result = await client(session).createTweet(text: "A & B + C = café", replyTo: "123", mediaIds: ["media1"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweetId, "321")
        let requests = await session.recorded()
        let body = String(data: try XCTUnwrap(requests.last?.httpBody), encoding: .utf8)!
        XCTAssertTrue(body.contains("status=A%20%26%20B%20%2B%20C%20%3D%20caf%C3%A9"))
        XCTAssertTrue(body.contains("auto_populate_reply_metadata=true"))
        XCTAssertTrue(body.contains("media_ids=media1"))
    }

    func testDirectDetailPartialErrorsAndMissingTarget() async {
        let tweet = Self.tweet("1")
        let session = ClientMockSession { _, _ in (200, jsonString(["data": ["tweetResult": ["result": tweet]], "errors": [["message": "is_translatable unavailable"]]])) }
        let result = await client(session).getTweet("1", includeRaw: true)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.first?.id, "1")
        XCTAssertNotNil(result.tweets.first?._raw)
        let other = ClientMockSession { _, _ in (200, Self.detail([Self.tweet("2")])) }
        let missing = await client(other).getTweet("1")
        XCTAssertFalse(missing.success)
        XCTAssertEqual(missing.error, "Tweet not found in response")
    }

    func testPartialUserErrorsOnlyInvalidateTheUserTweetsOperation() async {
        for message in ["User has been suspended", "User not found"] {
            let session = ClientMockSession { request, _ in
                let operation = request.url!.lastPathComponent
                let body = operation == "TweetDetail" ? Self.detail([Self.tweet("1")]) : Self.timeline(operation, tweets: [Self.tweet("1")])
                var json = JSON.parse(Data(body.utf8))!
                json["errors"] = [["message": message]]
                return (200, jsonString(json))
            }
            let client = client(session)
            let detail = await client.getTweet("1")
            XCTAssertTrue(detail.success, "A failure for another user in a detail response must not discard the requested tweet")
            let bookmarks = await client.bookmarks()
            XCTAssertTrue(bookmarks.success)
            let timeline = await client.userTweets(userId: "author")
            XCTAssertFalse(timeline.success)
            XCTAssertTrue(timeline.error?.contains(message) == true)
        }
    }

    func testUnbookmarkSkipsCurrentUserWarmupWithDefaultClientSettings() async {
        let session = ClientMockSession { request, _ in
            XCTAssertEqual(request.url!.lastPathComponent, "DeleteBookmark")
            return (200, #"{"data":{"tweet_bookmark_delete":"Done"}}"#)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TwitterClient(cookies: .init(authToken: "test", ct0: "csrf"), session: session,
            queryIdStore: QueryIdStore(cachePath: root.appendingPathComponent("aviary.json").path,
                                      legacyCachePath: root.appendingPathComponent("legacy.json").path, allowRefresh: false))
        let result = await client.unbookmark("123")
        XCTAssertTrue(result.success)
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testQueryIDRefreshUsesNewIDAndDoesNotWriteLegacyCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("legacy.json")
        let legacyText = #"{"fetchedAt":"2026-01-01T00:00:00Z","ttlMs":1,"ids":{"TweetDetail":"stale_id"},"discovery":{"pages":[],"bundles":[]}}"#
        try Data(legacyText.utf8).write(to: legacy)
        let store = QueryIdStore(cachePath: root.appendingPathComponent("aviary.json").path, legacyCachePath: legacy.path, allowRefresh: true)
        let session = ClientMockSession { request, _ in
            let url = request.url!
            if url.host == "abs.twimg.com" { return (200, #"e.exports={queryId:"fresh_id",operationName:"TweetDetail"}"#) }
            if !url.path.contains("/graphql/") { return (200, "<script src=\"https://abs.twimg.com/responsive-web/client-web/main.js\"></script>") }
            if url.path.contains("/fresh_id/") { return (200, Self.detail([Self.tweet("1")])) }
            return (404, "not found")
        }
        let result = await client(session, store: store).getTweet("1")
        XCTAssertTrue(result.success)
        let requests = await session.recorded()
        XCTAssertTrue(requests.contains { $0.httpMethod == "POST" && $0.url!.path.contains("/stale_id/") })
        XCTAssertTrue(requests.last?.url?.path.contains("/fresh_id/") == true)
        XCTAssertEqual(try String(contentsOf: legacy), legacyText)
        let id = await store.getQueryId("TweetDetail")
        XCTAssertEqual(id, "fresh_id")
    }

    func testArticleDetailFetchesMissingPlainTextWithoutRequiringAuthorInFallback() async {
        var tweet = Self.tweet("1")
        tweet["article"] = ["article_results": ["result": ["title": "Article title"]]]
        let session = ClientMockSession { request, _ in
            if request.url!.lastPathComponent == "UserArticlesTweets" {
                let article: [String: Any] = ["rest_id": "1", "article": ["article_results": ["result": ["title": "Article title", "plain_text": "Complete article body"]]]]
                return (200, Self.timeline("UserArticlesTweets", tweets: [article]))
            }
            return (200, Self.detail([tweet]))
        }
        let result = await client(session).getTweet("1")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.first?.text, "Article title\n\nComplete article body")
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 2)
    }

    func testUserLookupAndFollowerRESTFallbacks() async {
        let session = ClientMockSession { request, _ in
            if request.url!.path.hasSuffix("users/show.json") {
                return (200, #"{"id_str":"7","screen_name":"person","name":"Person"}"#)
            }
            if request.url!.path.hasSuffix("followers/list.json") {
                return (200, #"{"users":[{"id_str":"8","screen_name":"follower","followers_count":12}],"next_cursor_str":"rest-next"}"#)
            }
            if request.url!.lastPathComponent == "UserByScreenName" { return (503, "unavailable") }
            return (404, "not found")
        }
        let client = client(session)
        let lookup = await client.getUserIdByUsername("person")
        XCTAssertTrue(lookup.success)
        XCTAssertEqual(lookup.userId, "7")
        let followers = await client.followers(userId: "7")
        XCTAssertTrue(followers.success)
        XCTAssertEqual(followers.users.first?.followersCount, 12)
        XCTAssertEqual(followers.nextCursor, "rest-next")
    }

    func testUserTimelinesRejectMissingInstructionsButAcceptEmptyTimeline() async {
        for operation in ["Following", "Followers"] {
            for hasTimeline in [false, true] {
                let session = ClientMockSession { _, _ in
                    (200, hasTimeline ? Self.timeline(operation, tweets: []) : #"{"data":{"user":{"result":{"__typename":"UserUnavailable"}}}}"#)
                }
                let client = client(session)
                let result = operation == "Following"
                    ? await client.following(userId: "7")
                    : await client.followers(userId: "7")
                XCTAssertEqual(result.success, hasTimeline)
                XCTAssertTrue(result.users.isEmpty)
                XCTAssertEqual(result.error == nil, hasTimeline)
            }
        }
    }

    func testNewsParsesGroupedPostCounts() async {
        let session = ClientMockSession { _, _ in
            let item: [String: Any] = ["name": "A news headline", "social_context": ["text": "News · 12,345 posts"]]
            let instructions: [[String: Any]] = [["entries": [["content": ["itemContent": item]]]]]
            return (200, jsonString(["data": ["timeline": ["timeline": ["instructions": instructions]]]]))
        }
        let result = await client(session).news(count: 1)
        XCTAssertEqual(result.items.first?.postCount, 12_345)
    }

    func testListOwnerSupportsCoreIdentityFields() async {
        let session = ClientMockSession { request, _ in
            if request.url!.path.hasSuffix("settings.json") { return (200, #"{"user_id":"42","screen_name":"me"}"#) }
            let owner: [String: Any] = ["rest_id": "42", "core": ["screen_name": "me", "name": "My name"]]
            let list: [String: Any] = ["id_str": "list1", "name": "Friends", "user_results": ["result": owner]]
            let instructions: [[String: Any]] = [["entries": [["content": ["itemContent": ["list": list]]]]]]
            return (200, jsonString(["data": ["user": ["result": ["timeline": ["timeline": ["instructions": instructions]]]]]]))
        }
        let result = await client(session).lists()
        XCTAssertEqual(result.lists.first?.owner?.id, "42")
        XCTAssertEqual(result.lists.first?.owner?.username, "me")
        XCTAssertEqual(result.lists.first?.owner?.name, "My name")
    }

    func testSearchPaginationUsesPOSTDeduplicatesAndReturnsCursor() async throws {
        let session = ClientMockSession { request, _ in
            let vars = Self.variables(request)
            if JSON.string(vars["cursor"]) == "page2" {
                return (200, Self.timeline("SearchTimeline", tweets: [Self.tweet("2"), Self.tweet("3")], cursor: "page3"))
            }
            return (200, Self.timeline("SearchTimeline", tweets: [Self.tweet("1"), Self.tweet("2")], cursor: "page2"))
        }
        let result = await client(session).search("hello", count: 3)
        XCTAssertEqual(result.tweets.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(result.nextCursor, "page3")
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertNotNil(JSON.parse(try XCTUnwrap(requests.first?.httpBody))?["features"])
    }

    func testPaginationKeepsPartialResultsAndResumeCursorOnFailure() async {
        let session = ClientMockSession { _, index in
            index == 1 ? (200, Self.timeline("SearchTimeline", tweets: [Self.tweet("1")], cursor: "page2")) : (429, "rate limited")
        }
        let result = await client(session).search("hello", all: true)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.tweets.map(\.id), ["1"])
        XCTAssertEqual(result.nextCursor, "page2")
    }

    func testHomeSelectsForYouAndFollowingEndpoints() async {
        let session = ClientMockSession { request, _ in (200, Self.timeline(request.url!.lastPathComponent, tweets: [])) }
        let client = client(session)
        _ = await client.home()
        _ = await client.home(following: true)
        let requests = await session.recorded()
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["HomeTimeline", "HomeLatestTimeline"])
    }

    func testThreadSortsDatesChronologically() async {
        let tweets = [Self.tweet("1", date: "Thu Sep 17 10:00:00 +0000 2026"), Self.tweet("2", date: "Fri Sep 18 10:00:00 +0000 2026")]
        let session = ClientMockSession { _, _ in (200, Self.detail(tweets.reversed())) }
        let result = await client(session).getThread("1")
        XCTAssertEqual(result.tweets.map(\.id), ["1", "2"])
    }

    func testBookmarkFolderCountFallback() async {
        let session = ClientMockSession { request, _ in
            if Self.variables(request)["count"] != nil { return (400, #"{"errors":[{"message":"Variable \"$count\" is not defined"}]}"#) }
            return (200, Self.timeline("BookmarkFolderTimeline", tweets: [Self.tweet("1")]))
        }
        let result = await client(session).bookmarks(folderId: "folder")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.first?.id, "1")
        let requests = await session.recorded()
        XCTAssertEqual(Self.variables(requests[0])["bookmark_collection_id"] as? String, "folder")
        XCTAssertNil(Self.variables(requests[1])["count"])
    }

    func testOwnedListsAndNewsAreMapped() async {
        let session = ClientMockSession { request, _ in
            if request.url!.path.hasSuffix("settings.json") { return (200, #"{"user_id":"42","screen_name":"me"}"#) }
            if request.url!.path.hasSuffix("ListOwnerships") {
                let list: [String: Any] = ["id_str": "list1", "name": "Friends", "member_count": 2, "mode": "private"]
                return (200, jsonString(["data": ["user": ["result": ["timeline": ["timeline": ["instructions": [["entries": [["content": ["itemContent": ["list": list]]]]]]]]]]]]))
            }
            let news: [String: Any] = ["name": "A major scientific discovery changes medicine", "is_ai_trend": true,
                                      "social_context": ["text": "News · 2 hours ago · 1.2K posts"], "trend_url": ["url": "https://x.com/explore/1"]]
            return (200, jsonString(["data": ["timeline": ["timeline": ["instructions": [["entries": [["entryId": "trend1", "content": ["itemContent": news]]]]]]]]]))
        }
        let client = client(session)
        let lists = await client.lists()
        XCTAssertEqual(lists.lists.first?.name, "Friends")
        XCTAssertEqual(lists.lists.first?.isPrivate, true)
        let news = await client.news(count: 1, includeRaw: true, aiOnly: true)
        XCTAssertTrue(news.success)
        XCTAssertEqual(news.items.first?.postCount, 1200)
        XCTAssertEqual(news.items.first?.category, "AI · News")
        XCTAssertNotNil(news.items.first?._raw)
    }

    func testListOwnerJSONContainsOnlyIdentityFields() async throws {
        let session = ClientMockSession { request, _ in
            if request.url!.path.hasSuffix("settings.json") { return (200, #"{"user_id":"42","screen_name":"me"}"#) }
            let owner: [String: Any] = ["rest_id": "42", "is_blue_verified": true,
                "legacy": ["screen_name": "me", "name": "My name", "description": "Biography", "followers_count": 100,
                           "friends_count": 20, "profile_image_url_https": "https://example.com/avatar.jpg"]]
            let list: [String: Any] = ["id_str": "list1", "name": "Friends", "user_results": ["result": owner]]
            let instructions: [[String: Any]] = [["entries": [["content": ["itemContent": ["list": list]]]]]]
            let body: [String: Any] = ["data": ["user": ["result": ["timeline": ["timeline": ["instructions": instructions]]]]]]
            return (200, jsonString(body))
        }
        let result = await client(session).lists()
        let list = try XCTUnwrap(result.lists.first)
        let json = try XCTUnwrap(JSON.parse(JSONEncoder().encode(list)))
        let owner = try XCTUnwrap(JSON.object(json["owner"]))
        XCTAssertEqual(Set(owner.keys), Set(["id", "username", "name"]))
        XCTAssertEqual(owner["username"] as? String, "me")
    }

    static func tweet(_ id: String, date: String = "Tue Sep 22 13:27:42 +0000 2026") -> [String: Any] {
        ["rest_id": id, "legacy": ["full_text": "tweet \(id)", "created_at": date, "conversation_id_str": "1"],
         "core": ["user_results": ["result": ["rest_id": "author", "legacy": ["screen_name": "test", "name": "Test"]]]]]
    }
    static func instructions(_ tweets: [ [String: Any] ], cursor: String? = nil) -> [[String: Any]] {
        var entries = tweets.map { ["content": ["itemContent": ["tweet_results": ["result": $0]]]] as [String: Any] }
        if let cursor { entries.append(["content": ["cursorType": "Bottom", "value": cursor]]) }
        return [["type": "TimelineAddEntries", "entries": entries]]
    }
    static func detail<S: Sequence>(_ tweets: S) -> String where S.Element == [String: Any] {
        jsonString(["data": ["threaded_conversation_with_injections_v2": ["instructions": instructions(Array(tweets))]]])
    }
    static func timeline(_ operation: String, tweets: [[String: Any]], cursor: String? = nil) -> String {
        let timeline: [String: Any] = ["instructions": instructions(tweets, cursor: cursor)]
        switch operation {
        case "SearchTimeline": return jsonString(["data": ["search_by_raw_query": ["search_timeline": ["timeline": timeline]]]])
        case "HomeTimeline", "HomeLatestTimeline": return jsonString(["data": ["home": ["home_timeline_urt": timeline]]])
        case "Bookmarks": return jsonString(["data": ["bookmark_timeline_v2": ["timeline": timeline]]])
        case "BookmarkFolderTimeline": return jsonString(["data": ["bookmark_collection_timeline": ["timeline": timeline]]])
        default: return jsonString(["data": ["user": ["result": ["timeline": ["timeline": timeline]]]]])
        }
    }
    static func variables(_ request: URLRequest) -> [String: Any] {
        let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "variables" }?.value ?? "{}"
        return JSON.parse(Data(value.utf8)) ?? [:]
    }
}
