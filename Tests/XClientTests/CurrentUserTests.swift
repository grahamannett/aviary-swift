import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XClient

final class CurrentUserTests: XCTestCase {
    private static let apiURLs = [
        "https://x.com/i/api/account/settings.json",
        "https://api.twitter.com/1.1/account/settings.json",
        "https://x.com/i/api/account/verify_credentials.json?skip_status=true&include_entities=false",
        "https://api.twitter.com/1.1/account/verify_credentials.json?skip_status=true&include_entities=false",
    ]
    private static let pageURLs = ["https://x.com/settings/account", "https://twitter.com/settings/account"]

    func testCurrentUserAPISendsJSONContentTypeAndStopsAfterSuccess() async {
        let responses = [
            (#"{"user_id":"123","screen_name":"person","name":"Person"}"#, "Person"),
            (#"{"user":{"id_str":"123","screen_name":"person","name":"Person"}}"#, "Person"),
            (#"{"id":123,"screen_name":"person"}"#, "person"),
        ]
        for (body, expectedName) in responses {
            let session = ClientMockSession { request, _ in
                guard request.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
                    return (401, "JSON content type required")
                }
                return (200, body)
            }
            let result = await ClientParityTests.makeClient(session).getCurrentUser()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.user?.id, "123")
            XCTAssertEqual(result.user?.username, "person")
            XCTAssertEqual(result.user?.name, expectedName)
            XCTAssertNil(result.error)
            let requests = await session.recorded()
            XCTAssertEqual(requests.map { $0.url!.absoluteString }, [Self.apiURLs[0]])
            XCTAssertEqual(requests.first?.httpMethod, "GET")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "auth_token=test; ct0=csrf")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-CSRF-Token"), "csrf")
            XCTAssertTrue(requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        }
    }

    func testCurrentUserHTMLFallbackUsesBrowserHeadersInOrder() async {
        let session = ClientMockSession { request, _ in
            guard Self.pageURLs.contains(request.url!.absoluteString) else { return (401, "API unavailable") }
            guard Self.hasBrowserHeaders(request) else { return (401, "API headers rejected by settings page") }
            if request.url!.host == "x.com" { return (401, "Try the next settings page") }
            return (200, #"<script>{"screen_name":"person","user_id":"123","name":"Person \"Quoted\""}</script>"#)
        }
        let result = await ClientParityTests.makeClient(session).getCurrentUser()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.user?.id, "123")
        XCTAssertEqual(result.user?.username, "person")
        XCTAssertEqual(result.user?.name, "Person \"Quoted\"")
        XCTAssertNil(result.error)
        let requests = await session.recorded()
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, Self.apiURLs + Self.pageURLs)
        for request in requests.prefix(4) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
        for request in requests.suffix(2) {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(Self.hasBrowserHeaders(request))
        }
    }

    func testCurrentUserFailureReturnsLastSettingsPageError() async {
        let session = ClientMockSession { request, _ in
            (request.url!.absoluteString == Self.pageURLs.last ? 503 : 401, "Unavailable")
        }
        let result = await ClientParityTests.makeClient(session).getCurrentUser()
        XCTAssertFalse(result.success)
        XCTAssertNil(result.user)
        XCTAssertEqual(result.error, "HTTP 503 (settings page)")
        let requests = await session.recorded()
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, Self.apiURLs + Self.pageURLs)
    }

    private static func hasBrowserHeaders(_ request: URLRequest) -> Bool {
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        return headerNames == ["cookie", "user-agent"]
            && request.value(forHTTPHeaderField: "Cookie") == "auth_token=test; ct0=csrf"
            && request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") == true
    }
}
