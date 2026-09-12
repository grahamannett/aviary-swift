import ArgumentParser
import Foundation
import XClient

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check credential availability")
    @OptionGroup var opts: GlobalOptions
    func run() async throws {
        let cookies = await opts.credentials()
        print("\(opts.p("info"))Credential check")
        print(String(repeating: "─", count: 40))
        if let a = cookies.authToken {
            print("\(opts.p("ok"))auth_token: \(a.prefix(10))...")
        } else {
            print("\(opts.p("err"))auth_token: not found")
        }
        if let c = cookies.ct0 {
            print("\(opts.p("ok"))ct0: \(c.prefix(10))...")
        } else {
            print("\(opts.p("err"))ct0: not found")
        }
        if let s = cookies.source { print("source \(s)") }
        if !cookies.warnings.isEmpty {
            print("\n\(opts.p("warn"))Warnings:")
            for w in cookies.warnings { print("   - \(w)") }
        }
        if cookies.authToken != nil, cookies.ct0 != nil {
            print("\n\(opts.p("ok"))Ready to tweet!")
        } else {
            print("\n\(opts.p("err"))Missing credentials. Options:")
            print("   1. Login to x.com in Safari/Chrome/Firefox")
            print("   2. For Safari EPERM: grant Full Disk Access to Terminal (System Settings → Privacy & Security)")
            print("   3. For Chrome: try --chrome-profile \"Profile 3\" (or another non-Default profile)")
            print("   4. Set AUTH_TOKEN and CT0 environment variables")
            print("   5. Use --auth-token and --ct0 flags")
            throw ExitCode(1)
        }
    }
}

struct Whoami: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the logged-in account")
    @OptionGroup var opts: GlobalOptions
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        if let s = cookies.source { print("\(opts.p("info"))\(s)") }
        let client = opts.makeClient(cookies)
        let r = await client.getCurrentUser()
        if r.success, let u = r.user {
            print("🙋 @\(u.username)\(u.name.map { " (\($0))" } ?? "")")
            if !u.id.isEmpty { print("🪪 \(u.id)") }
            print("⚙️ graphql")
            if let s = cookies.source { print("🔑 \(s)") }
        } else {
            fputs("\(opts.p("err"))\(r.error ?? "failed")\n", stderr)
            throw ExitCode(1)
        }
    }
}

struct QueryIds: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query-ids", abstract: "Show GraphQL query IDs")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    @Flag(name: .long) var fresh: Bool = false
    func run() async throws {
        if fresh {
            await QueryIdStore.shared.refresh(force: true, session: URLSessionHTTP())
        }
        let ids = await QueryIdStore.shared.queryIdsForCLI()
        if json {
            struct Out: Codable { var ids: [String: String] }
            printJSON(Out(ids: ids))
        } else {
            for k in ids.keys.sorted() { print("\(k): \(ids[k] ?? "")") }
        }
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read/fetch a tweet by ID or URL")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let id = extractTweetId(tweetIdOrUrl)
        let r = await client.getTweet(id, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "Failed to read tweet", opts: opts, success: r.success, error: r.error)
    }
}

struct Replies: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List replies to a tweet (by ID or URL)")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let id = extractTweetId(tweetIdOrUrl)
        let r: TweetListResult
        if page.usePagination {
            r = await client.getRepliesPaged(id, includeRaw: json.includeRaw, maxPages: page.all ? nil : page.maxPages, cursor: page.cursor, pageDelayMs: page.delay)
        } else {
            r = await client.getReplies(id, includeRaw: json.includeRaw)
        }
        try printTweets(r.tweets, json: json.asJson, empty: "No replies found.", opts: opts, success: r.success, error: r.error)
        if let c = r.nextCursor, !json.asJson {
            fputs("\(opts.p("info"))More replies available. Use --cursor \"\(c)\" to continue.\n", stderr)
        }
    }
}

struct Thread: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the full conversation thread containing the tweet")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let id = extractTweetId(tweetIdOrUrl)
        let r: TweetListResult
        if page.usePagination {
            r = await client.getThreadPaged(id, includeRaw: json.includeRaw, maxPages: page.all ? nil : page.maxPages, cursor: page.cursor, pageDelayMs: page.delay)
        } else {
            r = await client.getThread(id, includeRaw: json.includeRaw)
        }
        try printTweets(r.tweets, json: json.asJson, empty: "No thread tweets found.", opts: opts, success: r.success, error: r.error)
        if let c = r.nextCursor, !json.asJson {
            fputs("\(opts.p("info"))More thread tweets available. Use --cursor \"\(c)\" to continue.\n", stderr)
        }
    }
}

