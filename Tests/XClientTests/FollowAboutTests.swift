import XCTest
import Cookies
import XClient
import Foundation

final class MockSession: HTTPSession, @unchecked Sendable {
    var handler: (URLRequest) -> (Data, HTTPURLResponse)
    init(_ handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (d, r) = handler(request)
        return (d, r)
    }
}

final class FollowAboutTests: XCTestCase {
    private func client(session: MockSession) -> TwitterClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-follow-tests-\(UUID().uuidString)")
        let store = QueryIdStore(
            cachePath: directory.appendingPathComponent("queries.json").path,
            legacyCachePath: directory.appendingPathComponent("legacy.json").path,
            allowRefresh: false
        )
        return TwitterClient(cookies: TwitterCookies(authToken: "a", ct0: "c", cookieHeader: "auth_token=a; ct0=c"),
                             session: session, queryIdStore: store)
    }

    func testFollowCode160() async {
        let session = MockSession { req in
            let json = #"{"errors":[{"code":160,"message":"already"}]}"#
            let url = req.url ?? URL(string: "https://x.com")!
            return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let client = client(session: session)
        let r = await client.follow("123")
        XCTAssertTrue(r.success)
    }

    func testFriendshipFailuresDoNotRetryMutation() async {
        let responses = [
            (429, #"{"errors":[{"message":"Rate limited"}]}"#),
            (503, "unavailable"),
            (200, "invalid JSON"),
            (200, "{}"),
            (200, #"{"errors":[{"message":"Rejected","code":32}]}"#),
            (404, #"{"errors":[{"message":"User not found","code":108}]}"#),
        ]
        for follow in [false, true] {
            for response in responses {
                let session = ClientMockSession { _, _ in response }
                let client = ClientParityTests.makeClient(session)
                let result = follow ? await client.follow("123") : await client.unfollow("123")
                XCTAssertFalse(result.success)
                XCTAssertNotNil(result.error)
                let requests = await session.recorded()
                XCTAssertEqual(requests.count, 1)
            }
            let session = ClientMockSession { _, _ in throw URLError(.timedOut) }
            let client = ClientParityTests.makeClient(session)
            let result = follow ? await client.follow("123") : await client.unfollow("123")
            XCTAssertFalse(result.success)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testFriendshipFallbackRequiresMissingEndpoint() async {
        for follow in [false, true] {
            for missingEndpoints in [1, 2] {
                let session = ClientMockSession { request, index in
                    if index <= missingEndpoints { return (404, "not found") }
                    if request.url!.path.contains("/graphql/") {
                        return (200, #"{"data":{"user":{"result":{"rest_id":"123","legacy":{"screen_name":"person","name":"Person"}}}}}"#)
                    }
                    return (200, #"{"id_str":"123","screen_name":"person"}"#)
                }
                let client = ClientParityTests.makeClient(session)
                let result = follow ? await client.follow("123") : await client.unfollow("123")
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.userId, "123")
                XCTAssertEqual(result.username, "person")
                let requests = await session.recorded()
                XCTAssertEqual(requests.count, missingEndpoints + 1)
                XCTAssertEqual(requests.last?.url?.host, missingEndpoints == 1 ? "api.twitter.com" : "x.com")
            }
        }
    }

    func testAboutMapping() async {
        let body = """
        {"data":{"user_result_by_screen_name":{"result":{"about_profile":{
          "account_based_in":"US","source":"ip","created_country_accurate":true,
          "location_accurate":false,"learn_more_url":"https://x.com/i/about"
        }}}}}
        """
        let session = MockSession { req in
            let url = req.url ?? URL(string: "https://x.com")!
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = client(session: session)
        let r = await client.getUserAboutAccount("someone")
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.about?.accountBasedIn == "US")
        XCTAssertTrue(r.about?.learnMoreUrl == "https://x.com/i/about")
    }
}
