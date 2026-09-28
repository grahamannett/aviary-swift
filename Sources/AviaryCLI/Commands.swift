import ArgumentParser
import Foundation
import XClient

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check credential availability")
    @OptionGroup var opts: GlobalOptions
    func run() async throws {
        let cookies = try await opts.credentials()
        print("\(opts.p("info"))Credential check")
        print(String(repeating: "─", count: 40))
        for (name, value) in [("auth_token", cookies.authToken), ("ct0", cookies.ct0)] {
            if let value, !value.isEmpty { print("\(opts.p("ok"))\(name): \(value.prefix(10))...") }
            else { print("\(opts.p("err"))\(name): not found") }
        }
        if let source = cookies.source { print(opts.l("source") + source) }
        if !cookies.warnings.isEmpty {
            print("\n\(opts.p("warn"))Warnings:")
            for warning in cookies.warnings { print("   - \(warning)") }
        }
        if !(cookies.authToken ?? "").isEmpty && !(cookies.ct0 ?? "").isEmpty { print("\n\(opts.p("ok"))Ready to tweet!") }
        else {
            print("\n\(opts.p("err"))Missing credentials. Options:")
            print("   1. Login to x.com in Safari/Chrome/Firefox")
            print("   2. Set AUTH_TOKEN and CT0 environment variables")
            print("   3. Use --auth-token and --ct0 flags")
            throw ExitCode(1)
        }
    }
}

struct Whoami: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which Twitter account the current credentials belong to")
    @OptionGroup var opts: GlobalOptions
    func run() async throws {
        let cookies = try opts.require(try await opts.credentials())
        if let source = cookies.source { stderrLine(opts.l("source") + source) }
        let result = await opts.makeClient(cookies).getCurrentUser()
        guard result.success, let user = result.user else {
            throw CLIError("\(opts.p("err"))Failed to determine current user: \(result.error ?? "Unknown error")")
        }
        print("\(opts.l("user"))@\(user.username) (\(user.name ?? ""))")
        print(opts.l("userId") + user.id)
        print(opts.l("engine") + "graphql")
        print(opts.l("credentials") + (cookies.source ?? "env/auto-detected cookies"))
    }
}

struct QueryIds: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query-ids", abstract: "Show or refresh cached Twitter GraphQL query IDs")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .long, help: "Force refresh (downloads X client bundles)") var fresh = false
    func run() async throws {
        if fresh {
            stderrLine("\(opts.p("info"))Refreshing GraphQL query IDs…")
            stderrLine("\(opts.p("info"))Refreshing feature overrides…")
            await QueryIdStore.shared.refreshCLI()
        }
        let status = await QueryIdStore.shared.cliStatus()
        if json { try printJSON(status); return }
        guard case .object(let fields) = status.value else { throw CLIError("Invalid query cache status") }
        func text(_ key: String) -> String {
            guard let value = fields[key] else { return "" }
            switch value { case .string(let s): return s; case .bool(let b): return b ? "yes" : "no"; default: return "" }
        }
        if case .bool(true) = fields["cached"] {
            print("\(opts.p("ok"))GraphQL query IDs cached")
            print("path: \(text("cachePath"))")
            print("fetched_at: \(text("fetchedAt"))")
            print("fresh: \(text("isFresh"))")
            if case .object(let ids) = fields["ids"] { print("ops: \(ids.count)") }
            print("features_path: \(text("featuresPath"))")
            var count = 0
            if case .object(let features) = fields["features"] {
                if case .object(let global) = features["global"] { count += global.count }
                if case .object(let sets) = features["sets"] {
                    for value in sets.values { if case .object(let overrides) = value { count += overrides.count } }
                }
            }
            print("features: \(count)")
        } else {
            print("\(opts.p("warn"))No cached query IDs yet.")
            print("\(opts.p("info"))Run: aviary query-ids --fresh")
            print("features_path: \(text("featuresPath"))")
        }
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read/fetch a tweet by ID or URL")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let client = try await opts.authenticatedClient()
        let result = await client.getTweet(extractTweetId(tweetIdOrUrl), includeRaw: json.includeRaw)
        guard result.success, let tweet = result.tweets.first else {
            throw CLIError("\(opts.p("err"))Failed to read tweet: \(result.error ?? "Unknown error")")
        }
        if json.asJson { try printJSON(tweet) }
        else {
            print(opts.output.tweets([tweet], separator: false))
            print(opts.output.stats(tweet))
        }
    }
}

