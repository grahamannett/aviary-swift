import Darwin
import Testing
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

@Suite struct FollowAboutTests {
    @Test func followCode160() async {
        let session = MockSession { req in
            let json = #"{"errors":[{"code":160,"message":"already"}]}"#
            let url = req.url ?? URL(string: "https://x.com")!
            return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let cookies = TwitterCookies(authToken: "a", ct0: "c", cookieHeader: "auth_token=a; ct0=c")
        let client = TwitterClient(cookies: cookies, session: session)
        let r = await client.follow("123")
        #expect(r.success)
    }

    @Test func aboutMapping() async {
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
        let cookies = TwitterCookies(authToken: "a", ct0: "c", cookieHeader: "auth_token=a; ct0=c")
        let client = TwitterClient(cookies: cookies, session: session)
        setenv("AVIARY_SKIP_QUERY_ID_REFRESH", "1", 1)
        let r = await client.getUserAboutAccount("someone")
        #expect(r.success)
        #expect(r.about?.accountBasedIn == "US")
        #expect(r.about?.learnMoreUrl == "https://x.com/i/about")
    }
}
