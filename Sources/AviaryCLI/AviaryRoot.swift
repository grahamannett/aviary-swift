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
            News.self, Lists.self, ListTimeline.self, Following.self, Followers.self,
            Follow.self, Unfollow.self, About.self, Whoami.self, Check.self,
        ]
    )

    @OptionGroup var opts: GlobalOptions

    public init() {}

    public func run() async throws { print(AviaryRoot.helpMessage()) }

    static let commandNames: Set<String> = [
        "tweet", "reply", "query-ids", "read", "replies", "thread", "search", "mentions", "bookmarks",
        "unbookmark", "follow", "unfollow", "about", "following", "followers", "likes", "lists",
        "list-timeline", "home", "user-tweets", "news", "trending", "help", "whoami", "check",
    ]

    static let valuedGlobalOptions: Set<String> = [
        "--auth-token", "--ct0", "--chrome-profile", "--chrome-profile-dir", "--firefox-profile",
        "--cookie-timeout", "--cookie-source", "--media", "--alt", "--timeout", "--quote-depth",
    ]

    static let valuedOptions = valuedGlobalOptions.union([
        "--count", "-n", "--max-pages", "--cursor", "--delay", "--user", "-u",
        "--folder-id", "--tweets-per-item",
    ])

    public static func rewrittenArguments(_ arguments: [String]) -> [String] {
        var args = arguments
        if args.first == "--" { args.removeFirst() }
        // Commander exposes -V as the short version flag. Do not rewrite values
        // of any option or literal arguments after the option terminator.
        var flagIndex = 0
        while flagIndex < args.count {
            if args[flagIndex] == "--" { break }
            if valuedOptions.contains(args[flagIndex]) { flagIndex += 2; continue }
            if args[flagIndex] == "-V" { args[flagIndex] = "--version" }
            flagIndex += 1
        }
        var index = 0
        while index < args.count {
            let token = args[index]
            if valuedGlobalOptions.contains(token) { index += 2; continue }
            if token == "--" { break }
            if token.hasPrefix("-") { index += 1; continue }
            if commandNames.contains(token) { return args }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let isID = trimmed.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil
            let isURL = trimmed.range(of: #"^(?:https?://)?(?:www\.)?(?:twitter\.com|x\.com)/[^/]+/status/\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
            if isID || isURL { args.insert("read", at: index); return args }
            index += 1
        }
        return args
    }

    public static func mainAsync() async {
        let args = rewrittenArguments(Array(CommandLine.arguments.dropFirst()))
        do {
            var command = try AviaryRoot.parseAsRoot(args)
            if var asyncCommand = command as? any AsyncParsableCommand { try await asyncCommand.run() }
            else { try command.run() }
        } catch let error as CLIError {
            let output = CLIOutput(plain: args.contains("--plain"), noEmoji: args.contains("--no-emoji"), noColor: args.contains("--no-color"))
            let prefix = output.status("err")
            stderrLine(error.description.hasPrefix(prefix) ? error.description : prefix + error.description)
            Foundation.exit(error.exitCode)
        } catch let exit as ExitCode {
            Foundation.exit(exit.rawValue)
        } catch {
            // Keep ArgumentParser's detailed usage/help, but use Bird's parser error status.
            if AviaryRoot.exitCode(for: error).rawValue == 0 { AviaryRoot.exit(withError: error) }
            stderrLine(AviaryRoot.fullMessage(for: error))
            Foundation.exit(1)
        }
    }
}