struct Replies: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List replies to a tweet (by ID or URL)")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: .long, parsing: .unconditional, help: "Delay in ms between page fetches") var delay = "1000"
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let pagination = try page.resolved(maxPagesImpliesPagination: true)
        let milliseconds = try nonNegativeInt(delay, flag: "--delay")
        let client = try await opts.authenticatedClient()
        let id = extractTweetId(tweetIdOrUrl)
        let result = pagination.use
            ? await client.getRepliesPaged(id, includeRaw: json.includeRaw, maxPages: pagination.maxPages, cursor: pagination.cursor, pageDelayMs: milliseconds)
            : await client.getReplies(id, includeRaw: json.includeRaw)
        try printTweetResult(result, json: json.asJson, pagination: pagination.use, empty: "No replies found.", opts: opts,
                             failure: "Failed to fetch replies", preservePartial: true, resumeKind: "replies")
    }
}

struct Thread: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the full conversation thread containing the tweet")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: .long, parsing: .unconditional, help: "Delay in ms between page fetches") var delay = "1000"
    @Argument var tweetIdOrUrl: String
    func run() async throws {
        let pagination = try page.resolved(maxPagesImpliesPagination: true)
        let milliseconds = try nonNegativeInt(delay, flag: "--delay")
        let client = try await opts.authenticatedClient()
        let id = extractTweetId(tweetIdOrUrl)
        let result = pagination.use
            ? await client.getThreadPaged(id, includeRaw: json.includeRaw, maxPages: pagination.maxPages, cursor: pagination.cursor, pageDelayMs: milliseconds)
            : await client.getThread(id, includeRaw: json.includeRaw)
        try printTweetResult(result, json: json.asJson, pagination: pagination.use, empty: "No thread tweets found.", opts: opts,
                             failure: "Failed to fetch thread", preservePartial: true, resumeKind: "thread tweets")
    }
}

struct Tweet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Post a new tweet")
    @OptionGroup var opts: GlobalOptions
    @Argument var text: String
    func run() async throws { try await post(text: text, replyTo: nil, opts: opts) }
}

struct Reply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reply to an existing tweet")
    @OptionGroup var opts: GlobalOptions
    @Argument var tweetIdOrUrl: String
    @Argument var text: String
    func run() async throws { try await post(text: text, replyTo: extractTweetId(tweetIdOrUrl), opts: opts) }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search for tweets")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of tweets to fetch") var count = "10"
    @Argument var query: String
    func run() async throws {
        let pagination = try page.resolved()
        let count = try timelineCount(count, usingPagination: pagination.use, defaultValue: 10)
        let client = try await opts.authenticatedClient()
        let result = await client.search(query, count: count, includeRaw: json.includeRaw, all: pagination.use, maxPages: pagination.maxPages, cursor: pagination.cursor)
        try printTweetResult(result, json: json.asJson, pagination: pagination.use, empty: "No tweets found.", opts: opts, failure: "Search failed")
    }
}

struct Mentions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find tweets mentioning a user (defaults to current user)")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Option(name: [.customShort("u"), .long], help: "User handle (e.g. @steipete)") var user: String?
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of tweets to fetch") var count = "10"
    @Argument(help: "Optional user handle (alias for --user)") var username: String?
    func run() async throws {
        try rejectConflictingTarget(user: user, positional: username)
        let requested = user ?? username
        if let requested, normalizeHandle(requested) == nil {
            throw CLIError("Invalid --user handle. Expected something like @steipete (letters, digits, underscore; max 15).", exitCode: 2)
        }
        let count = try countFlag(count, defaultValue: 10)
        let client = try await opts.authenticatedClient()
        let handle: String
        if let requested { handle = normalizeHandle(requested)! }
        else {
            let current = await client.getCurrentUser()
            guard let username = current.user?.username, let normalized = normalizeHandle(username) else {
                throw CLIError("\(opts.p("err"))Could not determine current user (\(current.error ?? "Unknown error")). Use --user <handle>.")
            }
            handle = normalized
        }
        let result = await client.search("@\(handle)", count: count, includeRaw: json.includeRaw)
        try printTweetResult(result, json: json.asJson, empty: "No mentions found.", opts: opts, failure: "Failed to fetch mentions")
    }
}

struct Home: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get your home timeline (\"For You\" feed)")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of tweets to fetch") var count = "20"
    @Flag(name: .long, help: "Get \"Following\" feed (chronological) instead of \"For You\"") var following = false
    func run() async throws {
        let count = try countFlag(count, defaultValue: 20)
        let client = try await opts.authenticatedClient()
        let result = await client.home(count: count, following: following, includeRaw: json.includeRaw)
        try printTweetResult(result, json: json.asJson, empty: "No tweets found in \(following ? "Following" : "For You") timeline.", opts: opts, failure: "Failed to fetch home timeline")
    }
}