struct Tweet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Post a tweet")
    @OptionGroup var opts: GlobalOptions
    @Argument var text: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).createTweet(text: text)
        if r.success { print("\(opts.p("ok"))Tweeted \(r.tweetId ?? "")") }
        else { fputs("\(opts.p("err"))\(r.error ?? "failed")\n", stderr); throw ExitCode(1) }
    }
}

struct Reply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reply to a tweet")
    @OptionGroup var opts: GlobalOptions
    @Argument var tweetIdOrUrl: String
    @Argument var text: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).createTweet(text: text, replyTo: extractTweetId(tweetIdOrUrl))
        if r.success { print("\(opts.p("ok"))Replied") }
        else { fputs("\(opts.p("err"))\(r.error ?? "failed")\n", stderr); throw ExitCode(1) }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search tweets")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var query: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).search(query, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No results.", opts: opts, success: r.success, error: r.error)
    }
}

struct Mentions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search mentions of a user")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var username: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let q = "@\(normalizeHandle(username) ?? username)"
        let r = await opts.makeClient(cookies).search(q, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No mentions.", opts: opts, success: r.success, error: r.error)
    }
}

struct Home: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Home timeline")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).home(includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No tweets.", opts: opts, success: r.success, error: r.error)
    }
}

struct UserTweets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "user-tweets", abstract: "Tweets from a user")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var username: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let lookup = await client.getUserIdByUsername(username)
        guard lookup.success, let id = lookup.userId else {
            fputs("\(opts.p("err"))\(lookup.error ?? "user not found")\n", stderr)
            throw ExitCode(1)
        }
        let r = await client.userTweets(userId: id, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No tweets.", opts: opts, success: r.success, error: r.error)
    }
}

struct Bookmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List bookmarks")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Flag(name: .customLong("author-chain")) var authorChain: Bool = false
    @Flag(name: .customLong("author-only")) var authorOnly: Bool = false
    @Flag(name: .customLong("full-chain")) var fullChain: Bool = false
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        var r = await opts.makeClient(cookies).bookmarks(includeRaw: json.includeRaw)
        if let first = r.tweets.first {
            if authorChain { r.tweets = filterAuthorChain(tweets: r.tweets, bookmarkedTweet: first) }
            else if authorOnly { r.tweets = filterAuthorOnly(tweets: r.tweets, bookmarkedTweet: first) }
            else if fullChain { r.tweets = filterFullChain(tweets: r.tweets, bookmarkedTweet: first) }
        }
        try printTweets(r.tweets, json: json.asJson, empty: "No bookmarks.", opts: opts, success: r.success, error: r.error)
    }
}

struct Unbookmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a bookmark")
    @OptionGroup var opts: GlobalOptions
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).unbookmark(extractTweetId(tweetIdOrUrl))
        if r.success { print("\(opts.p("ok"))Unbookmarked") }
        else { fputs("\(opts.p("err"))\(r.error ?? "failed")\n", stderr); throw ExitCode(1) }
    }
}

struct Likes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Liked tweets")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var username: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let lookup = await client.getUserIdByUsername(username)
        guard lookup.success, let id = lookup.userId else { throw ExitCode(1) }
        let r = await client.likes(userId: id, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No likes.", opts: opts, success: r.success, error: r.error)
    }
}

struct News: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Trending topics")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let items = await opts.makeClient(cookies).news()
        if json {
            printJSON(items)
        } else {
            for t in items { print(t["name"] ?? "") }
        }
    }
}

struct Trending: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Alias for news")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    func run() async throws {
        var n = News(); n.opts = opts; n.json = json
        try await n.run()
    }
}

struct Lists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Twitter lists")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).lists()
        if json { printJSON(r.users) } else { r.users.forEach { print("@\($0.username)") } }
    }
}

struct ListTimeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-timeline", abstract: "Tweets from a list")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var listId: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).listTimeline(listId, includeRaw: json.includeRaw)
        try printTweets(r.tweets, json: json.asJson, empty: "No tweets.", opts: opts, success: r.success, error: r.error)
    }
}

