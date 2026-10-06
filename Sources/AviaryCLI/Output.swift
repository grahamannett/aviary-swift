#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import XClient

struct CLIOutput {
    let plain: Bool
    let emoji: Bool
    let color: Bool
    let hyperlinks: Bool

    init(plain: Bool = false, noEmoji: Bool = false, noColor: Bool = false,
         isTTY: Bool = isatty(STDOUT_FILENO) != 0,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.plain = plain
        emoji = !plain && !noEmoji
        color = !plain && !noColor && isTTY && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
        hyperlinks = !plain && isTTY
    }

    func styled(_ value: String, code: Int) -> String { color ? "\u{1b}[\(code)m\(value)\u{1b}[0m" : value }
    func status(_ kind: String) -> String {
        let entry: (String, String, String, Int)
        switch kind {
        case "ok": entry = ("✅", "OK:", "[ok]", 32)
        case "warn": entry = ("⚠️", "Warning:", "[warn]", 33)
        case "err": entry = ("❌", "Error:", "[err]", 31)
        case "hint": entry = ("ℹ️", "Hint:", "[hint]", 90)
        default: entry = ("ℹ️", "Info:", "[info]", 36)
        }
        return styled((plain ? entry.2 : emoji ? entry.0 : entry.1) + " ", code: entry.3)
    }

    func label(_ kind: String) -> String {
        let entry: (String, String, String, Int)
        switch kind {
        case "date": entry = ("📅", "Date:", "date:", 35)
        case "source": entry = ("📍", "Source:", "source:", 90)
        case "engine": entry = ("⚙️", "Engine:", "engine:", 34)
        case "credentials": entry = ("🔑", "Credentials:", "credentials:", 33)
        case "user": entry = ("🙋", "User:", "user:", 32)
        case "userId": entry = ("🪪", "User ID:", "user_id:", 35)
        case "email": entry = ("📧", "Email:", "email:", 32)
        default: entry = ("🔗", "URL:", "url:", 36)
        }
        return styled((plain ? entry.2 : emoji ? entry.0 : entry.1) + " ", code: entry.3)
    }

    func hyperlink(_ url: String) -> String {
        guard hyperlinks else { return url }
        let safe = url.replacingOccurrences(of: "\u{1b}", with: "").replacingOccurrences(of: "\u{7}", with: "")
        return "\u{1b}]8;;\(safe)\u{7}\(safe)\u{1b}]8;;\u{7}"
    }

    func mediaLabel(_ type: String) -> String {
        if emoji { return type == "video" ? "🎬" : type == "animated_gif" ? "🔄" : "🖼️" }
        return type == "video" ? "VIDEO:" : type == "animated_gif" ? "GIF:" : "PHOTO:"
    }

    func tweets(_ tweets: [TweetData], empty: String = "No tweets found.", separator: Bool = true) -> String {
        guard !tweets.isEmpty else { return empty }
        var lines: [String] = []
        let articleLabel = emoji ? "📰" : "Article:"
        for tweet in tweets {
            lines.append("\n@\(tweet.author.username) (\(tweet.author.name)):")
            if let article = tweet.article {
                if tweet.text.hasPrefix(article.title) { lines.append("\(articleLabel) \(tweet.text)") }
                else {
                    lines.append("\(articleLabel) \(article.title)")
                    if let preview = article.previewText, !preview.isEmpty { lines.append("   \(preview)") }
                }
            } else { lines.append(tweet.text) }
            for media in tweet.media ?? [] { lines.append("\(mediaLabel(media.type)) \(media.url)") }
            if let quoted = tweet.quotedTweet {
                let top = emoji ? "┌─" : "> "
                let mid = emoji ? "│ " : "> "
                let bottom = emoji ? "└─" : "> "
                lines.append("\(top) QT @\(quoted.author.username):")
                let text = quoted.article.map { "\(articleLabel) \($0.title)" } ?? quoted.text
                let truncated = utf16Prefix(text, count: 280) + (text.utf16.count > 280 ? "..." : "")
                for line in truncated.components(separatedBy: "\n").prefix(4) { lines.append(mid + line) }
                for media in quoted.media ?? [] { lines.append("\(mid)\(mediaLabel(media.type)) \(media.url)") }
                lines.append("\(bottom) https://x.com/\(quoted.author.username)/status/\(quoted.id)")
            }
            if let date = tweet.createdAt, !date.isEmpty { lines.append(label("date") + date) }
            lines.append(label("url") + hyperlink("https://x.com/\(tweet.author.username)/status/\(tweet.id)"))
            if separator { lines.append(String(repeating: "─", count: 50)) }
        }
        return lines.joined(separator: "\n")
    }

    func stats(_ tweet: TweetData) -> String {
        let likes = tweet.likeCount ?? 0, retweets = tweet.retweetCount ?? 0, replies = tweet.replyCount ?? 0
        if plain { return "likes: \(likes)  retweets: \(retweets)  replies: \(replies)" }
        if !emoji { return "Likes \(likes)  Retweets \(retweets)  Replies \(replies)" }
        return "❤️ \(likes)  🔁 \(retweets)  💬 \(replies)"
    }

