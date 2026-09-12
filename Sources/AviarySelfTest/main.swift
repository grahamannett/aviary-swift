import AviaryCLI
import Cookies
import Darwin
import Foundation
import XClient

final class MockSession: HTTPSession, @unchecked Sendable {
    var handler: (URLRequest) -> (Data, HTTPURLResponse)
    init(_ handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (d, r) = handler(request)
        return (d, r)
    }
}

var failed = 0
func expect(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL \(msg)\n", stderr)
        failed += 1
    } else {
        print("ok \(msg)")
    }
}

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

expect(hostMatchesCookieDomain(host: "x.com", cookieDomain: ".x.com"), "host match")

setenv("AUTH_TOKEN", "env_auth", 1)
setenv("CT0", "env_ct0", 1)
let cred = await resolveTwitterCredentials(
    authToken: nil, ct0: nil, cookieSource: [.safari], chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: 1
)
expect(cred.authToken == "env_auth" && cred.ct0 == "env_ct0", "env beats browsers")
unsetenv("AUTH_TOKEN")
unsetenv("CT0")

let root = tweet("1", "alice")
let reply = tweet("2", "alice", parent: "1", created: "2026-01-01T00:01:00Z")
let other = tweet("3", "bob", parent: "1", created: "2026-01-01T00:02:00Z")
let nested = tweet("5", "alice", parent: "2", created: "2026-01-01T00:04:00Z")
expect(filterAuthorChain(tweets: [root, reply, other, nested], bookmarkedTweet: reply).map(\.id) == ["1", "2", "5"], "author chain")
expect(filterAuthorOnly(tweets: [root, reply, other], bookmarkedTweet: root).map(\.id) == ["1", "2"], "author only")
let parent = tweet("root-parent", "dave", created: "2025-12-31T00:00:00Z")
let sibling = tweet("4", "carol", parent: "root-parent", created: "2026-01-01T00:03:00Z")
let rootP = tweet("1", "alice", parent: "root-parent")
let without = filterFullChain(tweets: [parent, sibling, rootP, reply, other], bookmarkedTweet: rootP)
expect(without.map(\.id).sorted() == ["1", "2", "3", "root-parent"], "full chain")
let withB = filterFullChain(tweets: [parent, sibling, rootP, reply, other], bookmarkedTweet: rootP, includeAncestorBranches: true)
expect(withB.map(\.id).contains("4"), "ancestor branches")
let meta = addThreadMetadata(tweet: root, allConversationTweets: [root, reply])
expect(meta.isThread && meta.threadPosition == "root" && meta.hasSelfReplies && meta.threadRootId == "c1", "thread metadata")

let followSession = MockSession { req in
    let json = #"{"errors":[{"code":160,"message":"already"}]}"#
    return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
}
let cookies = TwitterCookies(authToken: "a", ct0: "c", cookieHeader: "auth_token=a; ct0=c")
let client = TwitterClient(cookies: cookies, session: followSession)
let follow = await client.follow("123")
expect(follow.success, "follow code 160")

let aboutBody = """
{"data":{"user_result_by_screen_name":{"result":{"about_profile":{
  "account_based_in":"US","source":"ip","created_country_accurate":true,
  "location_accurate":false,"learn_more_url":"https://x.com/i/about"
}}}}}
"""
let aboutSession = MockSession { req in
    (Data(aboutBody.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
setenv("AVIARY_SKIP_QUERY_ID_REFRESH", "1", 1)
let aboutClient = TwitterClient(cookies: cookies, session: aboutSession)
let about = await aboutClient.getUserAboutAccount("someone")
expect(about.success && about.about?.accountBasedIn == "US" && about.about?.learnMoreUrl == "https://x.com/i/about", "about mapping")

expect(AviaryRoot.rewrittenArguments(["2098225368230732160", "--json"]).first == "read", "id shorthand")
expect(AviaryRoot.rewrittenArguments(["https://x.com/RichardMCNgo/status/2098225368230732160"]).first == "read", "url shorthand")
expect(AviaryRoot.rewrittenArguments(["thread", "1"]).first == "thread", "keep thread")

if failed > 0 {
    fputs("\(failed) failed\n", stderr)
    exit(1)
}
print("all passed")