struct Following: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Accounts a user follows")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    @Argument var username: String
    func run() async throws {
        try await printUsers(username, opts: opts, json: json, kind: "following")
    }
}

struct Followers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Followers of a user")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    @Argument var username: String
    func run() async throws {
        try await printUsers(username, opts: opts, json: json, kind: "followers")
    }
}

struct Follow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Follow a user")
    @OptionGroup var opts: GlobalOptions
    @Argument var usernameOrId: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let id = try await resolveUser(client, usernameOrId, opts: opts)
        let r = await client.follow(id)
        if r.success { print("\(opts.p("ok"))Now following \(r.username.map { "@\($0)" } ?? id)") }
        else { fputs("\(opts.p("err"))Failed to follow: \(r.error ?? "")\n", stderr); throw ExitCode(1) }
    }
}

struct Unfollow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unfollow a user")
    @OptionGroup var opts: GlobalOptions
    @Argument var usernameOrId: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let client = opts.makeClient(cookies)
        let id = try await resolveUser(client, usernameOrId, opts: opts)
        let r = await client.unfollow(id)
        if r.success { print("\(opts.p("ok"))Unfollowed") }
        else { fputs("\(opts.p("err"))Failed to unfollow: \(r.error ?? "")\n", stderr); throw ExitCode(1) }
    }
}

struct About: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "About-account metadata for a user")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long) var json: Bool = false
    @Argument var username: String
    func run() async throws {
        let cookies = try await opts.require(await opts.credentials())
        let r = await opts.makeClient(cookies).getUserAboutAccount(username)
        if r.success, let a = r.about {
            if json { printJSON(a) }
            else {
                print("accountBasedIn: \(a.accountBasedIn ?? "")")
                print("source: \(a.source ?? "")")
            }
        } else {
            fputs("\(opts.p("err"))\(r.error ?? "failed")\n", stderr)
            throw ExitCode(1)
        }
    }
}

struct HelpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "help", abstract: "Show help")
    @Argument var command: String?
    func run() async throws {
        let map: [String: ParsableCommand.Type] = [
            "read": Read.self,
            "replies": Replies.self,
            "thread": Thread.self,
            "tweet": Tweet.self,
            "whoami": Whoami.self,
            "check": Check.self,
            "follow": Follow.self,
            "about": About.self,
        ]
        if let command, let t = map[command] {
            print(t.helpMessage())
        } else {
            print(AviaryRoot.helpMessage())
        }
    }
}

func printTweets(_ tweets: [TweetData], json: Bool, empty: String, opts: GlobalOptions, success: Bool, error: String?) throws {
    if json {
        printJSON(tweets)
    } else if tweets.isEmpty {
        print(empty)
    } else {
        for t in tweets {
            print("@\(t.author.username): \(t.text)")
            print("---")
        }
    }
    if !success {
        fputs("\(opts.p("err"))\(error ?? "failed")\n", stderr)
        throw ExitCode(1)
    }
}

func printUsers(_ username: String, opts: GlobalOptions, json: Bool, kind: String) async throws {
    let cookies = try await opts.require(await opts.credentials())
    let client = opts.makeClient(cookies)
    let lookup = await client.getUserIdByUsername(username)
    guard lookup.success, let id = lookup.userId else { throw ExitCode(1) }
    let r = kind == "following" ? await client.following(userId: id) : await client.followers(userId: id)
    if json { printJSON(r.users) }
    else { r.users.forEach { print("@\($0.username) \($0.name ?? "")") } }
    if !r.success { throw ExitCode(1) }
}

func resolveUser(_ client: TwitterClient, _ usernameOrId: String, opts: GlobalOptions) async throws -> String {
    let raw = usernameOrId.trimmingCharacters(in: .whitespaces)
    let isNumeric = raw.range(of: #"^\d+$"#, options: .regularExpression) != nil
    if let handle = normalizeHandle(raw) {
        let lookup = await client.getUserIdByUsername(handle)
        if lookup.success, let id = lookup.userId { return id }
        if !isNumeric {
            fputs("\(opts.p("err"))Failed to find user @\(handle): \(lookup.error ?? "")\n", stderr)
            throw ExitCode(1)
        }
    }
    if isNumeric { return raw }
    throw ExitCode(1)
}
