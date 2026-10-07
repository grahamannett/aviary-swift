import Foundation
import XClient

struct BookmarkExpansionOptions {
    var expandRootOnly = false
    var authorChain = false
    var authorOnly = false
    var fullChain = false
    var includeAncestorBranches = false
    var includeParent = false
    var threadMeta = false
    var sortChronological = false
}

struct BookmarkTweet: Encodable {
    var tweet: TweetData
    var metadata: ThreadMetadata?
    enum CodingKeys: String, CodingKey {
        case isThread, threadPosition, hasSelfReplies, threadRootId
    }
    func encode(to encoder: Encoder) throws {
        try tweet.encode(to: encoder)
        if let metadata {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(metadata.isThread, forKey: .isThread)
            try container.encode(metadata.threadPosition, forKey: .threadPosition)
            try container.encode(metadata.hasSelfReplies, forKey: .hasSelfReplies)
            try container.encode(metadata.threadRootId, forKey: .threadRootId)
        }
    }
}

func expandBookmarks(
    _ bookmarks: [TweetData], options: BookmarkExpansionOptions,
    fetchThread: (String) async -> TweetListResult,
    fetchTweet: (String) async -> TweetListResult,
    warn: (String) -> Void = { _ in },
    delay: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) }
) async -> [BookmarkTweet] {
    var cache: [String: [TweetData]] = [:]
    var expanded: [TweetData] = []
    let shouldExpand =
        options.expandRootOnly || options.authorChain || options.authorOnly || options.fullChain
    let shouldFetch = shouldExpand || options.threadMeta
    for (index, bookmark) in bookmarks.enumerated() {
        let isRoot = (bookmark.inReplyToStatusId ?? "").isEmpty
        var thread: [TweetData]?
        let key = bookmark.conversationId ?? bookmark.id
        if shouldFetch && (!options.expandRootOnly || isRoot || options.threadMeta) {
            if index > 0 { await delay() }
            if let cached = cache[key] {
                thread = cached
            } else {
                let result = await fetchThread(bookmark.id)
                if result.success {
                    thread = result.tweets
                    cache[result.tweets.first?.conversationId ?? key] = result.tweets
                } else {
                    warn(
                        "Failed to expand thread for \(bookmark.id): \(result.error ?? "Unknown error")"
                    )
                }
            }
        }
        var output = [bookmark]
        if shouldExpand && !(options.expandRootOnly && !isRoot), let thread {
            if options.authorChain {
                output = filterAuthorChain(tweets: thread, bookmarkedTweet: bookmark)
            } else {
                output =
                    options.fullChain
                    ? filterFullChain(
                        tweets: thread, bookmarkedTweet: bookmark,
                        includeAncestorBranches: options.includeAncestorBranches)
                    : thread
                if options.authorOnly {
                    output = filterAuthorOnly(tweets: output, bookmarkedTweet: bookmark)
                }
            }
        }
        if options.includeParent, let parentID = bookmark.inReplyToStatusId, !parentID.isEmpty,
            !output.contains(where: { $0.id == parentID })
        {
            if let parent = thread?.first(where: { $0.id == parentID }) {
                expanded.append(parent)
            } else {
                let result = await fetchTweet(parentID)
                if result.success, let parent = result.tweets.first { expanded.append(parent) }
            }
        }
        expanded.append(contentsOf: output)
    }
    // Match Map replacement semantics: later values win without moving the first insertion.
    var positions: [String: Int] = [:]
    var unique: [BookmarkTweet] = []
    for tweet in expanded {
        let metadata =
            options.threadMeta
            ? addThreadMetadata(
                tweet: tweet,
                allConversationTweets: cache[tweet.conversationId ?? tweet.id] ?? [tweet])
            : nil
        let value = BookmarkTweet(tweet: tweet, metadata: metadata)
        if let index = positions[tweet.id] {
            unique[index] = value
        } else {
            positions[tweet.id] = unique.count
            unique.append(value)
        }
    }
    if options.sortChronological {
        var dated: [(index: Int, value: BookmarkTweet, timestamp: Double)] = unique.enumerated().map
        {
            (
                index: $0.offset, value: $0.element,
                timestamp: XClient.tweetTimestamp($0.element.tweet.createdAt)
            )
        }
        dated.sort {
            $0.timestamp == $1.timestamp ? $0.index < $1.index : $0.timestamp < $1.timestamp
        }
        unique = dated.map(\.value)
    }
    return unique
}