struct UserTweets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "user-tweets", abstract: "Get tweets from a user's profile timeline")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of tweets to fetch (max: 200)") var count = "20"
    @Option(name: .customLong("max-pages"), parsing: .unconditional, help: "Stop after N pages (max: 10)") var maxPages: String?
    @Option(name: .long, parsing: .unconditional, help: "Delay in ms between page fetches") var delay = "1000"
    @Option(name: .long, parsing: .unconditional, help: "Resume pagination from a cursor") var cursor: String?
    @Argument var username: String

    func limits() throws -> (count: Int, maxPages: Int?, delay: Int) {
        let maximum = try maxPages.map { try positiveInt($0, flag: "--max-pages", exitCode: 2) }
        let delay = try nonNegativeInt(delay, flag: "--delay", exitCode: 2)
        let count = try countFlag(count, defaultValue: 20, exitCode: 2)
        guard count <= 200 else { throw CLIError("Invalid --count. Max 200 tweets per run (safety cap: 10 pages). Use --cursor to continue.", exitCode: 2) }
        guard (maximum ?? 10) <= 10 else { throw CLIError("Invalid --max-pages. Expected a positive integer (max: 10).", exitCode: 2) }
        return (count, maximum, delay)
    }

    func run() async throws {
        let limits = try limits()
        guard let username = normalizeHandle(username) else { throw CLIError("Invalid handle: \(username)", exitCode: 2) }
        let client = try await opts.authenticatedClient()
        stderrLine("\(opts.p("info"))Looking up @\(username)...")
        let lookup = await client.getUserIdByUsername(username)
        guard lookup.success, let id = lookup.userId else { throw CLIError("\(opts.p("err"))\(lookup.error ?? "Could not find user @\(username)")") }
        let display = lookup.name.map { "\($0) (@\(lookup.username ?? username))" } ?? "@\(lookup.username ?? username)"
        stderrLine("\(opts.p("info"))Fetching tweets from \(display)...")
        let result = await client.userTweets(userId: id, count: limits.count, includeRaw: json.includeRaw, maxPages: limits.maxPages, cursor: cursor, pageDelayMs: limits.delay)
        try printTweetResult(result, json: json.asJson, pagination: !(cursor ?? "").isEmpty || limits.maxPages != nil || limits.count > 20,
                             empty: "No tweets found for @\(username).", opts: opts, failure: "Failed to fetch tweets")
        if let cursor = result.nextCursor, !json.asJson { stderrLine("\(opts.p("info"))More tweets available. Use --cursor \"\(cursor)\" to continue.") }
    }
}

struct Bookmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get your bookmarked tweets")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of bookmarks to fetch") var count = "20"
    @Option(name: .customLong("folder-id"), help: "Bookmark folder (collection) ID or URL") var folderId: String?
    @Flag(name: .customLong("expand-root-only"), help: "Only expand threads when bookmarked tweet is root") var expandRootOnly = false
    @Flag(name: .customLong("author-chain"), help: "Only include author self-reply chains connected to the bookmark") var authorChain = false
    @Flag(name: .customLong("author-only"), help: "Include all tweets from bookmarked tweet author in thread") var authorOnly = false
    @Flag(name: [.customLong("full-chain-only"), .customLong("full-chain")], help: "Save entire reply chain connected to the bookmarked tweet") var fullChain = false
    @Flag(name: .customLong("include-ancestor-branches"), help: "Include sibling branches for ancestors with --full-chain-only") var includeAncestorBranches = false
    @Flag(name: .customLong("include-parent"), help: "Include direct parent tweet for non-root bookmarks") var includeParent = false
    @Flag(name: .customLong("thread-meta"), help: "Add metadata fields (isThread, threadPosition, etc.)") var threadMeta = false
    @Flag(name: .customLong("sort-chronological"), help: "Sort output globally oldest -> newest") var sortChronological = false

    func run() async throws {
        let pagination = try page.resolved()
        let count = try timelineCount(count, usingPagination: pagination.use)
        let folder = try folderId.map { input -> String in
            guard let id = extractCollectionID(input, kind: "bookmarks") else { throw CLIError("Invalid --folder-id. Expected numeric ID or https://x.com/i/bookmarks/<id>.") }
            return id
        }
        let client = try await opts.authenticatedClient()
        let result = await client.bookmarks(count: count, folderId: folder, includeRaw: json.includeRaw, all: pagination.use, maxPages: pagination.maxPages, cursor: pagination.cursor)
        guard result.success else { throw CLIError("\(opts.p("err"))Failed to fetch bookmarks: \(result.error ?? "Unknown error")") }
        if authorChain && (authorOnly || fullChain) { stderrLine("\(opts.p("warn"))--author-chain already limits to the connected self-reply chain; other chain filters are redundant.") }
        if includeAncestorBranches && !fullChain { stderrLine("\(opts.p("warn"))--include-ancestor-branches only applies with --full-chain-only.") }
        let options = BookmarkExpansionOptions(expandRootOnly: expandRootOnly, authorChain: authorChain, authorOnly: authorOnly,
            fullChain: fullChain, includeAncestorBranches: includeAncestorBranches, includeParent: includeParent,
            threadMeta: threadMeta, sortChronological: sortChronological)
        let expanded = await expandBookmarks(result.tweets, options: options,
            fetchThread: { await client.getThread($0, includeRaw: json.includeRaw) },
            fetchTweet: { await client.getTweet($0, includeRaw: json.includeRaw) },
            warn: { stderrLine("\(opts.p("warn"))\($0)") })
        if json.asJson {
            if pagination.use { try printJSON(TweetPage(tweets: expanded, nextCursor: result.nextCursor)) }
            else { try printJSON(expanded) }
        } else { print(opts.output.tweets(expanded.map(\.tweet), empty: folder == nil ? "No bookmarks found." : "No bookmarks found in folder.")) }
    }
}

