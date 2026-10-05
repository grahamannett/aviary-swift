import Foundation
import XCTest
@testable import XClient

final class TimelineTraversalTests: XCTestCase {
    private func searchPages() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "timeline-instruction-shapes", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSON.parse(Data(contentsOf: url)))
        return try XCTUnwrap(JSON.array(fixture["searchPages"])).compactMap(JSON.object)
    }

    private func searchInstructions(_ page: [String: Any]) -> Any? {
        JSON.path(page, "data", "search_by_raw_query", "search_timeline", "timeline", "instructions")
    }

    func testSearchPaginatesPinnedEntriesReplacementsAndModuleAdditions() async throws {
        let pages = try searchPages().map { jsonString($0) }
        let session = ClientMockSession { _, index in
            (200, pages[min(index - 1, pages.count - 1)])
        }
        let result = await ClientParityTests.makeClient(session).search("fixture", count: 5, includeRaw: true, maxPages: 2)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.map(\.id), ["101", "102", "103", "104", "105"])
        XCTAssertEqual(result.tweets.map(\.text), ["Pinned tweet", "Ordinary tweet", "Module tweet", "Added module tweet", "Nested module tweet"])
        XCTAssertEqual(result.nextCursor, "page-three")
        let added = try XCTUnwrap(result.tweets.first { $0.id == "104" })
        XCTAssertEqual(added.quotedTweet?.id, "900")
        XCTAssertNotNil(added._raw)
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(ClientParityTests.variables(try XCTUnwrap(requests.last))["cursor"] as? String, "page-two")
    }

    func testTimelineCursorsKeepTypePreferenceAndFirstValueAcrossShapes() throws {
        let pages = try searchPages()
        let first = searchInstructions(pages[0])
        XCTAssertEqual(JSON.cursor(first), "page-two")
        XCTAssertEqual(JSON.cursor(first, preferredTypes: ["ShowMore", "Bottom"]), "show-first")
        XCTAssertEqual(JSON.cursor(first, preferredTypes: ["Top"]), "top")
        XCTAssertEqual(JSON.cursor(searchInstructions(pages[1])), "page-three")
    }

    func testRepliesContinuePastFilteredEmptyPageWithReplacementCursor() async {
        let first: [[String: Any]] = [
            ["type": "TimelinePinEntry", "entry": ["content": ["itemContent": ["tweet_results": ["result": ClientParityTests.tweet("1")]]]]],
            ["type": "TimelineReplaceEntry", "entry": ["content": ["cursorType": "Bottom", "value": "replies-next"]]],
        ]
        var reply = ClientParityTests.tweet("2")
        var legacy = reply["legacy"] as! [String: Any]
        legacy["in_reply_to_status_id_str"] = "1"
        reply["legacy"] = legacy
        let second: [[String: Any]] = [["type": "TimelineAddToModule", "moduleEntryId": "conversation-1", "moduleItems": [
            ["item": ["itemContent": ["tweet_results": ["result": reply]]]],
            ["item": ["itemContent": ["tweet_results": ["result": ClientParityTests.tweet("3")]]]],
        ]]]
        let session = ClientMockSession { _, index in
            (200, jsonString(["data": ["threaded_conversation_with_injections_v2": ["instructions": index == 1 ? first : second]]]))
        }
        let result = await ClientParityTests.makeClient(session).getRepliesPaged("1", includeRaw: false, maxPages: 2, cursor: nil, pageDelayMs: 0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tweets.map(\.id), ["2"])
        XCTAssertNil(result.nextCursor)
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last.flatMap { ClientParityTests.variables($0)["cursor"] as? String }, "replies-next")
    }

    func testSearchStillStopsOnEmptyOrDuplicateOnlyModulePages() async {
        for duplicate in [false, true] {
            let moduleItems: [[String: Any]] = duplicate ? [["item": ["itemContent": ["tweet_results": ["result": ClientParityTests.tweet("1")]]]]] : []
            let instructions: [[String: Any]] = [
                ["type": "TimelineAddToModule", "moduleEntryId": "conversation-1", "moduleItems": moduleItems],
                ["type": "TimelineReplaceEntry", "entry": ["content": ["cursorType": "Bottom", "value": "unused-next"]]],
            ]
            let session = ClientMockSession { _, index in
                if index == 1 { return (200, ClientParityTests.timeline("SearchTimeline", tweets: [ClientParityTests.tweet("1")], cursor: "page-two")) }
                return (200, jsonString(["data": ["search_by_raw_query": ["search_timeline": ["timeline": ["instructions": instructions]]]]]))
            }
            let result = await ClientParityTests.makeClient(session).search("fixture", all: true, maxPages: 3)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.tweets.map(\.id), ["1"])
            XCTAssertNil(result.nextCursor)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testFollowersMapModuleUsersAndNestedContinuationCursor() async {
        let user: [String: Any] = ["rest_id": "7", "legacy": ["screen_name": "fixture", "name": "Fixture", "followers_count": 42]]
        let instructions: [[String: Any]] = [
            ["type": "TimelineAddToModule", "moduleEntryId": "users-1", "moduleItems": [
                ["item": ["itemContent": ["user_results": ["result": user]]]],
                ["itemContent": ["cursorType": "Bottom", "value": "users-next"]],
            ]],
            ["type": "TimelinePinEntry", "entry": ["content": ["itemContent": ["user_results": ["result": user]]]]],
        ]
        let session = ClientMockSession { _, _ in
            (200, jsonString(["data": ["user": ["result": ["timeline": ["timeline": ["instructions": instructions]]]]]]))
        }
        let result = await ClientParityTests.makeClient(session).followers(userId: "1")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.users.map(\.id), ["7"])
        XCTAssertEqual(result.users.first?.followersCount, 42)
        XCTAssertEqual(result.nextCursor, "users-next")
    }

    func testNewsRetainsParentEntryIdentityAndCountAcrossModuleShapes() async {
        let instructions: [[String: Any]] = [
            ["type": "TimelineAddEntries", "entries": [["entryId": "trends-parent", "content": ["items": [
                ["entryId": "nested-id", "item": ["itemContent": ["name": "First headline"]]],
            ]]]]],
            ["type": "TimelineAddToModule", "moduleEntryId": "trends-parent", "moduleItems": [
                ["item": ["itemContent": ["name": "Second headline"]]],
                ["item": ["itemContent": ["name": "Beyond count"]]],
            ]],
        ]
        let session = ClientMockSession { _, _ in
            (200, jsonString(["data": ["timeline": ["timeline": ["instructions": instructions]]]]))
        }
        let result = await ClientParityTests.makeClient(session).news(count: 2, tabs: ["news"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.items.map(\.id), ["trends-parent-First headline", "trends-parent-Second headline"])
    }
}