func extractCollectionID(_ input: String, kind: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern =
        "(?:twitter\\.com|x\\.com)/i/\(NSRegularExpression.escapedPattern(for: kind))/(\\d+)"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
        let range = Range(match.range(at: 1), in: trimmed)
    {
        return String(trimmed[range])
    }
    return trimmed.range(of: #"^\d{5,}$"#, options: .regularExpression) == nil ? nil : trimmed
}

struct MediaInput {
    var data: Data
    var mimeType: String
    var alt: String?
}

func loadMedia(
    paths: [String], alts: [String],
    read: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
) throws -> [MediaInput] {
    let types = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp",
        "gif": "image/gif", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
    ]
    var items: [MediaInput] = []
    for (index, path) in paths.enumerated() {
        guard let mime = types[URL(fileURLWithPath: path).pathExtension.lowercased()] else {
            throw CLIError(
                "Unsupported media type for \(path). Supported: jpg, jpeg, png, webp, gif, mp4, mov"
            )
        }
        items.append(
            MediaInput(
                data: try read(path), mimeType: mime, alt: index < alts.count ? alts[index] : nil))
    }
    let videos = items.filter { $0.mimeType.hasPrefix("video/") }.count
    if videos > 1 { throw CLIError("Only one video can be attached") }
    if videos == 1 && items.count > 1 {
        throw CLIError("Video cannot be combined with other media")
    }
    if items.count > 4 { throw CLIError("Maximum 4 media attachments") }
    return items
}

func uploadThenCreate(
    text: String, replyTo: String?, media: [MediaInput],
    upload: (MediaInput) async -> UploadMediaResult,
    create: (String, String?, [String]) async -> MutationResult
) async throws -> MutationResult {
    var ids: [String] = []
    for item in media {
        let result = await upload(item)
        guard result.success, let id = result.mediaId else {
            throw CLIError("Media upload failed: \(result.error ?? "Unknown error")")
        }
        ids.append(id)
    }
    return await create(text, replyTo, ids)
}

func post(text: String, replyTo: String?, opts: GlobalOptions) async throws {
    let media = try loadMedia(paths: opts.media, alts: opts.alt)
    let invocation = try opts.resolvedInvocation()
    let cookies = try opts.require(await invocation.credentials())
    if let source = cookies.source { stderrLine(opts.l("source") + source) }
    if let replyTo { stderrLine("\(opts.p("info"))Replying to tweet: \(replyTo)") }
    let client = invocation.makeClient(cookies)
    let result = try await uploadThenCreate(
        text: text, replyTo: replyTo, media: media,
        upload: { await client.uploadMedia(data: $0.data, mimeType: $0.mimeType, alt: $0.alt) },
        create: { await client.createTweet(text: $0, replyTo: $1, mediaIds: $2) })
    guard result.success, let id = result.tweetId else {
        throw CLIError(
            "\(opts.p("err"))Failed to post \(replyTo == nil ? "tweet" : "reply"): \(result.error ?? "Tweet created but no ID returned")"
        )
    }
    print("\(opts.p("ok"))\(replyTo == nil ? "Tweet" : "Reply") posted successfully!")
    print(opts.l("url") + opts.output.hyperlink("https://x.com/i/status/\(id)"))
}

func rejectConflictingTarget(user: String?, positional: String?) throws {
    if user != nil && positional != nil {
        throw CLIError("Use either --user or a positional username, not both.", exitCode: 2)
    }
}