struct Unbookmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove bookmarked tweets")
    @OptionGroup var opts: GlobalOptions
    @Argument(help: "Tweet IDs or URLs to remove from bookmarks") var tweetIdOrUrls: [String]
    mutating func validate() throws {
        if tweetIdOrUrls.isEmpty { throw ValidationError("Missing expected argument '<tweet-id-or-urls>'") }
    }
    func run() async throws {
        let client = try await opts.authenticatedClient()
        var failed = false
        for input in tweetIdOrUrls {
            let id = extractTweetId(input)
            let result = await client.unbookmark(id)
            if result.success { print("\(opts.p("ok"))Removed bookmark for \(id)") }
            else { failed = true; stderrLine("\(opts.p("err"))Failed to remove bookmark for \(id): \(result.error ?? "Unknown error")") }
        }
        if failed { throw ExitCode(1) }
    }
}

struct Likes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get your liked tweets")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of likes to fetch") var count = "20"
    @Argument(help: "Optional username (defaults to current user)") var username: String?
    func run() async throws {
        let pagination = try page.resolved()
        let count = try timelineCount(count, usingPagination: pagination.use)
        let client = try await opts.authenticatedClient()
        let id = try await currentOrNamedUser(client, username: username, opts: opts)
        let result = await client.likes(userId: id, count: count, includeRaw: json.includeRaw, all: pagination.use, maxPages: pagination.maxPages, cursor: pagination.cursor)
        try printTweetResult(result, json: json.asJson, pagination: pagination.use, empty: "No liked tweets found.", opts: opts, failure: "Failed to fetch likes")
    }
}

struct News: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch AI-curated news and trending topics from Explore tabs", aliases: ["trending"])
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of items to fetch") var count = "10"
    @Flag(name: .customLong("ai-only"), help: "Show only AI-curated news items") var aiOnly = false
    @Flag(name: .customLong("with-tweets"), help: "Also fetch related tweets for each news item") var withTweets = false
    @Option(name: .customLong("tweets-per-item"), parsing: .unconditional, help: "Number of related tweets per news item") var tweetsPerItem = "5"
    @Flag(name: .customLong("for-you"), help: "Fetch from For You tab") var forYou = false
    @Flag(name: .customLong("news-only"), help: "Fetch from News tab") var newsOnly = false
    @Flag(name: .long, help: "Fetch from Sports tab") var sports = false
    @Flag(name: .long, help: "Fetch from Entertainment tab") var entertainment = false
    @Flag(name: .customLong("trending-only"), help: "Fetch from Trending tab") var trendingOnly = false
    var selectedTabs: [String] {
        let selected = [(forYou, "forYou"), (newsOnly, "news"), (sports, "sports"), (entertainment, "entertainment"), (trendingOnly, "trending")].filter(\.0).map(\.1)
        return selected.isEmpty ? ["forYou", "news", "sports", "entertainment"] : selected
    }
    func run() async throws {
        let count = try countFlag(count, defaultValue: 10, errorMessage: "--count must be a positive number")
        let tweetsPerItem = try countFlag(tweetsPerItem, defaultValue: 5, flag: "--tweets-per-item", errorMessage: "--tweets-per-item must be a positive number")
        let client = try await opts.authenticatedClient()
        let result = await client.news(count: count, includeRaw: json.includeRaw, withTweets: withTweets, tweetsPerItem: tweetsPerItem, aiOnly: aiOnly, tabs: selectedTabs)
        guard result.success else { throw CLIError("\(opts.p("err"))Failed to fetch news: \(result.error ?? "Unknown error")") }
        if json.asJson { try printJSON(result.items) }
        else { print(opts.output.news(result.items, tweetLimit: withTweets ? tweetsPerItem : nil)) }
    }
}

