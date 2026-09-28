import Foundation
import XCTest
@testable import XClient

final class JSONParityTests: XCTestCase {
    private func fixtures() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bird-0.8-tweets", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSON.parse(Data(contentsOf: url)))
    }

    func testTweetMappingMatchesBirdOracle() throws {
        for fixture in try XCTUnwrap(JSON.array(fixtures()["mapping"])).compactMap(JSON.object) {
            let name = fixture["name"] as? String ?? "fixture"
            let input = try XCTUnwrap(JSON.object(fixture["input"]))
            let actual = JSON.mapTweet(input, quoteDepth: fixture["quoteDepth"] as? Int ?? 1, includeRaw: fixture["includeRaw"] as? Bool ?? false)
            if fixture["expected"] is NSNull {
                XCTAssertNil(actual, name)
            } else {
                let encoded = try JSONEncoder().encode(XCTUnwrap(actual))
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
                XCTAssertEqual(value, JSON.foundationValue(try XCTUnwrap(fixture["expected"])) as? NSDictionary, name)
                let decoded = try JSONDecoder().decode(TweetData.self, from: encoded)
                let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
                XCTAssertEqual(roundTrip, value, "Codable round-trip: \(name)")
            }
        }
    }

    func testRichArticlesMatchBirdOracle() throws {
        for fixture in try XCTUnwrap(JSON.array(fixtures()["rich"])).compactMap(JSON.object) {
            XCTAssertEqual(JSON.renderContentState(JSON.object(fixture["input"])), fixture["expected"] as? String)
        }
    }

    func testTimelineUnwrapsVisibilityResultsAndDeduplicates() {
        let tweet: [String: Any] = ["rest_id": "1", "core": ["user_results": ["result": ["legacy": ["screen_name": "alice"]]]], "legacy": ["full_text": "Hello"]]
        let item: [String: Any] = ["itemContent": ["tweet_results": ["result": ["tweet": tweet]]]]
        let instructions: [[String: Any]] = [["entries": [["content": item], ["content": ["items": [["item": item]]]]]]]
        XCTAssertEqual(JSON.walkTweets(instructions, quoteDepth: 1, includeRaw: false).map(\.id), ["1"])
    }

    func testCursorPrefersBottomOverEarlierShowMore() {
        let instructions = [["entries": [
            ["content": ["cursorType": "ShowMore", "value": "show"]],
            ["content": ["cursorType": "Bottom", "value": "bottom"]],
        ]]]
        XCTAssertEqual(JSON.cursor(instructions), "bottom")
    }

    func testInvalidArticleRangesCannotCrash() {
        let content: [String: Any] = ["blocks": [["text": "hello", "entityRanges": [["key": 0, "offset": Int.max, "length": 10]]]],
                                    "entityMap": ["0": ["type": "LINK", "data": ["url": "https://example.invalid"]]]]
        XCTAssertEqual(JSON.renderContentState(content), "hello")
    }

    func testParsingPreservesValuesAndRawJSONWithoutInternalMetadata() throws {
        let source = #"{"escaped\"key":{"a":[true,false,null,1,-2,1.25,"a\\b",{"unicode":"🎉"}]},"empty":{},"array":[]}"#
        let data = Data(source.utf8)
        let parsed = try XCTUnwrap(JSON.parse(data))
        let normalized = JSON.foundationValue(parsed)
        XCTAssertEqual(normalized as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: normalized))
        XCTAssertNil(JSON.parse(Data("{broken".utf8)))
        XCTAssertNil(JSON.parse(Data("[]".utf8)))
    }

    func testHandleNormalizationMatchesBird() {
        XCTAssertEqual(normalizeHandle(" @ alice_1 "), "alice_1")
        XCTAssertNil(normalizeHandle("https://x.com/alice"))
        XCTAssertNil(normalizeHandle("alice bob"))
        XCTAssertNil(normalizeHandle("abcdefghijklmnop"))
        XCTAssertNil(normalizeHandle("@"))
    }

    func testDuplicateKeysCannotDiscardFollowingFields() throws {
        for source in [
            #"{"same":{"text":"first"},"same":"last","tail":"keep"}"#,
            #"{"same":"first","same":{"text":"last"},"tail":"keep"}"#,
            #"{"same":[1,2],"same":true,"tail":"keep"}"#,
            #"{"same":[{"old":1}],"same":[{"new":2}],"tail":"keep"}"#,
        ] {
            let data = Data(source.utf8)
            let parsed = try XCTUnwrap(JSON.parse(data))
            XCTAssertEqual(JSON.foundationValue(parsed) as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
    }
}