    func users(_ users: [TwitterUser]) -> String {
        guard !users.isEmpty else { return "No users found." }
        return users.map { user in
            var lines = ["@\(user.username) (\(user.name ?? ""))"]
            if let description = user.description, !description.isEmpty {
                lines.append("  " + utf16Prefix(description, count: 100) + (description.utf16.count > 100 ? "..." : ""))
            }
            if let followers = user.followersCount { lines.append("  \(status("info"))\(groupedCount(followers)) followers") }
            lines.append(String(repeating: "─", count: 50))
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func lists(_ lists: [TwitterList], memberships: Bool) -> String {
        guard !lists.isEmpty else { return memberships ? "You are not a member of any lists." : "You do not own any lists." }
        return lists.map { list in
            var lines = ["\(list.name) \(styled(list.isPrivate == true ? "[private]" : "[public]", code: 90))"]
            if let description = list.description, !description.isEmpty {
                lines.append("  " + utf16Prefix(description, count: 100) + (description.utf16.count > 100 ? "..." : ""))
            }
            lines.append("  \(status("info"))\(groupedCount(list.memberCount ?? 0)) members")
            if let owner = list.owner { lines.append("  " + styled("Owner: @\(owner.username)", code: 90)) }
            lines.append("  " + styled(hyperlink("https://x.com/i/lists/\(list.id)"), code: 32))
            lines.append(String(repeating: "─", count: 50))
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func news(_ items: [NewsItem], tweetLimit: Int?) -> String {
        guard !items.isEmpty else { return "No news items found." }
        return items.map { item in
            var lines = ["\n\(styled(item.category.map { "[\($0)]" } ?? "", code: 32)) \(styled(item.headline, code: 36))"]
            if let description = item.description, !description.isEmpty { lines.append("  " + styled(description, code: 90)) }
            var meta: [String] = []
            if let time = item.timeAgo, !time.isEmpty { meta.append(time) }
            if let count = item.postCount, count != 0 { meta.append("\(shortCount(count)) posts") }
            if !meta.isEmpty { lines.append("  " + styled(meta.joined(separator: " | "), code: 90)) }
            if let url = item.url, !url.isEmpty { lines.append("  " + label("url") + url) }
            if let tweets = item.tweets, !tweets.isEmpty {
                lines.append("  " + styled("Related tweets:", code: 37))
                for tweet in tweets.prefix(tweetLimit ?? tweets.count) {
                    lines.append("    @\(tweet.author.username): " + utf16Prefix(tweet.text, count: 100) + (tweet.text.utf16.count > 100 ? "..." : ""))
                }
            }
            lines.append(styled(String(repeating: "─", count: 50), code: 90))
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func about(_ profile: AboutProfile, handle: String) -> String {
        var lines = ["\(status("info"))Account information for @\(handle):"]
        if let country = profile.accountBasedIn, !country.isEmpty { lines.append("  Account based in: \(country)") }
        if let accurate = profile.createdCountryAccurate { lines.append("  Creation country accurate: \(accurate ? "Yes" : "No")") }
        if let accurate = profile.locationAccurate { lines.append("  Location accurate: \(accurate ? "Yes" : "No")") }
        if let source = profile.source, !source.isEmpty { lines.append(label("source") + source) }
        if let url = profile.learnMoreUrl, !url.isEmpty { lines.append("  Learn more: \(url)") }
        return lines.joined(separator: "\n")
    }
}

func utf16Prefix(_ text: String, count: Int) -> String { String(decoding: text.utf16.prefix(count), as: UTF16.self) }

func groupedCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

func shortCount(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return String(value)
}

struct TweetPage<Tweet: Encodable>: Encodable {
    let tweets: [Tweet]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case tweets, nextCursor }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tweets, forKey: .tweets)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

struct UserPage: Encodable {
    let users: [TwitterUser]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case users, nextCursor }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(users, forKey: .users)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

func printUserResult(_ result: UserListResult, json: Bool, pagination: Bool, all: Bool, opts: GlobalOptions, kind: String,
                     write: (String) -> Void = { print($0) }, writeError: (String) -> Void = stderrLine) throws {
    guard result.success else { throw CLIError("\(opts.p("err"))Failed to fetch \(kind): \(result.error ?? "Unknown error")") }
    if json {
        if pagination { write(try jsonString(UserPage(users: result.users, nextCursor: result.nextCursor))) }
        else { write(try jsonString(result.users)) }
    } else {
        if all {
            writeError("\(opts.p("info"))Total: \(result.users.count) users")
            if let cursor = result.nextCursor {
                writeError("\(opts.p("info"))Stopped at --max-pages. Use --cursor to continue.")
                writeError("\(opts.p("info"))Next cursor: \(cursor)")
            }
        }
        if !all || !result.users.isEmpty { write(opts.output.users(result.users)) }
        if !all, !result.users.isEmpty, let cursor = result.nextCursor { writeError("\(opts.p("info"))Next cursor: \(cursor)") }
    }
}

func printTweetResult(_ result: TweetListResult, json: Bool, pagination: Bool = false,
                      empty: String = "No tweets found.", opts: GlobalOptions,
                      failure: String, preservePartial: Bool = false, resumeKind: String? = nil,
                      write: (String) -> Void = { print($0) },
                      writeError: (String) -> Void = stderrLine) throws {
    if !result.success && (!preservePartial || result.tweets.isEmpty) {
        throw CLIError("\(opts.p("err"))\(failure): \(result.error ?? "Unknown error")")
    }
    if json {
        if pagination { write(try jsonString(TweetPage(tweets: result.tweets, nextCursor: result.nextCursor))) }
        else { write(try jsonString(result.tweets)) }
    } else { write(opts.output.tweets(result.tweets, empty: empty)) }
    if let resumeKind, let cursor = result.nextCursor, !json {
        writeError("\(opts.p("info"))More \(resumeKind) available. Use --cursor \"\(cursor)\" to continue.")
    }
    if !result.success { throw CLIError("\(opts.p("err"))\(failure): \(result.error ?? "Unknown error")") }
}