struct Lists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get your Twitter lists")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .customLong("member-of"), help: "Show lists you are a member of (instead of owned lists)") var memberOf = false
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of lists to fetch") var count = "100"
    func run() async throws {
        let count = try countFlag(count, defaultValue: 100)
        let client = try await opts.authenticatedClient()
        let result = await client.lists(count: count, memberships: memberOf)
        guard result.success else { throw CLIError("\(opts.p("err"))Failed to fetch lists: \(result.error ?? "Unknown error")") }
        if json { try printJSON(result.lists) }
        else { print(opts.output.lists(result.lists, memberships: memberOf)) }
    }
}

struct ListTimeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-timeline", abstract: "Get tweets from a list timeline")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var json: JsonFlags
    @OptionGroup var page: PageFlags
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of tweets to fetch") var count = "20"
    @Argument var listIdOrUrl: String
    func run() async throws {
        let pagination = try page.resolved(maxPagesImpliesPagination: true)
        let count = try timelineCount(count, usingPagination: pagination.use)
        guard let id = extractCollectionID(listIdOrUrl, kind: "lists") else { throw CLIError("Invalid list ID or URL. Expected numeric ID or https://x.com/i/lists/<id>.", exitCode: 2) }
        let client = try await opts.authenticatedClient()
        let result = await client.listTimeline(id, count: count, includeRaw: json.includeRaw, all: pagination.use, maxPages: pagination.maxPages, cursor: pagination.cursor)
        try printTweetResult(result, json: json.asJson, pagination: pagination.use, empty: "No tweets found in this list.", opts: opts, failure: "Failed to fetch list timeline")
    }
}

struct UserListFlags: ParsableArguments {
    @Option(name: .long, help: "User ID (defaults to current user)") var user: String?
    @Option(name: [.customShort("n"), .long], parsing: .unconditional, help: "Number of users to fetch per page") var count = "20"
    @OptionGroup var page: PageFlags
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Argument(help: "Optional username (alias for user lookup)") var username: String?
}

struct Following: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get users that you (or another user) follow")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var flags: UserListFlags
    func run() async throws { try await printUsers(flags, opts: opts, kind: "following") }
}

struct Followers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get users that follow you (or another user)")
    @OptionGroup var opts: GlobalOptions
    @OptionGroup var flags: UserListFlags
    func run() async throws { try await printUsers(flags, opts: opts, kind: "followers") }
}

struct Follow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Follow a user")
    @OptionGroup var opts: GlobalOptions
    @Argument var usernameOrId: String
    func run() async throws { try await followUser(usernameOrId, following: true, opts: opts) }
}

struct Unfollow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unfollow a user")
    @OptionGroup var opts: GlobalOptions
    @Argument var usernameOrId: String
    func run() async throws { try await followUser(usernameOrId, following: false, opts: opts) }
}

struct About: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get account origin and location information for a user")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Argument var username: String
    func run() async throws {
        guard let handle = normalizeHandle(username) else { throw CLIError("Invalid username: \(username)") }
        let client = try await opts.authenticatedClient()
        let result = await client.getUserAboutAccount(handle)
        guard result.success, let profile = result.about else { throw CLIError("\(opts.p("err"))Failed to fetch account information: \(result.error ?? "Unknown error")") }
        if json { try printJSON(profile) }
        else { print(opts.output.about(profile, handle: handle)) }
    }
}

struct HelpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "help", abstract: "Show help for a command")
    @OptionGroup var opts: GlobalOptions
    @Argument var command: String?
    func run() async throws {
        guard let command else { print(AviaryRoot.helpMessage()); return }
        guard let type = AviaryRoot.configuration.subcommands.first(where: {
            ($0.configuration.commandName ?? String(describing: $0).lowercased()) == command || $0.configuration.aliases.contains(command)
        }) else { throw CLIError("\(opts.p("err"))Unknown command: \(command)", exitCode: 2) }
        print(type.helpMessage())
    }
}
