import ArgumentParser
import Foundation

public struct AviaryRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "aviary",
        abstract: "Post tweets and replies via Twitter/X GraphQL API",
        discussion: "fast X CLI for tweeting, replying, and reading",
        version: "0.8.0",
        subcommands: [
            Tweet.self, Reply.self, HelpCmd.self, QueryIds.self, Home.self, Read.self, Replies.self, Thread.self,
            Search.self, Mentions.self, UserTweets.self, Bookmarks.self, Unbookmark.self, Likes.self,
            News.self, Trending.self, Lists.self, ListTimeline.self, Following.self, Followers.self,
            Follow.self, Unfollow.self, About.self, Whoami.self, Check.self,
        ]
    )

    @OptionGroup var opts: GlobalOptions

    public init() {}

    public func run() async throws {
        print(AviaryRoot.helpMessage())
    }

    public static func rewrittenArguments(_ args: [String]) -> [String] {
        let known: Set<String> = [
            "tweet", "reply", "query-ids", "read", "replies", "thread", "search", "mentions", "bookmarks",
            "unbookmark", "follow", "unfollow", "about", "following", "followers", "likes", "lists",
            "list-timeline", "home", "user-tweets", "news", "trending", "help", "whoami", "check",
        ]
        guard let first = args.first(where: { !$0.hasPrefix("-") }) else { return args }
        if known.contains(first) { return args }
        let isId = first.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil
        let isUrl = first.lowercased().contains("x.com/") || first.lowercased().contains("twitter.com/")
        if isId || isUrl, let idx = args.firstIndex(of: first) {
            var copy = args
            copy.insert("read", at: idx)
            return copy
        }
        return args
    }

    public static func mainAsync() async {
        let args = rewrittenArguments(Array(CommandLine.arguments.dropFirst()))
        do {
            var command = try AviaryRoot.parseAsRoot(args)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let exit as ExitCode {
            Foundation.exit(exit.rawValue)
        } catch {
            AviaryRoot.exit(withError: error)
        }
    }
}