func currentOrNamedUser(_ client: TwitterClient, username: String?, opts: GlobalOptions)
    async throws -> String
{
    if let username {
        let lookup = await client.getUserIdByUsername(username)
        guard lookup.success, let id = lookup.userId else {
            throw CLIError("\(opts.p("err"))\(lookup.error ?? "Could not find user @\(username)")")
        }
        return id
    }
    let current = await client.getCurrentUser()
    guard current.success, let user = current.user else {
        throw CLIError(
            "\(opts.p("err"))Failed to get current user: \(current.error ?? "Unknown error")")
    }
    return user.id
}

func resolveUser(_ client: TwitterClient, _ usernameOrId: String, opts: GlobalOptions) async throws
    -> (id: String, username: String?)
{
    let raw = usernameOrId.trimmingCharacters(in: .whitespacesAndNewlines)
    let numeric = raw.range(of: #"^\d+$"#, options: .regularExpression) != nil
    if let handle = normalizeHandle(raw) {
        let lookup = await client.getUserIdByUsername(handle)
        if lookup.success, let id = lookup.userId { return (id, lookup.username) }
        if !numeric {
            throw CLIError(
                "\(opts.p("err"))Failed to find user @\(handle): \(lookup.error ?? "Unknown error")"
            )
        }
    }
    if numeric { return (raw, nil) }
    throw CLIError("\(opts.p("err"))Invalid username: \(usernameOrId)")
}

func followUser(_ input: String, following: Bool, opts: GlobalOptions) async throws {
    let client = try await opts.authenticatedClient()
    let user = try await resolveUser(client, input, opts: opts)
    let display = user.username.map { "@\($0)" } ?? user.id
    let result = following ? await client.follow(user.id) : await client.unfollow(user.id)
    guard result.success else {
        throw CLIError(
            "\(opts.p("err"))Failed to \(following ? "follow" : "unfollow") \(display): \(result.error ?? "Unknown error")"
        )
    }
    print(
        "\(opts.p("ok"))\(following ? "Now following" : "Unfollowed") \(result.username.map { "@\($0)" } ?? display)"
    )
}

func collectUsers(
    cursor: String?, maxPages: Int?,
    fetch: (String?) async -> UserListResult,
    pageStarted: (Int) -> Void = { _ in },
    delay: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) }
) async -> UserListResult {
    var users: [TwitterUser] = []
    var seen = Set<String>()
    var next = cursor
    var page = 0
    while true {
        page += 1
        pageStarted(page)
        let result = await fetch(next)
        guard result.success else {
            return UserListResult(
                success: false, users: users, nextCursor: next, error: result.error)
        }
        let added = result.users.filter { seen.insert($0.id).inserted }
        users.append(contentsOf: added)
        guard let cursor = result.nextCursor, !result.users.isEmpty, !added.isEmpty, cursor != next
        else {
            return UserListResult(success: true, users: users, nextCursor: nil, error: nil)
        }
        if let maxPages, page >= maxPages {
            return UserListResult(success: true, users: users, nextCursor: cursor, error: nil)
        }
        next = cursor
        await delay()
    }
}

func printUsers(_ flags: UserListFlags, opts: GlobalOptions, kind: String) async throws {
    try rejectConflictingTarget(user: flags.user, positional: flags.username)
    let count = try countFlag(flags.count, defaultValue: 20)
    let page = try flags.page.resolved(requiresAll: true)
    let client = try await opts.authenticatedClient()
    let id: String
    if let requested = flags.user, !requested.isEmpty {
        id = requested
    } else {
        id = try await currentOrNamedUser(client, username: flags.username, opts: opts)
    }
    let fetch: (String?) async -> UserListResult = { cursor in
        kind == "following"
            ? await client.following(userId: id, count: count, cursor: cursor)
            : await client.followers(userId: id, count: count, cursor: cursor)
    }
    let result: UserListResult
    if page.all {
        result = await collectUsers(
            cursor: page.cursor, maxPages: page.maxPages, fetch: fetch,
            pageStarted: {
                if !flags.json { stderrLine("\(opts.p("info"))Fetching page \($0)...") }
            })
    } else {
        result = await fetch(page.cursor)
    }
    try printUserResult(
        result, json: flags.json, pagination: page.use, all: page.all, opts: opts, kind: kind)
}
